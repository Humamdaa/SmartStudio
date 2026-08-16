import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

// ═══════════════════════════════════════════════════════════════
// AlbumService — نقل/نسخ الصور بين مجلدات الجهاز الحقيقية
//
// هذه مجلدات فعلية على الذاكرة (Pictures/اسم_الألبوم)، يعني
// بتظهر بأي تطبيق معرض تاني وبمدير الملفات — مش ألبومات وهمية
// جوّا التطبيق.
//
// أندرويد ما بيعرف "مجلد فاضي" بالمعرض، فإنشاء ألبوم جديد
// بيصير وقت ما ننقل/ننسخ أول صورة عليه.
// ═══════════════════════════════════════════════════════════════
class AlbumService {
  AlbumService._();
  static final AlbumService instance = AlbumService._();

  /// المجلد الأب اللي بننشئ تحته الألبومات الجديدة.
  static const _root = 'Pictures';

  String relativePathFor(String albumName) => '$_root/$albumName';

  /// المسار النسبي لمجلد موجود — منجيبه من أول ملف جوّاه،
  /// لأن AssetPathEntity ما بيعطينا RELATIVE_PATH مباشرة.
  Future<String?> relativePathOf(AssetPathEntity path) async {
    try {
      final assets = await path.getAssetListRange(start: 0, end: 1);
      if (assets.isEmpty) return null;
      final rel = assets.first.relativePath;
      if (rel == null || rel.isEmpty) return null;
      // منشيل السلاش الأخير حتى يطابق الصيغة المتوقّعة
      return rel.endsWith('/') ? rel.substring(0, rel.length - 1) : rel;
    } catch (_) {
      return null;
    }
  }

  /// نقل صورة/فيديو لمجلد موجود على الجهاز.
  ///
  /// على أندرويد 11+ الطريقة الموثوقة هي moveAssetsToPath (بتستخدم
  /// MediaStore.createWriteRequest وبتطلب إذن المستخدم بنافذة نظام).
  /// moveAssetToAnother مخصّصة لأندرويد 10 وأقل، فمنخليها احتياط.
  Future<bool> moveToExisting({
    required AssetEntity asset,
    required AssetPathEntity target,
  }) async {
    final rel = await relativePathOf(target);
    if (rel != null) {
      try {
        final ok = await PhotoManager.editor.android
            .moveAssetsToPath(entities: [asset], targetPath: rel);
        if (ok) return true;
      } catch (_) {
        // منجرّب الطريقة القديمة تحت
      }
    }
    try {
      return await PhotoManager.editor.android
          .moveAssetToAnother(entity: asset, target: target);
    } catch (_) {
      return false;
    }
  }

  /// نقل لمجلد جديد — بينشأ تلقائياً بأول ملف ينتقل عليه.
  /// يتطلب أندرويد 11+ (API 30).
  Future<bool> moveToNewAlbum({
    required List<AssetEntity> assets,
    required String albumName,
  }) async {
    try {
      return await PhotoManager.editor.android.moveAssetsToPath(
        entities: assets,
        targetPath: relativePathFor(albumName),
      );
    } catch (_) {
      return false;
    }
  }

  /// نسخ لمجلد موجود (الأصل بيضل مكانه).
  Future<bool> copyToExisting({
    required AssetEntity asset,
    required AssetPathEntity target,
  }) async {
    try {
      await PhotoManager.editor
          .copyAssetToPath(asset: asset, pathEntity: target);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// نسخ لمجلد جديد — منحفظ نسخة تانية تحت المسار الجديد.
  Future<bool> copyToNewAlbum({
    required AssetEntity asset,
    required String albumName,
  }) async {
    try {
      final file = await asset.originFile;
      if (file == null || !await file.exists()) return false;

      final relative = relativePathFor(albumName);
      if (asset.type == AssetType.video) {
        await PhotoManager.editor.saveVideo(
          File(file.path),
          title: asset.title,
          relativePath: relative,
        );
      } else {
        await PhotoManager.editor.saveImageWithPath(
          file.path,
          title: asset.title,
          relativePath: relative,
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// حذف ألبوم = حذف كل الملفات اللي جوّاه.
  ///
  /// أندرويد ما بيخزّن "ألبوم فاضي" بالمعرض، فلما ينحذف آخر ملف
  /// بيختفي المجلد لحاله. أندرويد 11+ بيعرض نافذة تأكيد نظام
  /// قبل الحذف، والمستخدم لازم يوافق عليها.
  ///
  /// يرجع عدد الملفات اللي انحذفت فعلياً.
  Future<int> deleteAlbum(AssetPathEntity path, {int? knownCount}) async {
    try {
      final count = knownCount ?? await path.assetCountAsync;
      if (count == 0) return 0;
      final assets = await path.getAssetListRange(start: 0, end: count);
      final ids = assets.map((e) => e.id).toList();
      if (ids.isEmpty) return 0;
      final deleted = await PhotoManager.editor.deleteWithIds(ids);
      return deleted.length;
    } catch (_) {
      return 0;
    }
  }

  /// كل مجلدات الجهاز اللي فيها صور/فيديو — نستخدمها كوجهات.
  Future<List<AssetPathEntity>> loadTargets() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: false, // ما بدنا "Recent" لأنه مش مجلد حقيقي
    );
    return paths;
  }
}
