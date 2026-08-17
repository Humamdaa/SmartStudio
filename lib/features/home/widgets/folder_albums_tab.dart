import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:go_router/go_router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/router/app_router.dart';
import '../../../data/repositories/media_repository.dart';
import '../../../services/album_service.dart';
import '../../albums/asset_picker_screen.dart';
import '../../favorites/favorites_controller.dart';
import '../home_screen.dart';

class FolderAlbumsState {
  final List<AlbumInfo> albums;
  final bool loading;
  final String? error;

  const FolderAlbumsState({
    this.albums = const [],
    this.loading = false,
    this.error,
  });

  FolderAlbumsState copyWith({
    List<AlbumInfo>? albums,
    bool? loading,
    String? error,
  }) => FolderAlbumsState(
    albums: albums ?? this.albums,
    loading: loading ?? this.loading,
    error: error,
  );
}

class FolderAlbumsController extends StateNotifier<FolderAlbumsState> {
  final MediaRepository _repo;

  FolderAlbumsController(this._repo) : super(const FolderAlbumsState()) {
    load();
  }

  Future<void> load() async {
    state = state.copyWith(loading: true);
    try {
      final albums = await _repo.getFolderAlbums();
      state = state.copyWith(albums: albums, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: 'Failed to load albums');
    }
  }
}

final folderAlbumsProvider =
    StateNotifierProvider<FolderAlbumsController, FolderAlbumsState>((ref) {
      return FolderAlbumsController(ref.read(mediaRepositoryProvider));
    });

class FolderAlbumsTab extends ConsumerStatefulWidget {
  const FolderAlbumsTab({super.key});

  @override
  ConsumerState<FolderAlbumsTab> createState() => _FolderAlbumsTabState();
}

