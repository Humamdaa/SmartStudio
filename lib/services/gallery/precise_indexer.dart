import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../data/database/db_helper.dart';
import '../../data/models/search_index_entry.dart';
import '../../data/prefs/app_prefs.dart';
import '../../data/repositories/media_repository.dart';
import '../../data/repositories/precise_search_repository.dart';
import '../ai/color_service.dart';
import '../ai/face_service.dart';
import '../ai/object_detection_service.dart';
import '../ai/ocr_service.dart';
import '../ai/scene_label_service.dart';
import '../device/device_health_service.dart';

typedef IndexProgressCallback = void Function(IndexProgress progress);
typedef QueueProgressCallback = void Function(QueuePreparationProgress progress);
typedef IndexCancellationCheck = bool Function();
typedef IndexPauseWaiter = Future<void> Function();

class PreciseIndexer {
  PreciseIndexer({
    MediaRepository? mediaRepository,
    PreciseSearchRepository? searchRepository,
    DatabaseHelper? database,
  })  : _mediaRepository = mediaRepository ?? MediaRepository(),
        _searchRepository = searchRepository ?? PreciseSearchRepository(),
        _database = database ?? DatabaseHelper.instance;

  final MediaRepository _mediaRepository;
  final PreciseSearchRepository _searchRepository;
  final DatabaseHelper _database;

  /// Walks the complete Android photo collection page-by-page and persists a
  /// resumable queue. Re-running it is cheap because already indexed IDs and
  /// already queued IDs are ignored by SQLite.
  Future<int> prepareFullQueue({QueueProgressCallback? onProgress}) async {
    final permission = await _mediaRepository.checkPermission();
    if (!permission.hasAccess) {
      throw StateError('صلاحية الصور مطلوبة قبل الفهرسة');
    }
    const pageSize = 200;
    final total = await _mediaRepository.getTotalCount(RequestType.image);
    var discovered = 0;
    for (var page = 0; discovered < total; page++) {
      final assets = await _mediaRepository.loadRawPage(
        type: RequestType.image,
        page: page,
        pageSize: pageSize,
      );
      if (assets.isEmpty) break;
      await _database.enqueueAssets(
        assets.map((asset) => asset.id),
        priority: 0,
      );
      discovered += assets.length;
      onProgress?.call(QueuePreparationProgress(
        discovered: discovered.clamp(0, total).toInt(),
        total: total,
      ));
    }
    return total;
  }

  Future<void> enqueueRecent({
    int limit = 500,
    int priority = 100,
    bool force = false,
  }) async {
    final assets = await _mediaRepository.loadRecentAssets(
      type: RequestType.image,
      limit: limit,
    );
    await _database.enqueueAssets(
      assets.map((asset) => asset.id),
      priority: priority,
      force: force,
    );
  }


  /// Enqueues the next [limit] photos that have not yet been fully processed
  /// by the current presentation pipeline. Scanning is newest -> oldest, so
  /// repeated taps naturally progress 1-20, 21-40, 41-60... without storing a
  /// fragile UI cursor. Photos manually OCR'd but not fully AI-indexed are not
  /// skipped because [getPresentationIndexedAssetIds] only contains complete
  /// current-pipeline rows.
  Future<int> enqueueNextUnindexed({
    int limit = 20,
    int priority = 1000,
  }) async {
    final permission = await _mediaRepository.checkPermission();
    if (!permission.hasAccess) {
      throw StateError('صلاحية الصور مطلوبة قبل الفهرسة');
    }

    final fullyIndexed = await _database.getPresentationIndexedAssetIds();
    final total = await _mediaRepository.getTotalCount(RequestType.image);
    if (total <= 0 || limit <= 0) return 0;

    const pageSize = 120;
    final selected = <String>[];
    for (var start = 0; start < total && selected.length < limit; start += pageSize) {
      final end = (start + pageSize) > total ? total : start + pageSize;
      final assets = await _mediaRepository.loadAssetRange(
        type: RequestType.image,
        start: start,
        end: end,
      );
      if (assets.isEmpty) break;
      for (final asset in assets) {
        if (!fullyIndexed.contains(asset.id)) {
          selected.add(asset.id);
          if (selected.length >= limit) break;
        }
      }
    }

    if (selected.isEmpty) return 0;
    await _database.enqueueAssets(
      selected,
      priority: priority,
      force: false,
    );
    return selected.length;
  }

