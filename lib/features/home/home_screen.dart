import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/constants/app_strings.dart';
import '../../core/router/app_router.dart';
import '../../data/models/media_item.dart';
import '../../data/repositories/media_repository.dart';
import 'widgets/media_grid_item.dart';
import 'widgets/folder_albums_tab.dart';
import '../selection/selection_controller.dart';
import '../selection/selection_actions.dart';
import '../../core/providers/gallery_refresh_provider.dart';
import '../albums/indexing_providers.dart';

enum MediaFilter { all, images, videos, folders }

class HomeState {
  final List<MediaItem> items;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final String? error;
  final PermissionState? permissionStatus;

  final MediaFilter filter;
  final int currentPage;
  final int totalCount;

  const HomeState({
    this.items = const [],
    this.loading = false,
    this.loadingMore = false,
    this.hasMore = true,
    this.error,
    this.permissionStatus,
    this.filter = MediaFilter.all,
    this.currentPage = 0,
    this.totalCount = 0,
  });

  bool get hasPermission =>
      permissionStatus == PermissionState.authorized ||
      permissionStatus == PermissionState.limited;

  HomeState copyWith({
    List<MediaItem>? items,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    String? error,
    PermissionState? permissionStatus,
    MediaFilter? filter,
    int? currentPage,
    int? totalCount,
  }) => HomeState(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    hasMore: hasMore ?? this.hasMore,
    error: error,
    permissionStatus: permissionStatus ?? this.permissionStatus,
    filter: filter ?? this.filter,
    currentPage: currentPage ?? this.currentPage,
    totalCount: totalCount ?? this.totalCount,
  );
}

class HomeController extends StateNotifier<HomeState> {
  final MediaRepository _repo;
  static const _pageSize = 120;

  HomeController(this._repo) : super(const HomeState()) {
    loadFirstPage();
  }

  RequestType get _requestType {
    switch (state.filter) {
      case MediaFilter.images:
        return RequestType.image;
      case MediaFilter.videos:
        return RequestType.video;
      case MediaFilter.all:
      case MediaFilter.folders:
        return RequestType.common;
    }
  }

  Future<void> loadFirstPage() async {
    if (state.filter == MediaFilter.folders) return;

    state = state.copyWith(
      loading: true,
      items: [],
      currentPage: 0,
      hasMore: true,
      error: null,
    );

    final permission = await _repo.requestPermission();

    state = state.copyWith(permissionStatus: permission);

    if (!state.hasPermission) {
      state = state.copyWith(loading: false, error: AppStrings.errorPermission);
      return;
    }

    try {
      final total = await _repo.getTotalCount(_requestType);
      final items = await _repo.loadPage(
        type: _requestType,
        page: 0,
        pageSize: _pageSize,
      );

      state = state.copyWith(
        items: items,
        loading: false,
        currentPage: 0,
        totalCount: total,
        hasMore: items.length >= _pageSize,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: 'Something went wrong: $e');
    }
  }

  Future<void> loadNextPage() async {
    if (state.loadingMore || !state.hasMore || state.loading) return;
    final permission = await _repo.checkPermission();
    if (permission != PermissionState.authorized &&
        permission != PermissionState.limited) {
      state = state.copyWith(
        permissionStatus: permission,
        error: AppStrings.errorPermission,
      );
      return;
    }

    state = state.copyWith(loadingMore: true);

    try {
      final nextPage = state.currentPage + 1;
      final newItems = await _repo.loadPage(
        type: _requestType,
        page: nextPage,
        pageSize: _pageSize,
      );

      if (newItems.isEmpty) {
        state = state.copyWith(loadingMore: false, hasMore: false);
        return;
      }

      state = state.copyWith(
        items: [...state.items, ...newItems],
        loadingMore: false,
        currentPage: nextPage,
        hasMore: newItems.length >= _pageSize,
      );
    } catch (e) {
      state = state.copyWith(loadingMore: false);
    }
  }

