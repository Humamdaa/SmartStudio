import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants/app_colors.dart';
import '../../features/selection/selection_controller.dart';
import '../../features/secure/secure_screen.dart';
import '../../features/splash/splash_screen.dart';
import '../../features/permissions/permissions_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/detail/detail_screen.dart';
import '../../features/placeholder_screens.dart';
import '../../features/editor/editor_screen.dart';
import '../../features/favorites/favorites_album_screen.dart';
import '../../features/collage/collage_screen.dart';
import '../../features/search/search_screen.dart';
import '../../features/ocr/ocr_screen.dart' as smart_ocr;
import '../../features/albums/smart_albums_screen.dart';
import '../../features/albums/duplicates_screen.dart';
import '../../features/albums/people_screen.dart';
import '../../features/suggestions/suggestions_screen.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../data/models/media_item.dart';
import '../../data/repositories/media_repository.dart';
import '../../features/visual_search/similar_images_screen.dart';
import '../../features/albums/indexing_providers.dart';
import '../../services/gallery/complete_smart_index_service.dart';

class AppRoutes {
  static const splash = '/';
  static const permissions = '/permissions';
  static const home = '/home';
  static const search = '/search';
  static const albums = '/albums';
  static const albumDetail = '/album-detail';
  static const detail = '/detail';
  static const editing = '/editing';
  static const ocr = '/ocr';
  static const secure = '/secure';
  static const suggestions = '/suggestions';
  static const video = '/video';
  static const favorites = '/favorites';
  static const collage = '/collage';
  static const duplicates = '/duplicates';
  static const people = '/people';
  static const personDetail = '/person-detail';
  static const visualSearch = '/visual-search';
}

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.splash,
    routes: [
      // for search in images by image
      GoRoute(
        path: AppRoutes.visualSearch,
        builder: (_, state) {
          return SimilarImagesScreen(queryAssetId: state.extra as String);
        },
      ),

      GoRoute(path: AppRoutes.splash, builder: (_, __) => const SplashScreen()),
      GoRoute(
        path: AppRoutes.permissions,
        builder: (_, state) =>
            PermissionsScreen(reason: state.extra as String?),
      ),
      ShellRoute(
        builder: (_, state, child) =>
            MainScaffold(child: child, location: state.uri.path),
        routes: [
          GoRoute(path: AppRoutes.home, builder: (_, __) => const HomeScreen()),
          GoRoute(
            path: AppRoutes.search,
            builder: (_, __) => const SearchScreen(),
          ),
          GoRoute(
            path: AppRoutes.albums,
            builder: (_, __) => const SmartAlbumsScreen(),
          ),
          GoRoute(
            path: AppRoutes.suggestions,
            builder: (_, __) => const SuggestionsScreen(),
          ),
        ],
      ),

      GoRoute(
        path: AppRoutes.detail,
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>;
          final id = extra['id'] as String;
          final items = extra['items'] as List<MediaItem>;
          return DetailScreen(assetId: id, allItems: items);
        },
      ),

      GoRoute(
        path: AppRoutes.albumDetail,
        builder: (_, state) =>
            AlbumDetailScreen(album: state.extra as AlbumInfo),
      ),
      GoRoute(
        path: AppRoutes.editing,
        builder: (_, state) =>
            EditingScreen(assetId: state.extra as String? ?? ''),
      ),
      GoRoute(
        path: AppRoutes.ocr,
        builder: (_, state) =>
            smart_ocr.OcrScreen(assetId: state.extra as String? ?? ''),
      ),
      GoRoute(path: AppRoutes.secure, builder: (_, __) => const SecureScreen()),
      GoRoute(
        path: AppRoutes.favorites,
        builder: (_, __) => const FavoritesAlbumScreen(),
      ),
      GoRoute(
        path: AppRoutes.collage,
        builder: (_, state) =>
            CollageScreen(assets: state.extra as List<AssetEntity>),
      ),
      GoRoute(
        path: AppRoutes.duplicates,
        builder: (_, __) => const DuplicatesScreen(),
      ),
      GoRoute(path: AppRoutes.people, builder: (_, __) => const PeopleScreen()),
      GoRoute(
        path: AppRoutes.personDetail,
        builder: (_, state) =>
            PersonDetailScreen(personId: state.extra as String),
      ),
      GoRoute(
        path: AppRoutes.video,
        builder: (_, state) =>
            VideoScreen(assetId: state.extra as String? ?? ''),
      ),
    ],
  );
});