  Future<IndexBatchResult> processQueueBatch({
    int batchSize = 8,
    required IndexProgressCallback onProgress,
    required IndexCancellationCheck shouldCancel,
    required IndexPauseWaiter waitWhilePaused,
    bool respectDeviceHealth = true,
    String mode = 'foreground',
    int? minPriority,
    bool forceArabicOcr = false,
  }) async {
    final detector = ObjectDetectionService.instance;
    onProgress(const IndexProgress(
      processed: 0,
      total: 0,
      phase: 'جاري تجهيز نماذج الذكاء المحلي…',
    ));
    final yoloReady = await detector.initialize();
    final ids = await _database.claimPendingAssets(
      limit: batchSize,
      minPriority: minPriority,
    );
    if (ids.isEmpty) {
      return IndexBatchResult(
        processed: 0,
        failed: 0,
        cancelled: false,
        queueEmpty: true,
        yoloReady: yoloReady,
        yoloError: detector.lastError,
        pending: 0,
      );
    }

    final runId = await _database.startIndexRun(mode);
    var processed = 0;
    var failed = 0;
    var cancelled = false;
    String? pausedReason;

    for (var position = 0; position < ids.length; position++) {
      await waitWhilePaused();
      if (shouldCancel()) {
        cancelled = true;
        await _database.releaseQueueAssets(ids.skip(position));
        break;
      }
      if (respectDeviceHealth) {
        // Manual/foreground indexing should remain available even when the
        // battery is below 20%. The explicit low-battery gate is reserved for
        // background work. Thermal protection remains active in both modes.
        final gate = await DeviceHealthService.instance.canContinueIndexing(
          checkLowBattery: mode == 'background',
          checkThermal: true,
        );
        if (!gate.allowed) {
          pausedReason = gate.reason;
          await _database.releaseQueueAssets(ids.skip(position));
          break;
        }
      }

      final assetId = ids[position];
      final asset = await AssetEntity.fromId(assetId);
      if (asset == null) {
        await _database.markQueueDone(assetId);
        continue;
      }

      try {
        await _indexAsset(
          asset,
          yoloReady: yoloReady,
          processed: processed,
          total: ids.length,
          onProgress: onProgress,
          shouldCancel: shouldCancel,
          waitWhilePaused: waitWhilePaused,
          forceArabicOcr: forceArabicOcr,
        );
        await _database.markQueueDone(asset.id);
        processed++;
      } on _GracefulIndexInterruption {
        cancelled = true;
        await _database.releaseQueueAssets(ids.skip(position));
        break;
      } catch (error, stackTrace) {
        failed++;
        await _database.markQueueFailed(asset.id, error);
        debugPrint('PixMind index error for ${asset.id}: $error\n$stackTrace');
      }

      onProgress(IndexProgress(
        processed: processed,
        total: ids.length,
        phase: 'تم الحفظ؛ ننتقل للصورة التالية…',
        assetName: asset.title,
      ));
      // A breather so the UI stays responsive. Kept only for background work:
      // in the foreground 90ms per photo added up to over two hours of pure
      // sleeping across a library this size.
      if (mode == 'background') {
        await Future<void>.delayed(const Duration(milliseconds: 90));
      }
    }

    if (processed > 0 && !cancelled) {
      onProgress(IndexProgress(
        processed: processed,
        total: ids.length,
        phase: 'تحسين ألبومات الأشخاص ودمج التكرارات الآمنة…',
      ));
      try {
        await FaceService.instance.refineClusters(maxMerges: 6);
      } catch (error, stackTrace) {
        // Cluster refinement is a safe post-pass. Never fail a successful
        // image index because a refinement attempt could not complete.
        debugPrint('PixMind face refinement error: $error\n$stackTrace');
      }
    }

    final pending = await _database.getPendingQueueCount();
    await _database.finishIndexRun(
      runId,
      processed: processed,
      failed: failed,
      note: pausedReason ?? (cancelled ? 'cancelled' : null),
    );
    return IndexBatchResult(
      processed: processed,
      failed: failed,
      cancelled: cancelled,
      queueEmpty: pending == 0,
      yoloReady: yoloReady,
      yoloError: detector.lastError,
      pending: pending,
      pausedReason: pausedReason,
    );
  }

