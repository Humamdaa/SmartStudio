import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/router/app_router.dart';
import '../../data/models/media_item.dart';
import '../../services/secure_storage_service.dart';
import '../../services/album_service.dart';
import '../../core/providers/gallery_refresh_provider.dart';
import '../selection/selection_actions.dart';
import '../favorites/favorites_controller.dart';
import '../secure/secure_screen.dart';
import '../albums/album_picker_sheet.dart';
import '../people/photo_people_sheet.dart';
import '../people/face_sticker_sheet.dart';
// ═══════════════════════════════════════════════════════════════
// DetailScreen
//
// يستقبل:
//   - assetId   : ID الصورة/الفيديو اللي ضُغط عليها
//   - allItems  : كل قائمة الـ MediaItem (الصور والفيديوهات)
//                 عشان نقدر نتنقل بالسوايب يمين/يسار
//
// السوايب يعمل بـ PageView.builder:
//   - كل صفحة = صورة أو فيديو
//   - نبدأ على الـ index تبع الصورة المضغوطة
//   - لما تتغير الصفحة نوقف الفيديو القديم ونهيئ الجديد
// ═══════════════════════════════════════════════════════════════
class DetailScreen extends ConsumerStatefulWidget {
  final String assetId;
  final List<MediaItem> allItems; // القائمة الكاملة للسوايب

  const DetailScreen({
    super.key,
    required this.assetId,
    required this.allItems,
  });

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  late PageController _pageCtrl;
  late int _currentIndex;
  bool _uiVisible = true;
  bool _isZoomed = false;

  // نخزن VideoController لكل فيديو تم تهيئته
  // Key = index في القائمة
  final Map<int, _VideoState> _videoStates = {};

