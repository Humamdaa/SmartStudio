import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:image/image.dart' as img;
import '../data/database/objectbox/entities.dart';

// ═══════════════════════════════════════════════════════════════
// SecureStorageService — المنطق الفيزيائي للمجلد السري
//
// المبدأ:
//   مجلد السيكيور = /data/user/0/com.pixmind/files/secure/
//   فيه ملف .nomedia → Android يتجاهله كلياً
//
// لما نضيف صورة:
//   1. نجلب الملف الأصلي من photo_manager
//   2. ننسخه للمجلد السري
//   3. نولّد thumbnail مصغر للـ grid
//   4. نحذف الأصل من الجهاز
//   5. نخزن SecureFile في ObjectBox
//
// لما نرجع صورة:
//   1. ننسخها لـ DCIM/PixMind/
//   2. photo_manager يعيد scan
//   3. نحذفها من مجلد السيكيور
//   4. نحذف SecureFile من ObjectBox
// ═══════════════════════════════════════════════════════════════
class SecureStorageService {
  SecureStorageService._();
  static final SecureStorageService instance = SecureStorageService._();

  // مجلد السيكيور (يُهيَّأ مرة وحدة)
  Directory? _secureDir;
  Directory? _thumbsDir;

  // ─────────────────────────────────────────
  // init — ننشئ المجلد و.nomedia إذا ما موجودين
  // نستدعيه مرة وحدة عند فتح التطبيق
  // ─────────────────────────────────────────
  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();

    _secureDir = Directory(p.join(appDir.path, 'secure'));
    _thumbsDir = Directory(p.join(appDir.path, 'secure', '.thumbs'));

    // ننشئ المجلدات إذا ما موجودة
    if (!await _secureDir!.exists()) {
      await _secureDir!.create(recursive: true);
    }
    if (!await _thumbsDir!.exists()) {
      await _thumbsDir!.create(recursive: true);
    }

