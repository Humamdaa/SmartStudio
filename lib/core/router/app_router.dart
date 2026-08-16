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
        builder: (_, __, child) => MainScaffold(child: child),
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
  const MainScaffold({super.key, required this.child});

  @override
  ConsumerState<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends ConsumerState<MainScaffold> {
  int _idx = 0;
  static const _tabs = [
    AppRoutes.home,
    AppRoutes.search,
    AppRoutes.albums,
    AppRoutes.suggestions,
  ];

  @override
  Widget build(BuildContext context) {
    // نخفي شريط التنقّل وقت التحديد المتعدد حتى ما يصير بارين فوق بعض.
    final selecting = ref.watch(selectionProvider).active;
    return Scaffold(
      body: widget.child,
      bottomNavigationBar: selecting
          ? null
          : NavigationBar(
              selectedIndex: _idx,
              height: 64,
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              indicatorColor: AppColors.mintAccent.withOpacity(0.22),
              labelBehavior:
                  NavigationDestinationLabelBehavior.onlyShowSelected,
              onDestinationSelected: (i) {
                setState(() => _idx = i);
                context.go(_tabs[i]);
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
    );
  }
}
