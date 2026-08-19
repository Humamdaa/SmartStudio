import 'package:photo_manager/photo_manager.dart';

import '../data/database/db_helper.dart';
import '../data/models/index_dashboard_stats.dart';
import '../data/models/media_item.dart';
import '../data/models/search_index_entry.dart';
import '../data/repositories/media_repository.dart';
import '../data/repositories/precise_search_repository.dart';
import '../features/search/search_scope.dart' as precise;
import 'gallery/background_indexer.dart';
import 'gallery/precise_indexer.dart';

enum SmartSearchDomain { general, people, ocr, objects, colors, scenes, date }

class SmartSearchResolvedHit {
  final MediaItem item;
  final SearchHit hit;

  const SmartSearchResolvedHit({required this.item, required this.hit});
}

class SmartIndexRunSummary {
  final int processed;
  final int failed;
  final bool cancelled;
  final String? pausedReason;
  final bool yoloReady;
  final String? yoloError;

  const SmartIndexRunSummary({
    required this.processed,
    required this.failed,
    required this.cancelled,
    required this.pausedReason,
    required this.yoloReady,
    required this.yoloError,
  });
}

/// Adapter that lets the teammate UI use the stable v2.1.1 offline search
/// engine without replacing the teammate ObjectBox/color-index architecture.
class SmartSearchBridge {
  SmartSearchBridge({
    PreciseSearchRepository? searchRepository,
    MediaRepository? mediaRepository,
    PreciseIndexer? indexer,
    DatabaseHelper? database,
  }) : _search = searchRepository ?? PreciseSearchRepository(),
       _media = mediaRepository ?? MediaRepository(),
       _indexer = indexer ?? PreciseIndexer(),
       _database = database ?? DatabaseHelper.instance;

  final PreciseSearchRepository _search;
  final MediaRepository _media;
  final PreciseIndexer _indexer;
  final DatabaseHelper _database;

  Future<List<SmartSearchResolvedHit>> search(
    String query, {
    SmartSearchDomain domain = SmartSearchDomain.general,
  }) async {
    final value = query.trim();
    if (value.isEmpty) return const [];

    final hits = await _search.search(value, scope: _scope(domain));
    final resolved = <SmartSearchResolvedHit>[];
    for (final hit in hits) {
      final asset = await AssetEntity.fromId(hit.assetId);
      if (asset == null) continue;
      resolved.add(
        SmartSearchResolvedHit(item: MediaItem.fromAsset(asset), hit: hit),
      );
    }
    return resolved;
  }

  /// Raw ids from the heavy content index. Federated search uses ids first,
  /// intersects them with Face/ObjectBox sources, then resolves only the final
  /// photos. This avoids requiring every feature to share one database row.
  Future<Set<String>> searchIndexedAssetIds(
    String query, {
    SmartSearchDomain domain = SmartSearchDomain.general,
    int limit = 800,
  }) async {
    final value = query.trim();
    if (value.isEmpty) return const <String>{};
    final hits = await _search.search(
      value,
      scope: _scope(domain),
      limit: limit,
    );
    return hits.map((hit) => hit.assetId).toSet();
  }

  /// Raw ids directly from the Face Lab / People index. No AI-content index
  /// row is required, so naming a person makes their photos searchable
  /// immediately after face classification.
  Future<Set<String>> searchPersonAssetIds(
    String normalizedName, {
    int limit = 800,
  }) async {
    final ids = await _database.searchPersonAssetIdsByName(
      normalizedName,
      limit: limit,
    );
    return ids.toSet();
  }

  Future<IndexDashboardStats> stats() async {
    final total = await _media.getTotalCount(RequestType.image);
    return _database.getDashboardStats(totalImages: total);
  }

  Future<void> retryFailed() => _database.retryFailedQueue();

  Future<void> setBackgroundEnabled(bool enabled) =>
      BackgroundIndexService.instance.setEnabled(enabled);

