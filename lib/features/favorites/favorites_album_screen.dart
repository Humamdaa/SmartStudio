import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/router/app_router.dart';
import '../../data/models/media_item.dart';
import '../home/widgets/media_grid_item.dart';
import 'favorites_controller.dart';

/// ألبوم المفضلة — يعرض الصور/الفيديوهات اللي عليها قلب.
class FavoritesAlbumScreen extends ConsumerStatefulWidget {
  const FavoritesAlbumScreen({super.key});

  @override
  ConsumerState<FavoritesAlbumScreen> createState() =>
      _FavoritesAlbumScreenState();
}

class _FavoritesAlbumScreenState extends ConsumerState<FavoritesAlbumScreen> {
  final Map<String, MediaItem> _cache = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _resolve(ref.read(favoritesProvider));
  }

  Future<void> _resolve(Set<String> ids) async {
    // أي صورة ما عاد إلها وجود على الجهاز (انحذفت أو راحت للمجلد الآمن)
    // منشيلها من المفضلة، وإلا بيضل العدّاد يحسبها.
    final missing = <String>{};
    for (final id in ids) {
      if (_cache.containsKey(id)) continue;
      final asset = await AssetEntity.fromId(id);
      if (asset != null) {
        _cache[id] = MediaItem.fromAsset(asset);
      } else {
        missing.add(id);
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
    if (missing.isNotEmpty) {
      await ref.read(favoritesProvider.notifier).removeMissing(missing);
    }
  }

  @override
  Widget build(BuildContext context) {
    // إذا تغيّرت المفضلة (أُضيف عنصر) نحلّه؛ والإزالة بتنعكس بالفلترة تحت.
    ref.listen<Set<String>>(favoritesProvider, (_, next) => _resolve(next));
    final favs = ref.watch(favoritesProvider);
    // آخر صورة أضيفت للمفضلة تظهر أول واحدة (نعكس ترتيب الإضافة)
    final items = favs.toList().reversed
        .where(_cache.containsKey)
        .map((e) => _cache[e]!)
        .toList();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: AppColors.lightBackground,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 16, 8),
                child: Row(
                  children: [
                    _CircleBack(onTap: () => context.pop()),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Favorites',
                              style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5)),
                          Text('${favs.length} items',
                              style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: AppColors.navyDeep))
                    : items.isEmpty
                        ? _empty()
                        : GridView.builder(
                            padding:
                                const EdgeInsets.all(AppSizes.gridSpacing),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: AppSizes.gridCrossAxisCount,
                              mainAxisSpacing: AppSizes.gridSpacing,
                              crossAxisSpacing: AppSizes.gridSpacing,
                            ),
                            itemCount: items.length,
                            itemBuilder: (context, i) {
                              final item = items[i];
                              return MediaGridItem(
                                item: item,
                                onTap: () => context.push<String>(
                                  AppRoutes.detail,
                                  extra: {'id': item.id, 'items': items},
                                ).then((removedId) {
                                  // انحذفت/انتقلت للسكيور — بطّل مفضّلة فوراً
                                  if (removedId != null) {
                                    ref
                                        .read(favoritesProvider.notifier)
                                        .toggle(removedId);
                                  }
                                }),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.errorRed.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.favorite_border_rounded,
                  color: AppColors.errorRed.withOpacity(0.6), size: 44),
            ),
            const SizedBox(height: 20),
            const Text('No favorites yet',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            const Text('Tap the heart on any photo to add it here',
                style: TextStyle(color: AppColors.textHint, fontSize: 13)),
          ],
        ),
      );
}

class _CircleBack extends StatelessWidget {
  final VoidCallback onTap;
  const _CircleBack({required this.onTap});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 42,
        height: 42,
        child: Material(
          color: Colors.white,
          elevation: 1.5,
          shadowColor: AppColors.navyDeep.withOpacity(0.2),
          shape: CircleBorder(
              side: BorderSide(color: AppColors.navyDeep.withOpacity(0.06))),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: const Center(
                child: Icon(Icons.arrow_back_rounded,
                    color: AppColors.navyDeep, size: 20)),
          ),
        ),
      );
}
