import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../models/media_item.dart';

class MediaRepository {
  Future<PermissionState> requestPermission() async {
    return await PhotoManager.requestPermissionExtend();
  }

  Future<PermissionState> checkPermission() async {
    return await PhotoManager.requestPermissionExtend();
  }

  Future<AssetPathEntity?> _getAllAlbum(RequestType type) async {
    final albums = await PhotoManager.getAssetPathList(
      type: type,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    return albums.isEmpty ? null : albums.first;
  }

  Future<int> getTotalCount(RequestType type) async {
    final album = await _getAllAlbum(type);
    if (album == null) return 0;
    return await album.assetCountAsync;
  }

  Future<List<MediaItem>> loadPage({
    required RequestType type,
    required int page,
    int pageSize = 120,
  }) async {
    final album = await _getAllAlbum(type);
    if (album == null) return [];

    final assets = await album.getAssetListPaged(page: page, size: pageSize);

    return assets.map(MediaItem.fromAsset).toList();
  }

  /// Raw assets for the merged offline AI indexer. Results are newest-first
  /// because [_getAllAlbum] applies descending createDate ordering.
  Future<List<AssetEntity>> loadRecentAssets({
    RequestType type = RequestType.image,
    int limit = 500,
  }) async {
    final album = await _getAllAlbum(type);
    if (album == null) return const [];
    return album.getAssetListPaged(page: 0, size: limit);
  }

  /// Raw assets in newest-first order starting at an absolute offset.
  /// Useful for small manual AI batches (next 20, next 20, ...).
  Future<List<AssetEntity>> loadAssetRange({
    RequestType type = RequestType.image,
    required int start,
    required int end,
  }) async {
    final album = await _getAllAlbum(type);
    if (album == null || end <= start) return const [];
    return album.getAssetListRange(start: start, end: end);
  }

  Future<List<AssetEntity>> loadRawPage({
    RequestType type = RequestType.image,
    required int page,
    int pageSize = 200,
  }) async {
    final album = await _getAllAlbum(type);
    if (album == null) return const [];
    return album.getAssetListPaged(page: page, size: pageSize);
  }

  Future<List<AlbumInfo>> getFolderAlbums() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );

    final albums = <AlbumInfo>[];
    for (final path in paths) {
      final count = await path.assetCountAsync;
      if (count == 0) continue;

      final cover = await path.getAssetListPaged(page: 0, size: 1);
      albums.add(
        AlbumInfo(
          id: path.id,
          name: path.name,
          count: count,
          coverAsset: cover.isNotEmpty ? cover.first : null,
          path: path,
        ),
      );
    }

    albums.sort((a, b) => b.count.compareTo(a.count));
    return albums;
  }

  Future<List<MediaItem>> loadAlbumPage({
    required AssetPathEntity albumPath,
    required int page,
    int pageSize = 120,
  }) async {
    final assets = await albumPath.getAssetListPaged(
      page: page,
      size: pageSize,
    );
    return assets.map(MediaItem.fromAsset).toList();
  }

  Future<AssetEntity?> getAssetById(String id) async {
    return await AssetEntity.fromId(id);
  }
}

class AlbumInfo {
  final String id;
  final String name;
  final int count;
  final AssetEntity? coverAsset;
  final AssetPathEntity path;

  const AlbumInfo({
    required this.id,
    required this.name,
    required this.count,
    required this.coverAsset,
    required this.path,
  });
}

final mediaRepositoryProvider = Provider<MediaRepository>(
  (_) => MediaRepository(),
);
