import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../data/database/db_helper.dart';
import '../../data/models/search_index_entry.dart';
import '../../data/prefs/app_prefs.dart';
import '../../data/repositories/media_repository.dart';
import '../../data/repositories/precise_search_repository.dart';
import '../ai/color_service.dart';
import '../ai/object_detection_service.dart';
import '../ai/ocr_service.dart';
import '../ai/scene_label_service.dart';
import '../device/device_health_service.dart';
import '../ai/heavy_ai_coordinator.dart';

List<String> _dominantColorsInIsolate(Uint8List bytes) =>
    ColorService.dominantColors(bytes);

typedef IndexProgressCallback = void Function(IndexProgress progress);
typedef QueueProgressCallback =
    void Function(QueuePreparationProgress progress);
typedef IndexCancellationCheck = bool Function();
typedef IndexPauseWaiter = Future<void> Function();

class PreciseIndexer {
  PreciseIndexer({
    MediaRepository? mediaRepository,
    PreciseSearchRepository? searchRepository,
    DatabaseHelper? database,
  }) : _mediaRepository = mediaRepository ?? MediaRepository(),
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
      onProgress?.call(
        QueuePreparationProgress(
          discovered: discovered.clamp(0, total).toInt(),
          total: total,
        ),
      );
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
    for (
      var start = 0;
      start < total && selected.length < limit;
      start += pageSize
    ) {
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
    await _database.enqueueAssets(selected, priority: priority, force: false);
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
    onProgress(
      const IndexProgress(
        processed: 0,
        total: 0,
        phase: 'جاري تجهيز نماذج الذكاء المحلي…',
      ),
    );
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

      final lease = await HeavyAiCoordinator.instance.acquire(
        task: 'content-$mode',
        // Foreground work may wait briefly for a background face/content slice
        // to finish. Background workers never wait; they yield and reschedule.
        wait: mode != 'background',
      );
      if (lease == null) {
        pausedReason = 'محرك ذكاء آخر يعمل الآن؛ سيتم المتابعة تلقائيًا.';
        await _database.releaseQueueAssets(ids.skip(position));
        break;
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
      } finally {
        await lease.release();
      }

      onProgress(
        IndexProgress(
          processed: processed,
          total: ids.length,
          phase: 'تم الحفظ؛ ننتقل للصورة التالية…',
          assetName: asset.title,
        ),
      );
      // Yield between photos so Flutter can render input/scroll frames. The
      // foreground pause is intentionally tiny: 12ms adds only ~12 seconds per
      // 1000 photos, while avoiding a long uninterrupted chain of heavy work.
      await Future<void>.delayed(
        mode == 'background'
            ? const Duration(milliseconds: 90)
            : const Duration(milliseconds: 12),
      );
    }

    // Face recognition is temporarily decoupled from the heavy AI index.
    // People -> Face Lab can rebuild faces independently without rerunning
    // YOLO/scene/OCR, which makes calibration much faster and safer.

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
    onProgress(
      IndexProgress(
        processed: processed,
        total: total,
        phase: 'كشف العناصر والألوان…',
        assetName: asset.title,
      ),
    );
    final thumbnail = await asset.thumbnailDataWithSize(
      const ThumbnailSize(640, 640),
      quality: 86,
    );
    var objects = const <String>[];
    var colors = const <String>[];
    if (thumbnail != null) {
      if (yoloReady)
        objects = await ObjectDetectionService.instance.detect(thumbnail);
      colors = await compute(_dominantColorsInIsolate, thumbnail);
    }

    await waitWhilePaused();
    if (shouldCancel()) throw const _GracefulIndexInterruption();

    var scenes = const <String>[];
    var ocr = OcrExtraction.empty;
    var people = const <String>[];
    var faceCount = 0;
    final file = await asset.file;
    if (file != null) {
      onProgress(
        IndexProgress(
          processed: processed,
          total: total,
          phase: 'فهم المشهد وقراءة النص…',
          assetName: asset.title,
        ),
      );
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

      // Face v3 is intentionally isolated while we calibrate recognition.
      // Reuse any existing face summary, but do not run ML Kit/MobileFaceNet
      // from Index next 20 / Index all. People -> Face Lab owns that stage.
      faceCount = await _database.getFaceScanCount(asset.id);
      people = (await _database.getPeopleForAsset(asset.id))
          .map((person) => person.name)
          .toList(growable: false);

      final metadata = _metadataFor(
        asset,
        hasText: ocr.text.trim().isNotEmpty,
        scenes: scenes,
      );
      await _searchRepository.save(
        SearchIndexEntry(
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
        ),
      );
      return;
    }

    final metadata = _metadataFor(
      asset,
      hasText: ocr.text.trim().isNotEmpty,
      scenes: scenes,
    );
    await _searchRepository.save(
      SearchIndexEntry(
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
      ),
    );
  }

  String _metadataFor(
    AssetEntity asset, {
    required bool hasText,
    required List<String> scenes,
  }) {
    const months = [
      'january',
      'february',
      'march',
      'april',
      'may',
      'june',
      'july',
      'august',
      'september',
      'october',
      'november',
      'december',
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
    final documentHint =
        sceneText.contains('receipt') ||
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

  const QueuePreparationProgress({
    required this.discovered,
    required this.total,
  });

  double get progress =>
      total == 0 ? 0 : (discovered / total).clamp(0.0, 1.0).toDouble();
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