class MainScaffold extends ConsumerStatefulWidget {
  final Widget child;
  final String location;
  const MainScaffold({
    super.key,
    required this.child,
    required this.location,
  });

  @override
  ConsumerState<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends ConsumerState<MainScaffold> {
  static const _tabs = [
    AppRoutes.home,
    AppRoutes.search,
    AppRoutes.albums,
    AppRoutes.suggestions,
  ];

  String _smartIndexStageLabel(CompleteSmartIndexStage stage) {
    return switch (stage) {
      CompleteSmartIndexStage.gallery => 'Gallery analysis',
      CompleteSmartIndexStage.content => 'Content understanding',
      CompleteSmartIndexStage.ocr => 'Text recognition',
      CompleteSmartIndexStage.people => 'People',
      CompleteSmartIndexStage.visual => 'Visual search',
      CompleteSmartIndexStage.complete => 'Complete',
      CompleteSmartIndexStage.stopped => 'Stopped',
      CompleteSmartIndexStage.error => 'Needs attention',
      _ => 'Preparing',
    };
  }

  @override
  Widget build(BuildContext context) {
    // نخفي شريط التنقّل وقت التحديد المتعدد حتى ما يصير بارين فوق بعض.
    final selecting = ref.watch(selectionProvider).active;
    final routeIndex = _tabs.indexOf(widget.location);
    final selectedIndex = routeIndex < 0 ? 0 : routeIndex;
    final smartIndex = ref.watch(completeSmartIndexServiceProvider);

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: selecting
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<CompleteSmartIndexState>(
                  valueListenable: smartIndex.progress,
                  builder: (context, state, _) {
                    if (!state.running) return const SizedBox.shrink();
                    final percent =
                        (state.overallFraction.clamp(0.0, 1.0) * 100).round();
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 7),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        border: Border(
                          top: BorderSide(color: Color(0xFFE7E9EE)),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.auto_awesome_rounded,
                                size: 16,
                                color: AppColors.mintAccent,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  'Smart Index • ${_smartIndexStageLabel(state.stage)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                '$percent%',
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          LinearProgressIndicator(
                            value: state.overallFraction.clamp(0.0, 1.0),
                            minHeight: 3,
                            color: AppColors.navyDeep,
                            backgroundColor: const Color(0xFFEFF1F4),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Indexing continues while you browse other tabs.',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 9.8,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                NavigationBar(
                  selectedIndex: selectedIndex,
                  height: 64,
                  backgroundColor: Colors.white,
                  surfaceTintColor: Colors.white,
                  indicatorColor: AppColors.mintAccent.withOpacity(0.22),
                  labelBehavior:
                      NavigationDestinationLabelBehavior.onlyShowSelected,
                  onDestinationSelected: (i) {
                    if (i != selectedIndex) context.go(_tabs[i]);
                  },
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(
                        Icons.home_outlined,
                        color: AppColors.textSecondary,
                      ),
                      selectedIcon: Icon(Icons.home, color: AppColors.navyDeep),
                      label: 'Home',
                    ),
                    NavigationDestination(
                      icon: Icon(
                        Icons.search_outlined,
                        color: AppColors.textSecondary,
                      ),
                      selectedIcon: Icon(Icons.search, color: AppColors.navyDeep),
                      label: 'Search',
                    ),
                    NavigationDestination(
                      icon: Icon(
                        Icons.photo_album_outlined,
                        color: AppColors.textSecondary,
                      ),
                      selectedIcon: Icon(
                        Icons.photo_album,
                        color: AppColors.navyDeep,
                      ),
                      label: 'Albums',
                    ),
                    NavigationDestination(
                      icon: Icon(
                        Icons.auto_awesome_outlined,
                        color: AppColors.textSecondary,
                      ),
                      selectedIcon: Icon(
                        Icons.auto_awesome,
                        color: AppColors.navyDeep,
                      ),
                      label: 'For You',
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