    // .nomedia = يخلي Android يتجاهل المجلد كلياً
    // أي gallery app أو media scanner لن يرى الملفات
    final nomedia = File(p.join(_secureDir!.path, '.nomedia'));
    if (!await nomedia.exists()) {
      await nomedia.create();
    }
  }

  Directory get secureDir {
    assert(_secureDir != null, 'Call init() first');
    return _secureDir!;
  }

  // ─────────────────────────────────────────
  // addAsset — نقل صورة/فيديو واحدة للمجلد السري
  // ─────────────────────────────────────────
  Future<SecureFile?> addAsset(AssetEntity asset) async {
    final results = await addAssets([asset]);
    return results.isEmpty ? null : results.first;
  }

  // ─────────────────────────────────────────
  // addAssets — نقل عدة صور/فيديوهات دفعة وحدة
  //
  // نسخ + thumbnail لكل عنصر أولاً، وبعدين حذف الكل
  // من المعرض بطلب واحد (deleteWithIds دفعة وحدة).
  // هيك أندرويد يطلع ديالوج تأكيد واحد بس مش ديالوج
  // لكل صورة — قبل كنا نحذف كل عنصر لحاله جوا اللوب
  // وهذا كان يسبب توقف/تجاهل العناصر اللي بعد أول ديالوج.
  // ─────────────────────────────────────────
  Future<List<SecureFile>> addAssets(List<AssetEntity> assets) async {
    assert(_secureDir != null, 'Call init() first');

    final results = <SecureFile>[];
    final idsToDelete = <String>[];

    for (final asset in assets) {
      try {
        final originFile = await asset.originFile;
        if (originFile == null) continue;

        final ext = p.extension(originFile.path);
        final safeName =
            '${DateTime.now().microsecondsSinceEpoch}_${asset.id}$ext';
        final destPath = p.join(_secureDir!.path, safeName);

        await originFile.copy(destPath);

        String? thumbPath;
        if (asset.type == AssetType.image) {
          thumbPath = await _generateThumbnail(destPath, asset.id);
        } else if (asset.type == AssetType.video) {
          thumbPath = await _generateVideoThumbnail(asset);
        }

        results.add(
          SecureFile(
            originalAssetId: asset.id,
            securePath: destPath,
            originalName: asset.title ?? safeName,
            mimeType: asset.type == AssetType.video ? 'video' : 'image',
            thumbnailPath: thumbPath,
            width: asset.width,
            height: asset.height,
            duration: asset.videoDuration.inSeconds,
            addedAt: DateTime.now(),
          ),
        );
        idsToDelete.add(asset.id);
      } catch (_) {
        // نتجاهل هذا العنصر ونكمل الباقي
      }
    }

    if (idsToDelete.isNotEmpty) {
      // حذف دفعة وحدة — ديالوج تأكيد واحد من أندرويد بدل واحد لكل صورة
      await PhotoManager.editor.deleteWithIds(idsToDelete);
    }

    return results;
  }

  // ─────────────────────────────────────────
  // restoreFile — إرجاع ملف للمعرض العام
  //
  // يرجع: true إذا نجح، false إذا فشل
  // ─────────────────────────────────────────
  Future<bool> restoreFile(SecureFile secureFile) async {
    try {
      final sourceFile = File(secureFile.securePath);
      if (!await sourceFile.exists()) return false;

      // فيديو وصورة تحتاج دالة حفظ مختلفة في photo_manager
      // (saveImageWithPath تفشل مع ملفات الفيديو)
      // الدالتان ترميان استثناء عند الفشل بدل إرجاع null، فالـ catch بالأسفل يغطي الفشل
      secureFile.mimeType == 'video'
          ? await PhotoManager.editor.saveVideo(
              sourceFile,
              title: secureFile.originalName,
            )
          : await PhotoManager.editor.saveImageWithPath(
              secureFile.securePath,
              title: secureFile.originalName,
            );

      // نحذف من المجلد السري
      await _deleteSecureFile(secureFile);

      return true;
    } catch (e) {
      return false;
    }
  }

  // ─────────────────────────────────────────
  // deleteFile — حذف نهائي من المجلد السري
  // ─────────────────────────────────────────
  Future<void> deleteFile(SecureFile secureFile) async {
    await _deleteSecureFile(secureFile);
  }

  Future<void> _deleteSecureFile(SecureFile secureFile) async {
    // نحذف الملف الأصلي
    final f = File(secureFile.securePath);
    if (await f.exists()) await f.delete();

    // نحذف الـ thumbnail
    if (secureFile.thumbnailPath != null) {
      final t = File(secureFile.thumbnailPath!);
      if (await t.exists()) await t.delete();
    }
  }

  // ─────────────────────────────────────────
  // _generateThumbnail — نولّد صورة مصغرة 200x200
  // نخزنها في مجلد .thumbs المخفي
  // ─────────────────────────────────────────
  Future<String?> _generateThumbnail(String imagePath, String id) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return null;

      // نصغّر لـ 200x200
      final thumb = img.copyResizeCropSquare(image, size: 200);
      final thumbBytes = img.encodeJpg(thumb, quality: 75);

      final thumbPath = p.join(_thumbsDir!.path, '$id.jpg');
      await File(thumbPath).writeAsBytes(thumbBytes);
      return thumbPath;
    } catch (_) {
      return null;
    }
  }

  // للفيديو نجلب thumbnail من photo_manager قبل الحذف
  Future<String?> _generateVideoThumbnail(AssetEntity asset) async {
    try {
      final thumbData = await asset.thumbnailDataWithSize(
        const ThumbnailSize.square(200),
      );
      if (thumbData == null) return null;

      final thumbPath = p.join(_thumbsDir!.path, '${asset.id}.jpg');
      await File(thumbPath).writeAsBytes(thumbData);
      return thumbPath;
    } catch (_) {
      return null;
    }
  }

  // إجمالي حجم المجلد السري بالـ bytes
  Future<int> getTotalSize() async {
    if (_secureDir == null || !await _secureDir!.exists()) return 0;
    int total = 0;
    await for (final entity in _secureDir!.list(recursive: false)) {
      if (entity is File && !entity.path.endsWith('.nomedia')) {
        total += await entity.length();
      }
    }
    return total;
  }
}
