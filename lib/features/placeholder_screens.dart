import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/constants/app_colors.dart';
import '../core/constants/app_sizes.dart';
import '../core/router/app_router.dart';
import '../data/models/media_item.dart';
import '../data/repositories/media_repository.dart';
import 'home/widgets/media_grid_item.dart';

// ── واجهة "Coming soon" عصرية مشتركة ─────────────────────────
class _ComingSoon extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool showBack;
  const _ComingSoon({
    required this.title,
    required this.icon,
    this.showBack = false,
  });

  static const subtitle = 'Coming soon';

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: AppColors.lightBackground,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 16, 6),
                child: Row(
                  children: [
                    if (showBack) ...[
                      _CircleBtn(
                        icon: Icons.arrow_back_rounded,
                        onTap: () => context.pop(),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          color: AppColors.navyDeep.withOpacity(0.06),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          icon,
                          color: AppColors.navyDeep.withOpacity(0.55),
                          size: 44,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// زر دائري عصري (رجوع/أيقونة) — أبيض بظل خفيف
class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 42,
    height: 42,
    child: Material(
      color: Colors.white,
      elevation: 1.5,
      shadowColor: AppColors.navyDeep.withOpacity(0.2),
      shape: CircleBorder(
        side: BorderSide(color: AppColors.navyDeep.withOpacity(0.06)),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Center(child: Icon(icon, color: AppColors.navyDeep, size: 20)),
      ),
    ),
  );
}

class OcrScreen extends StatelessWidget {
  final String assetId;
  const OcrScreen({super.key, required this.assetId});
  @override
  Widget build(BuildContext context) => const _ComingSoon(
    title: 'Extract Text',
    icon: Icons.text_fields_rounded,
    showBack: true,
  );
}

class VideoScreen extends StatelessWidget {
  final String assetId;
  const VideoScreen({super.key, required this.assetId});
  @override
  Widget build(BuildContext context) => const _ComingSoon(
    title: 'Video Summary',
    icon: Icons.movie_outlined,
    showBack: true,
  );
}

// ── تفاصيل الألبوم — بستايل الرئيسية العصري ──────────────────
class AlbumDetailScreen extends ConsumerStatefulWidget {
  final AlbumInfo album;
  const AlbumDetailScreen({super.key, required this.album});

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  final List<MediaItem> _items = [];
  final _scrollCtrl = ScrollController();
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 0;
  static const _pageSize = 120;

  @override
  void initState() {
    super.initState();
    _loadPage();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.extentAfter < 600) _loadPage();
  }

  Future<void> _loadPage() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);

    final repo = ref.read(mediaRepositoryProvider);
    final newItems = await repo.loadAlbumPage(
      albumPath: widget.album.path,
      page: _page,
      pageSize: _pageSize,
    );

    setState(() {
      _items.addAll(newItems);
      _page++;
      _hasMore = newItems.length >= _pageSize;
      _loading = false;
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
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
                    _CircleBtn(
                      icon: Icons.arrow_back_rounded,
                      onTap: () => context.pop(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.album.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          Text(
                            '${widget.album.count} items',
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
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
                          color: AppColors.navyDeep,
                        ),
                      )
                    : GridView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.all(AppSizes.gridSpacing),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: AppSizes.gridCrossAxisCount,
                              mainAxisSpacing: AppSizes.gridSpacing,
                              crossAxisSpacing: AppSizes.gridSpacing,
                            ),
                        itemCount: _items.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= _items.length) {
                            return const Center(
                              child: CircularProgressIndicator(
                                color: AppColors.navyDeep,
                                strokeWidth: 2,
                              ),
                            );
                          }
                          final item = _items[index];
                          return MediaGridItem(
                            item: item,
                            onTap: () => context
                                .push<String>(
                                  AppRoutes.detail,
                                  extra: {'id': item.id, 'items': _items},
                                )
                                .then((removedId) {
                                  // انحذفت/انتقلت للسكيور — نشيلها من الشبكة فوراً
                                  if (removedId != null && mounted) {
                                    setState(
                                      () => _items.removeWhere(
                                        (e) => e.id == removedId,
                                      ),
                                    );
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
}