  @override
  void initState() {
    super.initState();

    // نجد index الصورة المضغوطة في القائمة
    _currentIndex = widget.allItems.indexWhere(
      (item) => item.id == widget.assetId,
    );

    // إذا ما لقيناها نبدأ من 0
    if (_currentIndex < 0) _currentIndex = 0;

    _pageCtrl = PageController(initialPage: _currentIndex);

    // هيئ الفيديو الأول إذا كان فيديو
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prepareVideoAt(_currentIndex);
    });
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    // نتخلص من كل الـ video controllers
    for (final vs in _videoStates.values) {
      vs.chewie?.dispose();
      vs.player.dispose();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ─────────────────────────────────────────
  // تهيئة فيديو بـ index معين
  // نسبق ونهيئ الفيديو التالي/السابق أيضاً (prefetch)
  // ─────────────────────────────────────────
  Future<void> _openFaceSticker() async {
  if (_current.isVideo) return;
  await showFaceStickerSheet(
    context: context,
    item: _current,
  );
}

  Future<void> _prepareVideoAt(int index) async {
    final item = widget.allItems[index];
    if (!item.isVideo) return;
    if (_videoStates.containsKey(index)) return; // مهيأ مسبقاً

    final file = await item.asset.originFile;
    if (file == null || !mounted) return;

    final player = VideoPlayerController.file(file);
    await player.initialize();

    final chewie = ChewieController(
      videoPlayerController: player,
      autoPlay: false, // لا يشتغل تلقائي — فقط لما يكون الصفحة الحالية
      looping: false,
      // MediaStore يعطي أبعاد الفيديو بدون احتساب دوران التسجيل، فمقطع عمودي
      // مخزّن 1920x1080 كان يُعرض مضغوطًا. المشغّل بعد initialize يعطي النسبة
      // الحقيقية للعرض والدوران مطبّق عليها.
      aspectRatio: player.value.aspectRatio,
      materialProgressColors: ChewieProgressColors(
        playedColor: AppColors.mintAccent,
        handleColor: AppColors.mintAccent,
        backgroundColor: Colors.white24,
        bufferedColor: Colors.white38,
      ),
    );

    if (mounted) {
      setState(() {
        _videoStates[index] = _VideoState(player: player, chewie: chewie);
      });
    }
  }

  // ─────────────────────────────────────────
  // لما تتغير الصفحة بالسوايب
  // ─────────────────────────────────────────
  void _onPageChanged(int newIndex) {
    // وقّف الفيديو السابق
    final oldVs = _videoStates[_currentIndex];
    oldVs?.player.pause();

    setState(() => _currentIndex = newIndex);

    // هيئ الفيديو الجديد إذا كان فيديو
    _prepareVideoAt(newIndex);

    // prefetch: هيئ الفيديو التالي والسابق مسبقاً
    if (newIndex + 1 < widget.allItems.length) {
      _prepareVideoAt(newIndex + 1);
    }
    if (newIndex - 1 >= 0) {
      _prepareVideoAt(newIndex - 1);
    }
  }

  void _toggleUI() {
    setState(() => _uiVisible = !_uiVisible);
    if (_uiVisible) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    }
  }

  MediaItem get _current => widget.allItems[_currentIndex];

  Future<void> _shareCurrent() async {
    await SelectionActions.share([_current]);
  }

  Future<void> _deleteCurrent() async {
    final id = _current.id;
    final deleted = await SelectionActions.delete([_current]);
    if (deleted.isNotEmpty && mounted) context.pop(id);
  }

  void _editCurrent() => context.push(AppRoutes.editing, extra: _current.id);
  void _extractText() => context.push(AppRoutes.ocr, extra: _current.id);

  // ── نقل الصورة/الفيديو الحالي للمجلد الآمن ────────────────────
  Future<void> _secureCurrent() async {
    final item = _current;
    final secureFile = await SecureStorageService.instance.addAsset(item.asset);
    if (!mounted) return;

    if (secureFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to move to Secure Folder')),
      );
      return;
    }

    ref.read(secureRepoProvider).save(secureFile);

    // الأصل انحذف من المعرض فعلياً — ما نقدر نضل بهاي الصفحة
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Moved to Secure Folder')));
    // نرجّع الـ id حتى الشاشة اللي فتحتنا تشيله من القائمة فوراً
    context.pop(item.id);
  }

  // ── معلومات الملف الحقيقية ──────────────────────────────────
  Future<void> _showInfo() async {
    final item = _current;

    // بعض الملفات ممكن تصير غير موجودة (مثلاً انحذفت/انتقلت)
    // فما لازم نكسر الشاشة — نعرض اللي عنا ونتجاهل الباقي بهدوء.
    String sizeLabel = 'Unknown';
    try {
      final file = await item.asset.file;
      final bytes = await file?.length() ?? 0;
      if (bytes > 0) {
        sizeLabel = bytes < 1024 * 1024
            ? '${(bytes / 1024).toStringAsFixed(1)} KB'
            : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
      }
    } catch (_) {
      // الملف مش موجود فعلياً على الجهاز — منكمل بباقي المعلومات
    }

    String? mimeType;
    try {
      mimeType = await item.asset.mimeTypeAsync;
    } catch (_) {}

    double? lat, lng;
    try {
      final latLng = await item.asset.latlngAsync();
      lat = latLng?.latitude;
      lng = latLng?.longitude;
    } catch (_) {}
    final hasLocation = lat != null && lng != null;

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(item.title.isEmpty ? 'File Info' : item.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow('Name', item.title.isEmpty ? '—' : item.title),
              _InfoRow('Type', item.isVideo ? 'Video' : 'Image'),
              if (mimeType != null) _InfoRow('Format', mimeType),
              _InfoRow('Resolution', '${item.width}×${item.height}'),
              _InfoRow('Size', sizeLabel),
              _InfoRow('Date', item.createDate.toString().split('.').first),
              if (item.isVideo)
                _InfoRow('Duration', '${item.asset.videoDuration.inSeconds}s'),
              if (hasLocation)
                _InfoRow(
                  'Location',
                  '${lat!.toStringAsFixed(5)}, ${lng!.toStringAsFixed(5)}',
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ── نسخ/نقل الصورة لمجلد حقيقي على الجهاز ────────────────────
  // نستنى إغلاق شيت الخيارات بالكامل قبل ما نفتح شيت الاختيار،
  // بدل ما نفتحه بنفس اللحظة (كان يسبب تعارض بالتنقّل).
  Future<void> _pickAlbum({required bool move}) async {
    if (!mounted) return;
    final item = _current;

    final choice = await showModalBottomSheet<AlbumTarget>(
      context: context,
      backgroundColor: const Color(0xFF1C2B3A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => AlbumPickerSheet(
        title: move ? 'Move to album' : 'Copy to album',
        currentAlbumId: item.asset.relativePath,
      ),
    );
    if (choice == null || !mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(move ? 'Moving…' : 'Copying…')));

    final svc = AlbumService.instance;
    bool ok;
    if (move) {
      ok = choice.isNew
          ? await svc.moveToNewAlbum(
              assets: [item.asset],
              albumName: choice.name,
            )
          : await svc.moveToExisting(asset: item.asset, target: choice.path!);
    } else {
      ok = choice.isNew
          ? await svc.copyToNewAlbum(asset: item.asset, albumName: choice.name)
          : await svc.copyToExisting(asset: item.asset, target: choice.path!);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? (move
                    ? 'Moved to "${choice.name}"'
                    : 'Copied to "${choice.name}"')
              : 'Operation failed',
        ),
        backgroundColor: ok ? null : AppColors.errorRed,
      ),
    );

    if (!ok) return;
    // المعرض تغيّر — خلّي الشاشات تعيد التحميل
    ref.read(galleryNeedsRefreshProvider.notifier).state = true;
    // بالنقل الملف ما عاد بمكانه القديم، فمنطلع من صفحة العرض
    if (move) context.pop(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final isFav = ref.watch(favoritesProvider).contains(_current.id);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _uiVisible
          ? AppBar(
              backgroundColor: Colors.black.withOpacity(0.55),
              foregroundColor: Colors.white,
              elevation: 0,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _current.asset.title ?? '',
                    style: const TextStyle(fontSize: 14, color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    // عرض الموضع: "12 / 240"
                    '${_currentIndex + 1} / ${widget.allItems.length}',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ],
              ),
              actions: [
                if (!_current.isVideo)
                  IconButton(
                    tooltip: 'البحث عن صور مشابهة',
                    icon: const Icon(
                      Icons.image_search_outlined,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      context.push(AppRoutes.visualSearch, extra: _current.id);
                    },
                  ),
                IconButton(
                  tooltip: 'Favorite',
                  icon: Icon(
                    isFav
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: isFav ? AppColors.errorRed : Colors.white,
                  ),
                  onPressed: () =>
                      ref.read(favoritesProvider.notifier).toggle(_current.id),
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  onPressed: _showOptions,
                ),
              ],
            )
          : null,
      body: PageView.builder(
        controller: _pageCtrl,
        onPageChanged: _onPageChanged,
        // يبني الصفحة المجاورة مسبقًا، فالسوايب ما يستنى فكّ ترميز صورة جديدة.
        allowImplicitScrolling: true,
        // وقت ما تكون الصورة مكبّرة نوقف تبديل الصفحات حتى السحب يحرّك الصورة.
        physics: _isZoomed
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        itemCount: widget.allItems.length,
        itemBuilder: (context, index) {
          final item = widget.allItems[index];
          return item.isVideo
              ? _VideoPage(
                  item: item,
                  videoState: _videoStates[index],
                  isActive: index == _currentIndex,
                  onTap: _toggleUI,
                )
              : _ImagePage(
                  item: item,
                  onTap: _toggleUI,
                  onZoomChanged: (z) {
                    if (z != _isZoomed) setState(() => _isZoomed = z);
                  },
                );
        },
      ),
      bottomNavigationBar: _uiVisible
          ? _BottomToolbar(
              item: _current,
              onEdit: _editCurrent,
              onShare: _shareCurrent,
              onDelete: _deleteCurrent,
              onSecure: _secureCurrent,
            )
          : null,
    );
  }

  // منستنى إغلاق الشيت بالكامل (await) قبل ما ننفّذ الفعل المختار —
  // فتح دايالوج/شيت جديد فوراً بنفس اللحظة كان يسبب تعارض بالتنقل.
  Future<void> _showOptions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1C2B3A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _OptionsSheet(isVideo: _current.isVideo),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'info':
        _showInfo();
        break;
      case 'ocr':
        _extractText();
        break;
      case 'people':
        showPhotoPeopleSheet(context: context, item: _current);
        break;
      case 'copy':
        _pickAlbum(move: false);
        break;
      case 'move':
        _pickAlbum(move: true);
        break;
        case 'faceSticker':
  await _openFaceSticker();
  break;
    }
  }
}