  Future<void> _indexAsset(
    AssetEntity asset, {
    required bool yoloReady,
    required int processed,
    required int total,
    required IndexProgressCallback onProgress,
    required IndexCancellationCheck shouldCancel,
    required IndexPauseWaiter waitWhilePaused,
    required bool forceArabicOcr,
  }) async {
    onProgress(IndexProgress(
      processed: processed,
      total: total,
      phase: 'كشف العناصر والألوان…',
      assetName: asset.title,
    ));
    final thumbnail = await asset.thumbnailDataWithSize(
      const ThumbnailSize(640, 640),
      quality: 86,
    );
    var objects = const <String>[];
    var colors = const <String>[];
    if (thumbnail != null) {
      if (yoloReady) objects = await ObjectDetectionService.instance.detect(thumbnail);
      colors = ColorService.dominantColors(thumbnail);
    }

    await waitWhilePaused();
    if (shouldCancel()) throw const _GracefulIndexInterruption();

    var scenes = const <String>[];
    var ocr = OcrExtraction.empty;
    var people = const <String>[];
    var faceCount = 0;
    final file = await asset.file;
    if (file != null) {
      onProgress(IndexProgress(
        processed: processed,
        total: total,
        phase: 'فهم المشهد وقراءة النص…',
        assetName: asset.title,
      ));
      scenes = await SceneLabelService.instance.labelImage(file.path);
      final arabicEnabled = await AppPrefs.instance.arabicOcrEnabled;
      ocr = await OcrService.instance.extractCombinedText(
        file.path,
        arabic: !arabicEnabled
            ? ArabicOcrMode.off
            : forceArabicOcr
                ? ArabicOcrMode.force
                : ArabicOcrMode.auto,
      );

      await waitWhilePaused();
      if (shouldCancel()) throw const _GracefulIndexInterruption();
      onProgress(IndexProgress(
        processed: processed,
        total: total,
        phase: 'كشف الوجوه وتجميع الأشخاص…',
        assetName: asset.title,
      ));
      Object? faceStageError;
      try {
        final faceResult = await FaceService.instance.analyzeAndStore(
          assetId: asset.id,
          imagePath: file.path,
        );
        faceCount = faceResult.faceCount;
        people = faceResult.people.map((person) => person.name).toList();
      } catch (error, stackTrace) {
        // Face recognition is an enrichment stage. Never discard successful
        // YOLO/scene/OCR results just because MobileFaceNet or ML Kit failed.
        faceStageError = error;
        faceCount = await _database.getFaceScanCount(asset.id);
        debugPrint('PixMind face stage error for ${asset.id}: $error\n$stackTrace');
      }

      final metadata = _metadataFor(
        asset,
        hasText: ocr.text.trim().isNotEmpty,
        scenes: scenes,
      );
      await _searchRepository.save(SearchIndexEntry(
        assetId: asset.id,
        title: asset.title ?? '',
        takenAt: asset.createDateTime,
        width: asset.width,
        height: asset.height,
        objects: objects,
        scenes: scenes,
        colors: colors,
        ocrText: ocr.text,
        ocrScripts: ocr.scripts,
        metadata: metadata,
        people: people,
        faceCount: faceCount,
        indexedAt: DateTime.now(),
      ));
      if (faceStageError != null) {
        // Faces are an enrichment stage. Keep the successful object/scene/OCR
        // index and mark the queue item done instead of re-running every heavy
        // stage just because face recognition failed on this photo.
        debugPrint(
          'PixMind saved partial AI index without face recognition for '
          '${asset.id}: $faceStageError',
        );
      }
      return;
    }

    final metadata = _metadataFor(
      asset,
      hasText: ocr.text.trim().isNotEmpty,
      scenes: scenes,
    );
    await _searchRepository.save(SearchIndexEntry(
      assetId: asset.id,
      title: asset.title ?? '',
      takenAt: asset.createDateTime,
      width: asset.width,
      height: asset.height,
      objects: objects,
      scenes: scenes,
      colors: colors,
      ocrText: ocr.text,
      ocrScripts: ocr.scripts,
      metadata: metadata,
      people: people,
      faceCount: faceCount,
      indexedAt: DateTime.now(),
    ));
  }

  String _metadataFor(
    AssetEntity asset, {
    required bool hasText,
    required List<String> scenes,
  }) {
    const months = [
      'january', 'february', 'march', 'april', 'may', 'june',
      'july', 'august', 'september', 'october', 'november', 'december',
    ];
    final date = asset.createDateTime;
    final orientation = asset.width >= asset.height
        ? 'landscape horizontal افقي'
        : 'portrait vertical عمودي';
    final screenshot = (asset.title ?? '').toLowerCase().contains('screenshot')
        ? 'screenshot screen لقطة شاشة سكرينشوت'
        : '';
    final textHint = hasText ? 'text document كتابة نص مستند وثيقة' : '';
    final sceneText = scenes.join(' ').toLowerCase();
    final documentHint = sceneText.contains('receipt') ||
            sceneText.contains('document') ||
            sceneText.contains('paper')
        ? 'document receipt invoice فاتورة ايصال مستند'
        : '';
    final month = months[date.month - 1];
    final day = date.day.toString().padLeft(2, '0');
    final numericMonth = date.month.toString().padLeft(2, '0');
    return [
      'photo image صورة صور',
      date.year,
      month,
      '${date.year}-$numericMonth-$day',
      orientation,
      screenshot,
      textHint,
      documentHint,
      '${asset.width}x${asset.height}',
    ].join(' ');
  }
}

class QueuePreparationProgress {
  final int discovered;
  final int total;

  const QueuePreparationProgress({required this.discovered, required this.total});

  double get progress => total == 0
      ? 0
      : (discovered / total).clamp(0.0, 1.0).toDouble();
}

class IndexProgress {
  final int processed;
  final int total;
  final String phase;
  final String? assetName;

  const IndexProgress({
    required this.processed,
    required this.total,
    required this.phase,
    this.assetName,
  });
}

class IndexBatchResult {
  final int processed;
  final int failed;
  final bool cancelled;
  final bool queueEmpty;
  final bool yoloReady;
  final String? yoloError;
  final int pending;
  final String? pausedReason;

  const IndexBatchResult({
    required this.processed,
    required this.failed,
    required this.cancelled,
    required this.queueEmpty,
    required this.yoloReady,
    required this.yoloError,
    required this.pending,
    this.pausedReason,
  });
}

class _GracefulIndexInterruption implements Exception {
  const _GracefulIndexInterruption();

  @override
  String toString() => 'تم إيقاف المعالجة بعد حفظ آخر خطوة مكتملة';
}