  Future<void> setFilter(MediaFilter filter) async {
    if (state.filter == filter) return;
    state = state.copyWith(filter: filter);
    if (filter != MediaFilter.folders) {
      await loadFirstPage();
    }
  }

  /// إزالة عناصر من القائمة بعد حذفها فعلياً (بدون إعادة تحميل كاملة).
  void removeByIds(List<String> ids) {
    if (ids.isEmpty) return;
    final set = ids.toSet();
    final remaining = state.items.where((it) => !set.contains(it.id)).toList();
    final newTotal = state.totalCount - ids.length;
    state = state.copyWith(
      items: remaining,
      totalCount: newTotal < 0 ? 0 : newTotal,
    );
  }

  Future<void> onAppResumed() async {
    final permission = await _repo.checkPermission();
    if (permission != state.permissionStatus) {
      state = state.copyWith(permissionStatus: permission);
      if (state.hasPermission) {
        await loadFirstPage();
      } else {
        state = state.copyWith(items: [], error: AppStrings.errorPermission);
      }
    }
  }
}

final homeControllerProvider = StateNotifierProvider<HomeController, HomeState>(
  (ref) {
    return HomeController(ref.read(mediaRepositoryProvider));
  },
);

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      ref.read(homeControllerProvider.notifier).onAppResumed();
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 800) {
      ref.read(homeControllerProvider.notifier).loadNextPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeControllerProvider);
    final ctrl = ref.read(homeControllerProvider.notifier);
    final sel = ref.watch(selectionProvider);
    final selCtrl = ref.read(selectionProvider.notifier);

    // أول ما تتوفّر الأذونات وتُحمّل الصور، منبلّش الفهرسة
    // تلقائيًا بالخلفية — المستخدم ما لازم يضغط أي زر.
    if (state.hasPermission && state.items.isNotEmpty) {
      ref.read(autoIndexStarterProvider).startOnce();
    }

    // أي عملية غيّرت المعرض (استعادة من السكيور، نقل/نسخ لمجلد،
    // حفظ صورة معدّلة...) بترفع هذا العلم — ومنعيد التحميل هون
    // بمكان واحد بدل ما نكرّر المنطق بكل شاشة.
    ref.listen<bool>(galleryNeedsRefreshProvider, (_, needsRefresh) {
      if (!needsRefresh) return;
      Future(() {
        if (!mounted) return;
        ref.read(galleryNeedsRefreshProvider.notifier).state = false;
        ctrl.loadFirstPage();
        ref.read(folderAlbumsProvider.notifier).load();
      });
    });

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: PopScope(
        canPop: !sel.active,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && sel.active) selCtrl.clear();
        },
        child: Scaffold(
          backgroundColor: AppColors.lightBackground,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                sel.active
                    ? _SelectionHeader(
                        count: sel.count,
                        onClose: selCtrl.clear,
                        onSelectAll: () => selCtrl.selectAll(state.items),
                      )
                    : _HomeHeader(
                        subtitle: _subtitle(state),
                        onSearch: () => context.go(AppRoutes.search),
                        onSecure: () => context.push(AppRoutes.secure),
                      ),
                if (!sel.active)
                  _FilterChips(
                    current: state.filter,
                    onChanged: ctrl.setFilter,
                  ),
                const SizedBox(height: 6),
                Expanded(child: _buildBody(context, state, ctrl, sel, selCtrl)),
              ],
            ),
          ),
          bottomNavigationBar: sel.active
              ? _SelectionActionBar(
                  onShare: _onShare,
                  onDelete: _onDelete,
                  onCollage: _onCollage,
                )
              : null,
        ),
      ),
    );
  }

  String _subtitle(HomeState state) {
    if (state.filter == MediaFilter.folders) return 'Your albums';
    if (state.totalCount > 0) return '${state.totalCount} items';
    return 'Smart gallery';
  }

  // ── أفعال التحديد المتعدد ────────────────────────────────────
  Future<void> _onShare() async {
    final items = ref.read(selectionProvider).items;
    if (items.isEmpty) return;
    try {
      final ok = await SelectionActions.share(items);
      if (!ok && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No shareable files')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Share failed: $e')));
      }
    }
  }

  // كولاج: بدها صورتين على الأقل (الفيديو ما بينحط بالكولاج)
  void _onCollage() {
    final items = ref.read(selectionProvider).items;
    final photos = items.where((e) => !e.isVideo).map((e) => e.asset).toList();
    if (photos.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least 2 photos for a collage')),
      );
      return;
    }
    ref.read(selectionProvider.notifier).clear();
    context.push(AppRoutes.collage, extra: photos);
  }

  Future<void> _onDelete() async {
    final items = ref.read(selectionProvider).items;
    if (items.isEmpty) return;

    try {
      // حذف فعلي — أندرويد بيعرض ديالوج تأكيد النظام تلقائياً (مش محتاجين ديالوج خاص).
      final deleted = await SelectionActions.delete(items);
      if (deleted.isNotEmpty) {
        ref.read(homeControllerProvider.notifier).removeByIds(deleted);
        ref.read(selectionProvider.notifier).clear();
        // الألبومات كمان لازم تتحدّث وإلا بتضل تعرض الصور المحذوفة
        ref.read(folderAlbumsProvider.notifier).load();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted ${deleted.length} item(s)')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Widget _buildBody(
    BuildContext context,
    HomeState state,
    HomeController ctrl,
    SelectionState sel,
    SelectionController selCtrl,
  ) {
    if (state.filter == MediaFilter.folders) {
      return const FolderAlbumsTab();
    }

    if (!state.hasPermission && state.permissionStatus != null) {
      return _PermissionDeniedView(onRetry: ctrl.loadFirstPage);
    }

    if (state.loading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppColors.navyDeep),
            SizedBox(height: 16),
            Text(
              AppStrings.loadingPhotos,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    if (state.error != null && state.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.photo_library_outlined,
                size: 64,
                color: AppColors.textHint,
              ),
              const SizedBox(height: 16),
              Text(
                state.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: ctrl.loadFirstPage,
                child: const Text(AppStrings.errorGeneric),
              ),
            ],
          ),
        ),
      );
    }

    if (state.items.isEmpty) {
      return const Center(
        child: Text(
          AppStrings.noPhotos,
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: ctrl.loadFirstPage,
      color: AppColors.navyDeep,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverGrid(
            delegate: SliverChildBuilderDelegate((context, index) {
              final item = state.items[index];
              return MediaGridItem(
                item: item,
                selectionMode: sel.active,
                selected: sel.isSelected(item.id),
                onLongPress: () => selCtrl.enter(item),
                onTap: () {
                  if (sel.active) {
                    selCtrl.toggle(item);
                  } else {
                    context
                        .push<String>(
                          AppRoutes.detail,
                          extra: {'id': item.id, 'items': state.items},
                        )
                        .then((removedId) {
                          // انحذفت/انتقلت للسكيور أو لمجلد تاني من شاشة العرض
                          if (removedId == null || !mounted) return;
                          ctrl.removeByIds([removedId]);
                          ref.read(folderAlbumsProvider.notifier).load();
                        });
                  }
                },
              );
            }, childCount: state.items.length),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: AppSizes.gridCrossAxisCount,
              mainAxisSpacing: AppSizes.gridSpacing,
              crossAxisSpacing: AppSizes.gridSpacing,
            ),
          ),
          if (state.loadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: CircularProgressIndicator(
                    color: AppColors.navyDeep,
                    strokeWidth: 2,
                  ),
                ),
              ),
            ),
          if (!state.hasMore && state.items.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Text(
                    '${AppStrings.loadAllPhotos} (${state.totalCount})',
                    style: const TextStyle(
                      color: AppColors.textHint,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  final VoidCallback onRetry;
  const _PermissionDeniedView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.errorRed.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.no_photography_outlined,
                color: AppColors.errorRed,
                size: 40,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              AppStrings.errorPermission,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              AppStrings.permDeniedBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  await PhotoManager.openSetting();
                },
                icon: const Icon(Icons.settings_outlined, color: Colors.white),
                label: const Text(
                  AppStrings.openSettings,
                  style: TextStyle(color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.navyDeep,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: onRetry,
              child: const Text(
                AppStrings.checkAgain,
                style: TextStyle(color: AppColors.skyBlue),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── رأس الصفحة العصري ────────────────────────────────────────
class _HomeHeader extends StatelessWidget {
  final String subtitle;
  final VoidCallback onSearch;
  final VoidCallback onSecure;
  const _HomeHeader({
    required this.subtitle,
    required this.onSearch,
    required this.onSecure,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 14, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'PixMind',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          _CircleIconBtn(icon: Icons.search_rounded, onTap: onSearch),
          const SizedBox(width: 10),
          _CircleIconBtn(icon: Icons.lock_outline_rounded, onTap: onSecure),
        ],
      ),
    );
  }
}

// ── رأس وضع التحديد ──────────────────────────────────────────
class _SelectionHeader extends StatelessWidget {
  final int count;
  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  const _SelectionHeader({
    required this.count,
    required this.onClose,
    required this.onSelectAll,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Row(
        children: [
          _CircleIconBtn(icon: Icons.close_rounded, onTap: onClose),
          const SizedBox(width: 14),
          Text(
            '$count selected',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: onSelectAll,
            child: const Text(
              'Select all',
              style: TextStyle(
                color: AppColors.navyDeep,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleIconBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 44,
    height: 44,
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
        child: Center(child: Icon(icon, color: AppColors.navyDeep, size: 22)),
      ),
    ),
  );
}

// ── رقائق الفلترة (Pills) ────────────────────────────────────
class _FilterChips extends StatelessWidget {
  final MediaFilter current;
  final ValueChanged<MediaFilter> onChanged;
  const _FilterChips({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _Chip(
            label: AppStrings.all,
            active: current == MediaFilter.all,
            onTap: () => onChanged(MediaFilter.all),
          ),
          _Chip(
            label: AppStrings.photos,
            active: current == MediaFilter.images,
            onTap: () => onChanged(MediaFilter.images),
          ),
          _Chip(
            label: AppStrings.videos,
            active: current == MediaFilter.videos,
            onTap: () => onChanged(MediaFilter.videos),
          ),
          _Chip(
            label: AppStrings.folders,
            active: current == MediaFilter.folders,
            onTap: () => onChanged(MediaFilter.folders),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: active ? AppColors.navyDeep : Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: active
                  ? AppColors.navyDeep
                  : AppColors.navyDeep.withOpacity(0.10),
            ),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: AppColors.navyDeep.withOpacity(0.25),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : AppColors.textSecondary,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              fontSize: 13.5,
            ),
          ),
        ),
      ),
    );
  }
}

// ── شريط أفعال التحديد المتعدد (عصري: أبيض بحواف دائرية وظل) ──
class _SelectionActionBar extends StatelessWidget {
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final VoidCallback onCollage;
  const _SelectionActionBar({
    required this.onShare,
    required this.onDelete,
    required this.onCollage,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [
          BoxShadow(
            color: AppColors.navyDeep.withOpacity(0.12),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _BarBtn(
                icon: Icons.ios_share_rounded,
                label: 'Share',
                onTap: onShare,
              ),
              _BarBtn(
                icon: Icons.grid_view_rounded,
                label: 'Collage',
                onTap: onCollage,
              ),
              _BarBtn(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                onTap: onDelete,
                color: AppColors.errorRed,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;
  const _BarBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = AppColors.navyDeep,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 4),
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
