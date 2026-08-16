import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import '../../data/repositories/media_repository.dart';
import 'visual_embedding_service.dart';
import 'visual_search_repository.dart';

final class VisualIndexProgress {
  const VisualIndexProgress({
    required this.total,
    required this.visited,
    required this.indexed,
    required this.skipped,
    required this.failed,
    this.assetName,
  });

  final int total;
  final int visited;
  final int indexed;
  final int skipped;
  final int failed;
  final String? assetName;

  double get progress {
    if (total <= 0) {
      return 0.0;
    }
    return (visited / total).clamp(0.0, 1.0).toDouble();
  }
}

final class VisualIndexSummary {
  const VisualIndexSummary({
    required this.total,
    required this.indexed,
    required this.skipped,
    required this.failed,
    required this.cancelled,
  });

  final int total;
  final int indexed;
  final int skipped;
  final int failed;
  final bool cancelled;
}

final class VisualSearchIndexer {
  VisualSearchIndexer({
    required VisualEmbeddingService embeddingService,
    required VisualSearchRepository repository,
    MediaRepository? mediaRepository,
  }) : _embeddingService = embeddingService,
       _repository = repository,
       _mediaRepository = mediaRepository ?? MediaRepository();

  static const int _pageSize = 50;

  final VisualEmbeddingService _embeddingService;
  final VisualSearchRepository _repository;
  final MediaRepository _mediaRepository;

  Future<Float32List> ensureEmbedding(AssetEntity asset) async {
    final stored = await _repository.getEmbedding(asset.id);
    if (stored != null) {
      return stored;
    }

    final thumbnail = await asset.thumbnailDataWithSize(
      const ThumbnailSize(512, 512),
      quality: 95,
    );

    if (thumbnail == null || thumbnail.isEmpty) {
      throw StateError('تعذر إنشاء صورة مصغرة لـ ${asset.title ?? asset.id}.');
    }

    final embedding = await _embeddingService.generateEmbedding(thumbnail);

    await _repository.saveEmbedding(assetId: asset.id, embedding: embedding);

    return embedding;
  }

  Future<VisualIndexSummary> indexAllMissing({
    void Function(VisualIndexProgress progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) {
      throw StateError('لا يوجد إذن للوصول إلى الصور.');
    }

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );

    if (paths.isEmpty) {
      return const VisualIndexSummary(
        total: 0,
        indexed: 0,
        skipped: 0,
        failed: 0,
        cancelled: false,
      );
    }

    final total = await _mediaRepository.getTotalCount(RequestType.image);
    final indexedAssetIds = await _repository.getIndexedAssetIds();
    final allPhotos = paths.first;

    var page = 0;
    var visited = 0;
    var indexed = 0;
    var skipped = 0;
    var failed = 0;
    var cancelled = false;

    while (true) {
      if (shouldCancel?.call() ?? false) {
        cancelled = true;
        break;
      }

      final assets = await allPhotos.getAssetListPaged(
        page: page,
        size: _pageSize,
      );

      if (assets.isEmpty) {
        break;
      }

      for (final asset in assets) {
        if (shouldCancel?.call() ?? false) {
          cancelled = true;
          break;
        }

        visited++;

        if (indexedAssetIds.contains(asset.id)) {
          skipped++;
        } else {
          try {
            await ensureEmbedding(asset);
            indexedAssetIds.add(asset.id);
            indexed++;
          } catch (_) {
            failed++;
          }
        }

        onProgress?.call(
          VisualIndexProgress(
            total: total,
            visited: visited,
            indexed: indexed,
            skipped: skipped,
            failed: failed,
            assetName: asset.title,
          ),
        );

        await Future<void>.delayed(Duration.zero);
      }

      if (cancelled || assets.length < _pageSize) {
        break;
      }

      page++;
    }

    return VisualIndexSummary(
      total: total,
      indexed: indexed,
      skipped: skipped,
      failed: failed,
      cancelled: cancelled,
    );
  }
}