// ─────────────────────────────────────────
// صفحة صورة واحدة
// ─────────────────────────────────────────
class _ImagePage extends StatefulWidget {
  final MediaItem item;
  final VoidCallback onTap;
  final ValueChanged<bool>? onZoomChanged;
  const _ImagePage({
    required this.item,
    required this.onTap,
    this.onZoomChanged,
  });

  @override
  State<_ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<_ImagePage>
    with SingleTickerProviderStateMixin {
  final TransformationController _tc = TransformationController();
  late final AnimationController _animCtrl;
  Animation<Matrix4>? _anim;
  TapDownDetails? _doubleTapDetails;
  bool _lastZoomed = false;

  @override
  void initState() {
    super.initState();
    _animCtrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 260),
        )..addListener(() {
          if (_anim != null) _tc.value = _anim!.value;
        });
    _tc.addListener(_onTransform);
  }

  // نبلّغ الأب لمّا تتغيّر حالة التكبير (عشان يوقف/يرجّع تبديل الصفحات).
  void _onTransform() {
    final zoomed = _tc.value.getMaxScaleOnAxis() > 1.05;
    if (zoomed != _lastZoomed) {
      if (mounted) {
        setState(() => _lastZoomed = zoomed);
      } else {
        _lastZoomed = zoomed;
      }
      widget.onZoomChanged?.call(zoomed);
    }
  }

  @override
  void dispose() {
    _tc.removeListener(_onTransform);
    _animCtrl.dispose();
    _tc.dispose();
    super.dispose();
  }

  // دبل-تاب: يكبّر نحو نقطة اللمس أو يرجّع للوضع الطبيعي — بحركة سلسة.
  void _handleDoubleTap() {
    final bool isZoomed = _tc.value.getMaxScaleOnAxis() > 1.05;
    final Matrix4 end;
    if (isZoomed) {
      end = Matrix4.identity();
    } else {
      const double scale = 2.8;
      final Offset pos = _doubleTapDetails?.localPosition ?? Offset.zero;
      end = Matrix4.identity()
        ..translate(-pos.dx * (scale - 1), -pos.dy * (scale - 1))
        ..scale(scale);
    }
    _anim = Matrix4Tween(
      begin: _tc.value,
      end: end,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _animCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _doubleTapDetails = d,
      onDoubleTap: _handleDoubleTap,
      child: Center(
        child: InteractiveViewer(
          transformationController: _tc,
          minScale: 1.0,
          maxScale: 6.0,
          // التحريك مسموح فقط وقت التكبير. مع boundaryMargin الأكبر من الصورة،
          // كان التحريك شغّالًا حتى بمقياس 1.0، فالسحب الأفقي يروح للصورة
          // نفسها بدل الانتقال للصفحة التالية — الصورة تزيح جانبًا وتعلق.
          panEnabled: _lastZoomed,
          // هامش يسمح بالتحريك المريح لكل أجزاء الصورة المكبّرة.
          boundaryMargin: const EdgeInsets.all(64),
          child: Image(
            // الدقّة الكاملة غالية على كل صفحة. منعرض نسخة بحجم الشاشة
            // للتقليب السريع، ومنجيب الأصل لمّا يكبّر المستخدم فعلًا.
            image: AssetEntityImageProvider(
              widget.item.asset,
              isOriginal: _lastZoomed,
              thumbnailSize: const ThumbnailSize(1440, 1440),
            ),
            // يمنع وميض التبديل بين نسخة الشاشة والأصل.
            gaplessPlayback: true,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) {
              if (progress == null) return child;
              return Stack(
                alignment: Alignment.center,
                children: [
                  Image(
                    image: AssetEntityImageProvider(
                      widget.item.asset,
                      isOriginal: false,
                      thumbnailSize: const ThumbnailSize.square(600),
                    ),
                    fit: BoxFit.contain,
                  ),
                  CircularProgressIndicator(
                    value: progress.expectedTotalBytes != null
                        ? progress.cumulativeBytesLoaded /
                              progress.expectedTotalBytes!
                        : null,
                    color: AppColors.mintAccent,
                    strokeWidth: 2,
                  ),
                ],
              );
            },
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white38,
                size: 48,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// صفحة فيديو واحد
// ─────────────────────────────────────────
class _VideoPage extends StatelessWidget {
  final MediaItem item;
  final _VideoState? videoState; // null = لسا بيتهيأ
  final bool isActive;
  final VoidCallback onTap;

  const _VideoPage({
    required this.item,
    required this.videoState,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // لسا بيتحمل
    if (videoState == null) {
      return GestureDetector(
        onTap: onTap,
        child: const Center(
          child: CircularProgressIndicator(color: AppColors.mintAccent),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Center(
        child: AspectRatio(
          aspectRatio: videoState!.player.value.aspectRatio,
          child: Chewie(controller: videoState!.chewie!),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// Model داخلي لحالة الفيديو
// ─────────────────────────────────────────
class _VideoState {
  final VideoPlayerController player;
  final ChewieController? chewie;
  _VideoState({required this.player, this.chewie});
}

// ─────────────────────────────────────────
// Bottom Toolbar
// ─────────────────────────────────────────
class _BottomToolbar extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final VoidCallback onSecure;
  const _BottomToolbar({
    required this.item,
    required this.onEdit,
    required this.onShare,
    required this.onDelete,
    required this.onSecure,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // التعديل للصور فقط
          if (!item.isVideo)
            _Btn(icon: Icons.tune_rounded, label: 'Edit', onTap: onEdit),
          _Btn(icon: Icons.ios_share_rounded, label: 'Share', onTap: onShare),
          _Btn(
            icon: Icons.lock_outline_rounded,
            label: 'Secure',
            onTap: () => _confirmSecure(context, onSecure),
          ),
          _Btn(
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            onTap: onDelete,
            color: AppColors.errorRed,
          ),
        ],
      ),
    );
  }
}

void _confirmSecure(BuildContext context, VoidCallback onConfirm) {
  showDialog(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('Move to Secure Folder?'),
      content: const Text(
        'This file will be hidden and removed from your gallery.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(dialogCtx);
            onConfirm();
          },
          child: const Text('Move'),
        ),
      ],
    ),
  );
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;
  const _Btn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 25),
          const SizedBox(height: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}

// ─────────────────────────────────────────
// Options Sheet — كل خيار بيسكّر الشيت ويرجّع مفتاح الفعل المختار
// ─────────────────────────────────────────
class _OptionsSheet extends StatelessWidget {
  final bool isVideo;
  const _OptionsSheet({required this.isVideo});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSizes.lg),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 20),
        const _Opt(
          icon: Icons.info_outline,
          label: 'File Info',
          action: 'info',
        ),
        if (!isVideo)
          const _Opt(
            icon: Icons.text_fields,
            label: 'Live Text / OCR',
            action: 'ocr',
          ),
        if (!isVideo)
          const _Opt(
            icon: Icons.face_retouching_natural,
            label: 'People in Photo',
            action: 'people',
          ),
          if (!isVideo)
  const _Opt(
    icon: Icons.emoji_emotions_outlined,
    label: 'Face Sticker',
    action: 'faceSticker',
  ),
        const _Opt(
          icon: Icons.copy_all_outlined,
          label: 'Copy to Album',
          action: 'copy',
        ),
        const _Opt(
          icon: Icons.drive_file_move_outline,
          label: 'Move to Album',
          action: 'move',
        ),
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  // القيم الطويلة (اسم ملف، إحداثيات...) كانت تطلّع خطوط التجاوز
  // الصفراء لأن الـ Row ما كان يسمح للنص يلتف. صار عنده مساحة مرنة.
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            softWrap: true,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

class _Opt extends StatelessWidget {
  final IconData icon;
  final String label;
  final String action;
  const _Opt({required this.icon, required this.label, required this.action});

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: Colors.white70),
    title: Text(label, style: const TextStyle(color: Colors.white)),
    onTap: () => Navigator.pop(context, action),
  );
}