class _FolderAlbumsTabState extends ConsumerState<FolderAlbumsTab> {
  @override
  void initState() {
    super.initState();
    // نعيد التحميل كل مرة نفتح فيها التبويب — بدونها كانت الألبومات
    // تضل تعرض صور محذوفة لأن القائمة كانت تتحمّل مرة وحدة بس.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(folderAlbumsProvider.notifier).load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(folderAlbumsProvider);
    final favs = ref.watch(favoritesProvider);

    if (state.loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.navyDeep),
      );
    }

    if (state.error != null) {
      return Center(
        child: Text(
          state.error!,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    final albums = state.albums;
    return Column(
      children: [
        // زر إنشاء ألبوم — ينشئ مجلد حقيقي على الجهاز
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Text(
                '${albums.length} folders · hold to delete',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () => _createAlbum(context, ref),
                icon: const Icon(
                  Icons.create_new_folder_outlined,
                  color: Colors.white,
                  size: 18,
                ),
                label: const Text(
                  'New Album',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.navyDeep,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(100),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 18,
              crossAxisSpacing: 14,
              childAspectRatio: 0.82,
            ),
            // أول كرت دائماً = المفضلة، بعده ألبومات الجهاز.
            itemCount: albums.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return _FavoritesCard(
                  count: favs.length,
                  // آخر صورة انضافت للمفضلة = غلاف الألبوم
                  coverAssetId: favs.isEmpty ? null : favs.last,
                  onTap: () => context.push(AppRoutes.favorites),
                );
              }
              final album = albums[index - 1];
              return _AlbumCard(
                album: album,
                onTap: () => context.push(AppRoutes.albumDetail, extra: album),
                onLongPress: () => _confirmDeleteAlbum(context, ref, album),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── حذف ألبوم ────────────────────────────────────────────────
  // الألبوم مجلد حقيقي، وحذفه معناه حذف كل الصور اللي جوّاه —
  // عملية ما إلها رجعة، فمنوضّح العدد ومنطلب تأكيد صريح.
  Future<void> _confirmDeleteAlbum(
    BuildContext context,
    WidgetRef ref,
    AlbumInfo album,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Delete "${album.name}"?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This deletes all ${album.count} item(s) inside this album '
              'from your device.',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 10),
            const Text(
              'The photos themselves are deleted — not just the album.',
              style: TextStyle(fontSize: 12, color: AppColors.errorRed),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.errorRed),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Deleting album…')));

    // أندرويد 11+ بيعرض نافذة تأكيد نظام كمان — المستخدم لازم يوافق
    final deleted = await AlbumService.instance.deleteAlbum(
      album.path,
      knownCount: album.count,
    );

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deleted > 0
              ? 'Deleted "${album.name}" ($deleted item(s))'
              : 'Nothing was deleted',
        ),
        backgroundColor: deleted > 0 ? null : AppColors.errorRed,
      ),
    );

    if (deleted > 0) {
      ref.read(folderAlbumsProvider.notifier).load();
      ref.read(homeControllerProvider.notifier).loadFirstPage();
    }
  }

  // أندرويد ما بيعرف "مجلد فاضي" بالمعرض، فمنطلب من المستخدم
  // يختار صور وننقلها للمجلد الجديد — وهيك بينخلق فعلياً.
  Future<void> _createAlbum(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      // لازم نستخدم كونتكست الدايالوج نفسه — استخدام الكونتكست الخارجي
      // كان يسكّر الصفحة كاملة بدل الدايالوج ويخلي "إنشاء" ما يشتغل
      builder: (dialogCtx) => AlertDialog(
        title: const Text('New album'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Album name'),
            ),
            const SizedBox(height: 12),
            const Text(
              'Next you\'ll pick the photos to move into it.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
            child: const Text('Next'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !context.mounted) return;

    final picked = await Navigator.of(context).push<List<AssetEntity>>(
      MaterialPageRoute(
        builder: (_) => AssetPickerScreen(title: 'Move to "$name"'),
      ),
    );
    if (picked == null || picked.isEmpty || !context.mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Creating album…')));

    final ok = await AlbumService.instance.moveToNewAlbum(
      assets: picked,
      albumName: name,
    );

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Album "$name" created with ${picked.length} item(s)'
              : 'Could not create the album',
        ),
        backgroundColor: ok ? null : AppColors.errorRed,
      ),
    );

    if (ok) {
      ref.read(folderAlbumsProvider.notifier).load();
      ref.read(homeControllerProvider.notifier).loadFirstPage();
    }
  }
}

// كرت "المفضلة" — أول كرت بالألبومات، يفتح ألبوم المفضلة.
// الغلاف = آخر صورة انضافت للمفضلة (وإذا فاضي منعرض التدرّج بالأيقونة).
class _FavoritesCard extends StatelessWidget {
  final int count;
  final String? coverAssetId;
  final VoidCallback onTap;
  const _FavoritesCard({
    required this.count,
    required this.coverAssetId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.navyDeep.withOpacity(0.20),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (coverAssetId != null)
                      FutureBuilder<AssetEntity?>(
                        future: AssetEntity.fromId(coverAssetId!),
                        builder: (_, snap) {
                          if (snap.data == null) return _gradient();
                          return Image(
                            image: AssetEntityImageProvider(
                              snap.data!,
                              isOriginal: false,
                              thumbnailSize: const ThumbnailSize.square(400),
                            ),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _gradient(),
                          );
                        },
                      )
                    else
                      _gradient(),
                    // شارة القلب فوق الغلاف حتى يضل الكرت مميّز
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.45),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.favorite_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              'Favorites',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              '$count items',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _gradient() => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AppColors.navyDeep, AppColors.skyBlue],
      ),
    ),
    child: const Center(
      child: Icon(Icons.favorite_rounded, color: Colors.white, size: 42),
    ),
  );
}

class _AlbumCard extends StatelessWidget {
  final AlbumInfo album;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _AlbumCard({
    required this.album,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.navyDeep.withOpacity(0.10),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: album.coverAsset != null
                    ? Image(
                        image: AssetEntityImageProvider(
                          album.coverAsset!,
                          isOriginal: false,
                          thumbnailSize: const ThumbnailSize.square(400),
                        ),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (_, __, ___) => _placeholder(),
                      )
                    : _placeholder(),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  album.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${album.count} items',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: AppColors.navyDeep.withOpacity(0.06),
      child: const Center(
        child: Icon(
          Icons.photo_album_outlined,
          color: AppColors.textHint,
          size: 40,
        ),
      ),
    );
  }
}