  Future<SmartIndexRunSummary> indexNext({
    int limit = 20,
    void Function(IndexProgress progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    // Unique high priority isolates this manual run from an older interrupted
    // manual batch that may still be pending in the resumable queue.
    final priority = DateTime.now().millisecondsSinceEpoch;
    final queued = await _indexer.enqueueNextUnindexed(
      limit: limit,
      priority: priority,
    );
    if (queued == 0) {
      return const SmartIndexRunSummary(
        processed: 0,
        failed: 0,
        cancelled: false,
        pausedReason: 'No unindexed photos left in the library.',
        yoloReady: true,
        yoloError: null,
      );
    }

    var processed = 0;
    var failed = 0;
    var cancelled = false;
    String? pausedReason;
    var yoloReady = true;
    String? yoloError;

    var remaining = await _database.getPendingQueueCount(minPriority: priority);
    while (remaining > 0 && !(shouldCancel?.call() ?? false)) {
      final batch = await _indexer.processQueueBatch(
        batchSize: remaining > 8 ? 8 : remaining,
        onProgress: onProgress ?? (_) {},
        shouldCancel: shouldCancel ?? () => false,
        waitWhilePaused: () async {},
        respectDeviceHealth: true,
        mode: 'foreground',
        minPriority: priority,
        // A manual small batch should be deterministic for OCR testing.
        forceArabicOcr: true,
      );
      processed += batch.processed;
      failed += batch.failed;
      cancelled = cancelled || batch.cancelled;
      pausedReason ??= batch.pausedReason;
      yoloReady = yoloReady && batch.yoloReady;
      yoloError ??= batch.yoloError;
      if (batch.cancelled || batch.pausedReason != null || batch.queueEmpty)
        break;
      remaining = await _database.getPendingQueueCount(minPriority: priority);
    }

    return SmartIndexRunSummary(
      processed: processed,
      failed: failed,
      cancelled: cancelled || (shouldCancel?.call() ?? false),
      pausedReason: pausedReason,
      yoloReady: yoloReady,
      yoloError: yoloError,
    );
  }

  Future<SmartIndexRunSummary> reindexRecent({
    int limit = 20,
    void Function(IndexProgress progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final priority = DateTime.now().millisecondsSinceEpoch;
    await _indexer.enqueueRecent(limit: limit, priority: priority, force: true);

    var processed = 0;
    var failed = 0;
    var cancelled = false;
    String? pausedReason;
    var yoloReady = true;
    String? yoloError;

    var remaining = await _database.getPendingQueueCount(minPriority: priority);
    while (remaining > 0 && !(shouldCancel?.call() ?? false)) {
      final batch = await _indexer.processQueueBatch(
        batchSize: remaining > 8 ? 8 : remaining,
        onProgress: onProgress ?? (_) {},
        shouldCancel: shouldCancel ?? () => false,
        waitWhilePaused: () async {},
        respectDeviceHealth: true,
        mode: 'foreground',
        minPriority: priority,
        // The user explicitly asked to refresh these 20 photos. If Arabic OCR
        // is enabled, run it deterministically here instead of relying on the
        // lightweight text-heavy heuristic used by full/background indexing.
        forceArabicOcr: true,
      );
      processed += batch.processed;
      failed += batch.failed;
      cancelled = cancelled || batch.cancelled;
      pausedReason ??= batch.pausedReason;
      yoloReady = yoloReady && batch.yoloReady;
      yoloError ??= batch.yoloError;
      if (batch.cancelled || batch.pausedReason != null || batch.queueEmpty) {
        break;
      }
      remaining = await _database.getPendingQueueCount(minPriority: priority);
    }

    return SmartIndexRunSummary(
      processed: processed,
      failed: failed,
      cancelled: cancelled || (shouldCancel?.call() ?? false),
      pausedReason: pausedReason,
      yoloReady: yoloReady,
      yoloError: yoloError,
    );
  }

  Future<SmartIndexRunSummary> indexAll({
    void Function(QueuePreparationProgress progress)? onQueueProgress,
    void Function(IndexProgress progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    await _indexer.prepareFullQueue(onProgress: onQueueProgress);

    var processed = 0;
    var failed = 0;
    var cancelled = false;
    String? pausedReason;
    var yoloReady = true;
    String? yoloError;

    while (!(shouldCancel?.call() ?? false)) {
      final pending = await _database.getPendingQueueCount();
      if (pending <= 0) break;
      final batch = await _indexer.processQueueBatch(
        batchSize: pending > 8 ? 8 : pending,
        onProgress: onProgress ?? (_) {},
        shouldCancel: shouldCancel ?? () => false,
        waitWhilePaused: () async {},
        respectDeviceHealth: true,
        mode: 'foreground',
      );
      processed += batch.processed;
      failed += batch.failed;
      cancelled = cancelled || batch.cancelled;
      pausedReason ??= batch.pausedReason;
      yoloReady = yoloReady && batch.yoloReady;
      yoloError ??= batch.yoloError;
      if (batch.cancelled || batch.pausedReason != null || batch.queueEmpty) {
        break;
      }
    }

    return SmartIndexRunSummary(
      processed: processed,
      failed: failed,
      cancelled: cancelled || (shouldCancel?.call() ?? false),
      pausedReason: pausedReason,
      yoloReady: yoloReady,
      yoloError: yoloError,
    );
  }

  precise.SearchScope _scope(SmartSearchDomain domain) {
    return switch (domain) {
      SmartSearchDomain.people => precise.SearchScope.people,
      SmartSearchDomain.ocr => precise.SearchScope.ocr,
      SmartSearchDomain.objects => precise.SearchScope.objects,
      SmartSearchDomain.colors => precise.SearchScope.colors,
      SmartSearchDomain.scenes => precise.SearchScope.scenes,
      SmartSearchDomain.date => precise.SearchScope.date,
      SmartSearchDomain.general => precise.SearchScope.general,
    };
  }
}
