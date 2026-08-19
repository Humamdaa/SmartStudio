import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../data/database/db_helper.dart';
import '../../data/prefs/app_prefs.dart';
import '../../data/repositories/media_repository.dart';
import '../../features/visual_search/visual_search_indexer.dart';
import '../../features/visual_search/visual_search_repository.dart';
import '../ai/face_service.dart';
import '../indexing_service.dart';
import '../smart_search_bridge.dart';
import 'face_index_service.dart';
import 'ocr_index_service.dart';
import 'video_index_service.dart';

enum CompleteSmartIndexStage {
  idle,
  gallery,
  content,
  ocr,
  people,
  visual,
  complete,
  stopped,
  error,
}

@immutable
class CompleteSmartIndexSnapshot {
  const CompleteSmartIndexSnapshot({
    required this.total,
    required this.galleryAnalyzed,
    required this.contentIndexed,
    required this.ocrIndexed,
    required this.peopleIndexed,
    required this.visualIndexed,
    required this.arabicOcrEnabled,
    required this.videoIndexingEnabled,
    required this.videoTotal,
    required this.videoContentIndexed,
    required this.videoPeopleIndexed,
  });

  const CompleteSmartIndexSnapshot.empty()
      : total = 0,
        galleryAnalyzed = 0,
        contentIndexed = 0,
        ocrIndexed = 0,
        peopleIndexed = 0,
        visualIndexed = 0,
        arabicOcrEnabled = true,
        videoIndexingEnabled = true,
        videoTotal = 0,
        videoContentIndexed = 0,
        videoPeopleIndexed = 0;

  final int total;
  final int galleryAnalyzed;
  final int contentIndexed;
  final int ocrIndexed;
  final int peopleIndexed;
  final int visualIndexed;
  final bool arabicOcrEnabled;
  final bool videoIndexingEnabled;
  final int videoTotal;
  final int videoContentIndexed;
  final int videoPeopleIndexed;

  int _safe(int value) => total <= 0 ? 0 : value.clamp(0, total).toInt();

  int get safeGalleryAnalyzed => _safe(galleryAnalyzed);
  int get safeContentIndexed => _safe(contentIndexed);
  int get safeOcrIndexed => _safe(ocrIndexed);
  int get safePeopleIndexed => _safe(peopleIndexed);
  int get safeVisualIndexed => _safe(visualIndexed);

  bool get galleryComplete => total > 0 && safeGalleryAnalyzed >= total;
  int get safeVideoContentIndexed =>
      videoTotal <= 0 ? 0 : videoContentIndexed.clamp(0, videoTotal).toInt();
  int get safeVideoPeopleIndexed =>
      videoTotal <= 0 ? 0 : videoPeopleIndexed.clamp(0, videoTotal).toInt();
  bool get videoContentComplete =>
      !videoIndexingEnabled || videoTotal <= 0 || safeVideoContentIndexed >= videoTotal;
  bool get videoPeopleComplete =>
      !videoIndexingEnabled || videoTotal <= 0 || safeVideoPeopleIndexed >= videoTotal;

  bool get contentComplete =>
      total > 0 && safeContentIndexed >= total && videoContentComplete;
  bool get ocrComplete => total > 0 && safeOcrIndexed >= total;
  bool get peopleComplete =>
      total > 0 && safePeopleIndexed >= total && videoPeopleComplete;
  bool get visualComplete => total > 0 && safeVisualIndexed >= total;

  bool get isComplete =>
      total > 0 &&
      galleryComplete &&
      contentComplete &&
      ocrComplete &&
      peopleComplete &&
      visualComplete;

  double get overallFraction {
    if (total <= 0) return 0;
    final videoUnits = videoIndexingEnabled ? videoTotal : 0;
    final contentDenominator = total + videoUnits;
    final peopleDenominator = total + videoUnits;
    final galleryFraction = safeGalleryAnalyzed / total;
    final contentFraction = contentDenominator <= 0
        ? 1.0
        : (safeContentIndexed + safeVideoContentIndexed) / contentDenominator;
    final ocrFraction = safeOcrIndexed / total;
    final peopleFraction = peopleDenominator <= 0
        ? 1.0
        : (safePeopleIndexed + safeVideoPeopleIndexed) / peopleDenominator;
    final visualFraction = safeVisualIndexed / total;
    return ((galleryFraction + contentFraction + ocrFraction + peopleFraction + visualFraction) / 5)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  CompleteSmartIndexSnapshot copyWith({
    int? total,
    int? galleryAnalyzed,
    int? contentIndexed,
    int? ocrIndexed,
    int? peopleIndexed,
    int? visualIndexed,
    bool? arabicOcrEnabled,
    bool? videoIndexingEnabled,
    int? videoTotal,
    int? videoContentIndexed,
    int? videoPeopleIndexed,
  }) {
    return CompleteSmartIndexSnapshot(
      total: total ?? this.total,
      galleryAnalyzed: galleryAnalyzed ?? this.galleryAnalyzed,
      contentIndexed: contentIndexed ?? this.contentIndexed,
      ocrIndexed: ocrIndexed ?? this.ocrIndexed,
      peopleIndexed: peopleIndexed ?? this.peopleIndexed,
      visualIndexed: visualIndexed ?? this.visualIndexed,
      arabicOcrEnabled: arabicOcrEnabled ?? this.arabicOcrEnabled,
      videoIndexingEnabled: videoIndexingEnabled ?? this.videoIndexingEnabled,
      videoTotal: videoTotal ?? this.videoTotal,
      videoContentIndexed: videoContentIndexed ?? this.videoContentIndexed,
      videoPeopleIndexed: videoPeopleIndexed ?? this.videoPeopleIndexed,
    );
  }
}

@immutable
class CompleteSmartIndexState {
  const CompleteSmartIndexState({
    required this.running,
    required this.stage,
    required this.snapshot,
    required this.status,
    this.stageFraction,
  });

  const CompleteSmartIndexState.idle()
      : running = false,
        stage = CompleteSmartIndexStage.idle,
        snapshot = const CompleteSmartIndexSnapshot.empty(),
        status = 'Smart Index is ready.',
        stageFraction = null;

  final bool running;
  final CompleteSmartIndexStage stage;
  final CompleteSmartIndexSnapshot snapshot;
  final String status;
  final double? stageFraction;

  CompleteSmartIndexState copyWith({
    bool? running,
    CompleteSmartIndexStage? stage,
    CompleteSmartIndexSnapshot? snapshot,
    String? status,
    double? stageFraction,
    bool clearStageFraction = false,
  }) {
    return CompleteSmartIndexState(
      running: running ?? this.running,
      stage: stage ?? this.stage,
      snapshot: snapshot ?? this.snapshot,
      status: status ?? this.status,
      stageFraction:
          clearStageFraction ? null : (stageFraction ?? this.stageFraction),
    );
  }

  double get overallFraction {
    final base = snapshot.overallFraction;
    if (!running || snapshot.total <= 0 || stageFraction == null) return base;

    final videoUnits = snapshot.videoIndexingEnabled ? snapshot.videoTotal : 0;
    final contentDenominator = snapshot.total + videoUnits;
    final gallery = snapshot.safeGalleryAnalyzed / snapshot.total;
    final content = contentDenominator <= 0
        ? 1.0
        : (snapshot.safeContentIndexed + snapshot.safeVideoContentIndexed) /
            contentDenominator;
    final ocr = snapshot.safeOcrIndexed / snapshot.total;
    final people = contentDenominator <= 0
        ? 1.0
        : (snapshot.safePeopleIndexed + snapshot.safeVideoPeopleIndexed) /
            contentDenominator;
    final visual = snapshot.safeVisualIndexed / snapshot.total;

    final persisted = switch (stage) {
      CompleteSmartIndexStage.gallery => gallery,
      CompleteSmartIndexStage.content => content,
      CompleteSmartIndexStage.ocr => ocr,
      CompleteSmartIndexStage.people => people,
      CompleteSmartIndexStage.visual => visual,
      _ => -1.0,
    };
    if (persisted < 0) return base;
    final live = stageFraction!.clamp(persisted, 1.0).toDouble();
    final totalFraction = switch (stage) {
      CompleteSmartIndexStage.gallery => live + content + ocr + people + visual,
      CompleteSmartIndexStage.content => gallery + live + ocr + people + visual,
      CompleteSmartIndexStage.ocr => gallery + content + live + people + visual,
      CompleteSmartIndexStage.people => gallery + content + ocr + live + visual,
      CompleteSmartIndexStage.visual => gallery + content + ocr + people + live,
      _ => base * 5,
    };
    return (totalFraction / 5).clamp(base, 1.0).toDouble();
  }
}

/// One user-facing orchestrator over PixMind's specialized indexes.
///
/// It intentionally does NOT merge the stores or rerun finished work. Each
/// stage delegates to the existing resumable index that owns that data:
///
/// 1) lightweight ObjectBox gallery analysis
/// 2) fast Content index (YOLO/scene/named colors/metadata)
/// 3) independent Text Recognition (English + optional Arabic OCR)
/// 4) Face v3 / People
/// 5) visual embeddings
///
/// Re-running this service therefore means "continue what is missing", not
/// "start the library from zero".
class CompleteSmartIndexService {
  CompleteSmartIndexService({
    required IndexingService galleryIndexer,
    required SmartSearchBridge contentBridge,
    required VisualSearchIndexer visualIndexer,
    required VisualSearchRepository visualRepository,
    MediaRepository? mediaRepository,
    DatabaseHelper? database,
    FaceIndexService? faceIndexer,
    OcrIndexService? ocrIndexer,
    VideoIndexService? videoIndexer,
  })  : _galleryIndexer = galleryIndexer,
        _contentBridge = contentBridge,
        _visualIndexer = visualIndexer,
        _visualRepository = visualRepository,
        _mediaRepository = mediaRepository ?? MediaRepository(),
        _database = database ?? DatabaseHelper.instance,
        _faceIndexer = faceIndexer ?? FaceIndexService.instance,
        _ocrIndexer = ocrIndexer ?? OcrIndexService.instance,
        _videoIndexer = videoIndexer ?? VideoIndexService();

  final IndexingService _galleryIndexer;
  final SmartSearchBridge _contentBridge;
  final VisualSearchIndexer _visualIndexer;
  final VisualSearchRepository _visualRepository;
  final MediaRepository _mediaRepository;
  final DatabaseHelper _database;
  final FaceIndexService _faceIndexer;
  final OcrIndexService _ocrIndexer;
  final VideoIndexService _videoIndexer;

  final ValueNotifier<CompleteSmartIndexState> progress =
      ValueNotifier<CompleteSmartIndexState>(
    const CompleteSmartIndexState.idle(),
  );

  bool _cancelRequested = false;

  bool get isRunning => progress.value.running;

  Future<CompleteSmartIndexSnapshot> refresh() async {
    final total = await _mediaRepository.getTotalCount(RequestType.image);
    final content = await _database.getPresentationIndexedCount();
    final arabic = await AppPrefs.instance.arabicOcrEnabled;
    final videoEnabled = await AppPrefs.instance.videoIndexingEnabled;
    final ocr = await _database.getOcrIndexedCount(arabicRequired: arabic);
    final people = await _database.getCompletedFaceScanCount(
      FaceService.facePipelineVersion,
    );
    final visual = await _visualRepository.countIndexedImages();
    final videoTotal = await _mediaRepository.getTotalCount(RequestType.video);
    final videoContent = await _database.getCompletedVideoObjectCount();
    final videoPeople = await _database.getCompletedVideoPeopleCount();

    final snapshot = CompleteSmartIndexSnapshot(
      total: total,
      galleryAnalyzed: _galleryIndexer.analyzedCount,
      contentIndexed: content,
      ocrIndexed: ocr,
      peopleIndexed: people,
      visualIndexed: visual,
      arabicOcrEnabled: arabic,
      videoIndexingEnabled: videoEnabled,
      videoTotal: videoTotal,
      videoContentIndexed: videoContent,
      videoPeopleIndexed: videoPeople,
    );

    final current = progress.value;
    progress.value = current.copyWith(
      snapshot: snapshot,
      status: current.running
          ? current.status
          : snapshot.isComplete
              ? 'All Smart Index stages are complete.'
              : 'Ready to continue only the missing Smart Index stages.',
    );
    return snapshot;
  }

  Future<bool> start() async {
    if (isRunning) return false;
    _cancelRequested = false;
    final snapshot = await refresh();
    if (snapshot.total <= 0) {
      progress.value = progress.value.copyWith(
        running: false,
        stage: CompleteSmartIndexStage.idle,
        status: 'No photos are available to index.',
        clearStageFraction: true,
      );
      return false;
    }
    if (snapshot.isComplete) {
      progress.value = progress.value.copyWith(
        running: false,
        stage: CompleteSmartIndexStage.complete,
        status: 'All Smart Index stages are already complete.',
        clearStageFraction: true,
      );
      return false;
    }

    progress.value = CompleteSmartIndexState(
      running: true,
      stage: CompleteSmartIndexStage.gallery,
      snapshot: snapshot,
      status: 'Checking the lightweight gallery analysis…',
      stageFraction: 0,
    );
    unawaited(_run());
    return true;
  }

  void stop() {
    if (!isRunning) return;
    _cancelRequested = true;
    _galleryIndexer.cancel();
    _ocrIndexer.stop();
    _faceIndexer.stop();
    _videoIndexer.stop();
    progress.value = progress.value.copyWith(
      status: 'Stopping safely after the current image…',
    );
  }

  Future<void> _run() async {
    try {
      await _runGalleryStage();
      if (_cancelRequested) {
        await _finishStopped();
        return;
      }

      await _runContentStage();
      if (_cancelRequested) {
        await _finishStopped();
        return;
      }

      await _runOcrStage();
      if (_cancelRequested) {
        await _finishStopped();
        return;
      }

      await _runPeopleStage();
      if (_cancelRequested) {
        await _finishStopped();
        return;
      }

      await _runVisualStage();
      if (_cancelRequested) {
        await _finishStopped();
        return;
      }

      final snapshot = await refresh();
      progress.value = CompleteSmartIndexState(
        running: false,
        stage: snapshot.isComplete
            ? CompleteSmartIndexStage.complete
            : CompleteSmartIndexStage.idle,
        snapshot: snapshot,
        status: snapshot.isComplete
            ? 'Complete Smart Index finished. Current enabled media stages are ready.'
            : 'Smart Index pass finished. Some media remains and can be retried safely.',
        stageFraction: null,
      );
    } catch (error, stackTrace) {
      debugPrint('PixMind Complete Smart Index failed: $error\n$stackTrace');
      final snapshot = await _safeRefreshSnapshot();
      progress.value = CompleteSmartIndexState(
        running: false,
        stage: CompleteSmartIndexStage.error,
        snapshot: snapshot,
        status: 'Smart Index stopped because of an error: $error',
        stageFraction: null,
      );
    }
  }

  Future<void> _runGalleryStage() async {
    var snapshot = await refresh();
    if (snapshot.galleryComplete || _cancelRequested) return;

    progress.value = progress.value.copyWith(
      running: true,
      stage: CompleteSmartIndexStage.gallery,
      snapshot: snapshot,
      status:
          'Gallery analysis: checking only photos missing pHash, color and quality…',
      stageFraction: snapshot.total <= 0
          ? 0
          : snapshot.safeGalleryAnalyzed / snapshot.total,
    );

    void listener() {
      final p = _galleryIndexer.progress.value;
      if (!progress.value.running ||
          progress.value.stage != CompleteSmartIndexStage.gallery) {
        return;
      }
      progress.value = progress.value.copyWith(
        stageFraction: p.total <= 0 ? null : p.fraction,
        status: p.running
            ? 'Gallery analysis: ${p.done}/${p.total} checked; existing results are skipped.'
            : progress.value.status,
      );
    }

    _galleryIndexer.progress.addListener(listener);
    try {
      if (_galleryIndexer.progress.value.running) {
        await _waitForGalleryIdle();
      } else {
        await _galleryIndexer.indexLibrary(background: true);
      }
    } finally {
      _galleryIndexer.progress.removeListener(listener);
    }
    snapshot = await refresh();
    progress.value = progress.value.copyWith(
      snapshot: snapshot,
      stageFraction: 1,
      status: 'Gallery analysis ready: ${snapshot.safeGalleryAnalyzed}/${snapshot.total}.',
    );
  }

  Future<void> _runContentStage() async {
    var snapshot = await refresh();
    if (snapshot.contentComplete || _cancelRequested) return;

    final initialContentUnits =
        snapshot.total + (snapshot.videoIndexingEnabled ? snapshot.videoTotal : 0);

    progress.value = progress.value.copyWith(
      running: true,
      stage: CompleteSmartIndexStage.content,
      snapshot: snapshot,
      status: 'Content: YOLO, scene, named colors and metadata — OCR runs next as a separate stage…',
      stageFraction: initialContentUnits <= 0
          ? 0
          : (snapshot.safeContentIndexed + snapshot.safeVideoContentIndexed) /
              initialContentUnits,
    );

    final startingCount = snapshot.safeContentIndexed;
    if (startingCount < snapshot.total) {
      final result = await _contentBridge.indexAll(
        shouldCancel: () => _cancelRequested,
        onQueueProgress: (p) {
          if (!progress.value.running ||
              progress.value.stage != CompleteSmartIndexStage.content) {
            return;
          }
          progress.value = progress.value.copyWith(
            status: 'Content: checking library queue ${p.discovered}/${p.total}…',
          );
        },
        onProgress: (p) {
          if (!progress.value.running ||
              progress.value.stage != CompleteSmartIndexStage.content) {
            return;
          }
          final liveCount = (startingCount + p.processed)
              .clamp(0, progress.value.snapshot.total)
              .toInt();
          final currentSnapshot = progress.value.snapshot;
          final denominator = currentSnapshot.total +
              (currentSnapshot.videoIndexingEnabled
                  ? currentSnapshot.videoTotal
                  : 0);
          final fraction = denominator <= 0
              ? null
              : (liveCount + currentSnapshot.safeVideoContentIndexed) /
                  denominator;
          progress.value = progress.value.copyWith(
            stageFraction: fraction,
            status: p.assetName == null
                ? 'Content: ${p.phase}'
                : 'Content: ${p.phase}\n${p.assetName}',
          );
        },
      );

      snapshot = await refresh();
      final photoVideoUnits =
          snapshot.total + (snapshot.videoIndexingEnabled ? snapshot.videoTotal : 0);
      progress.value = progress.value.copyWith(
        snapshot: snapshot,
        stageFraction: photoVideoUnits <= 0
            ? 1
            : (snapshot.safeContentIndexed + snapshot.safeVideoContentIndexed) /
                photoVideoUnits,
        status: result.pausedReason ??
            'Photo content ready: ${snapshot.safeContentIndexed}/${snapshot.total}; ${result.failed} failed in this pass.',
      );

      // A thermal/device-health pause is a signal to stop the entire heavy
      // sequence instead of immediately starting Face/Visual work.
      if (result.pausedReason != null) {
        _cancelRequested = true;
        return;
      }
    }

    snapshot = await refresh();
    if (snapshot.videoIndexingEnabled &&
        !snapshot.videoContentComplete &&
        !_cancelRequested) {
      final startingVideo = snapshot.safeVideoContentIndexed;
      void videoListener() {
        final p = _videoIndexer.progress.value;
        if (!progress.value.running ||
            progress.value.stage != CompleteSmartIndexStage.content) {
          return;
        }
        final currentSnapshot = progress.value.snapshot;
        final denominator = currentSnapshot.total + currentSnapshot.videoTotal;
        final liveVideo = (startingVideo + p.processed)
            .clamp(0, currentSnapshot.videoTotal)
            .toInt();
        progress.value = progress.value.copyWith(
          stageFraction: denominator <= 0
              ? null
              : (currentSnapshot.safeContentIndexed + liveVideo) / denominator,
          status: p.assetName == null
              ? p.phase
              : '${p.phase}\n${p.assetName}',
        );
      }

      _videoIndexer.progress.addListener(videoListener);
      try {
        await _videoIndexer.indexMissingObjects(
          shouldCancel: () => _cancelRequested,
        );
      } finally {
        _videoIndexer.progress.removeListener(videoListener);
      }
    }

    snapshot = await refresh();
    final denominator =
        snapshot.total + (snapshot.videoIndexingEnabled ? snapshot.videoTotal : 0);
    progress.value = progress.value.copyWith(
      snapshot: snapshot,
      stageFraction: denominator <= 0
          ? 1
          : (snapshot.safeContentIndexed + snapshot.safeVideoContentIndexed) /
              denominator,
      status: snapshot.videoIndexingEnabled
          ? 'Content ready: photos ${snapshot.safeContentIndexed}/${snapshot.total} • videos ${snapshot.safeVideoContentIndexed}/${snapshot.videoTotal}. OCR continues as its own photo stage.'
          : 'Content ready: ${snapshot.safeContentIndexed}/${snapshot.total} photos. Smart video indexing is off.',
    );
  }

  Future<void> _runOcrStage() async {
    var snapshot = await refresh();
    if (snapshot.ocrComplete || _cancelRequested) return;

    final startingCount = snapshot.safeOcrIndexed;
    progress.value = progress.value.copyWith(
      running: true,
      stage: CompleteSmartIndexStage.ocr,
      snapshot: snapshot,
      status: snapshot.arabicOcrEnabled
          ? 'Text Recognition: English OCR first, Arabic OCR when needed…'
          : 'Text Recognition: English OCR only; Arabic OCR is disabled.',
      stageFraction: snapshot.total <= 0 ? 0 : startingCount / snapshot.total,
    );

    void listener() {
      final p = _ocrIndexer.progress.value;
      if (!progress.value.running ||
          progress.value.stage != CompleteSmartIndexStage.ocr) {
        return;
      }
      final total = progress.value.snapshot.total;
      final liveCount = (startingCount + p.processed).clamp(0, total).toInt();
      progress.value = progress.value.copyWith(
        snapshot: progress.value.snapshot.copyWith(ocrIndexed: liveCount),
        stageFraction: total <= 0 ? null : liveCount / total,
        status: p.status,
      );
    }

    _ocrIndexer.progress.addListener(listener);
    try {
      if (!_ocrIndexer.isRunning) {
        await _ocrIndexer.start(limit: null);
      }
      while (_ocrIndexer.isRunning && !_cancelRequested) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      _ocrIndexer.progress.removeListener(listener);
    }

    snapshot = await refresh();
    progress.value = progress.value.copyWith(
      snapshot: snapshot,
      stageFraction: snapshot.total <= 0 ? 1 : snapshot.safeOcrIndexed / snapshot.total,
      status: 'Text Recognition ready: ${snapshot.safeOcrIndexed}/${snapshot.total}.',
    );
  }

  Future<void> _runPeopleStage() async {
    var snapshot = await refresh();
    if (snapshot.peopleComplete || _cancelRequested) return;

    final startingCount = snapshot.safePeopleIndexed;
    final initialPeopleUnits =
        snapshot.total + (snapshot.videoIndexingEnabled ? snapshot.videoTotal : 0);
    progress.value = progress.value.copyWith(
      running: true,
      stage: CompleteSmartIndexStage.people,
      snapshot: snapshot,
      status: 'People: continuing Face v3 only for photos not already scanned…',
      stageFraction: initialPeopleUnits <= 0
          ? 0
          : (startingCount + snapshot.safeVideoPeopleIndexed) /
              initialPeopleUnits,
    );

    void listener() {
      final p = _faceIndexer.progress.value;
      if (!progress.value.running ||
          progress.value.stage != CompleteSmartIndexStage.people) {
        return;
      }
      final currentSnapshot = progress.value.snapshot;
      final total = currentSnapshot.total;
      final liveCount = (startingCount + p.processed).clamp(0, total).toInt();
      final denominator = total +
          (currentSnapshot.videoIndexingEnabled
              ? currentSnapshot.videoTotal
              : 0);
      progress.value = progress.value.copyWith(
        snapshot: progress.value.snapshot.copyWith(peopleIndexed: liveCount),
        stageFraction: denominator <= 0
            ? null
            : (liveCount + currentSnapshot.safeVideoPeopleIndexed) /
                denominator,
        status: p.status,
      );
    }

    if (startingCount < snapshot.total) {
      _faceIndexer.progress.addListener(listener);
      try {
        if (!_faceIndexer.isRunning) {
          await _faceIndexer.start(limit: null);
        }
        await _waitForFaceIdle();
      } finally {
        _faceIndexer.progress.removeListener(listener);
      }
    }

    snapshot = await refresh();
    if (snapshot.videoIndexingEnabled &&
        !snapshot.videoPeopleComplete &&
        !_cancelRequested) {
      final startingVideo = snapshot.safeVideoPeopleIndexed;
      void videoListener() {
        final p = _videoIndexer.progress.value;
        if (!progress.value.running ||
            progress.value.stage != CompleteSmartIndexStage.people) {
          return;
        }
        final currentSnapshot = progress.value.snapshot;
        final denominator = currentSnapshot.total + currentSnapshot.videoTotal;
        final liveVideo = (startingVideo + p.processed)
            .clamp(0, currentSnapshot.videoTotal)
            .toInt();
        progress.value = progress.value.copyWith(
          stageFraction: denominator <= 0
              ? null
              : (currentSnapshot.safePeopleIndexed + liveVideo) / denominator,
          status: p.assetName == null
              ? p.phase
              : '${p.phase}\n${p.assetName}',
        );
      }

      _videoIndexer.progress.addListener(videoListener);
      try {
        await _videoIndexer.indexMissingPeople(
          shouldCancel: () => _cancelRequested,
        );
      } finally {
        _videoIndexer.progress.removeListener(videoListener);
      }
    }

    snapshot = await refresh();
    final denominator =
        snapshot.total + (snapshot.videoIndexingEnabled ? snapshot.videoTotal : 0);
    progress.value = progress.value.copyWith(
      snapshot: snapshot,
      stageFraction: denominator <= 0
          ? 1
          : (snapshot.safePeopleIndexed + snapshot.safeVideoPeopleIndexed) /
              denominator,
      status: snapshot.videoIndexingEnabled
          ? 'People ready: photos ${snapshot.safePeopleIndexed}/${snapshot.total} • videos ${snapshot.safeVideoPeopleIndexed}/${snapshot.videoTotal}. Video frames only match stable existing People; they do not alter Face Lab clusters.'
          : 'People ready: ${snapshot.safePeopleIndexed}/${snapshot.total} photos. Smart video indexing is off.',
    );
  }

  Future<void> _runVisualStage() async {
    var snapshot = await refresh();
    if (snapshot.visualComplete || _cancelRequested) return;

    final startingCount = snapshot.safeVisualIndexed;
    progress.value = progress.value.copyWith(
      running: true,
      stage: CompleteSmartIndexStage.visual,
      snapshot: snapshot,
      status: 'Visual search: generating only missing image embeddings…',
      stageFraction: snapshot.total <= 0
          ? 0
          : startingCount / snapshot.total,
    );

    final summary = await _visualIndexer.indexAllMissing(
      shouldCancel: () => _cancelRequested,
      onProgress: (p) {
        if (!progress.value.running ||
            progress.value.stage != CompleteSmartIndexStage.visual) {
          return;
        }
        final total = progress.value.snapshot.total;
        final liveCount = (startingCount + p.indexed).clamp(0, total).toInt();
        progress.value = progress.value.copyWith(
          snapshot: progress.value.snapshot.copyWith(visualIndexed: liveCount),
          stageFraction: total <= 0 ? null : liveCount / total,
          status: p.assetName == null
              ? 'Visual search: generating embeddings…'
              : 'Visual search: ${p.visited}/${p.total} checked\n${p.assetName}',
        );
      },
    );

    snapshot = await refresh();
    progress.value = progress.value.copyWith(
      snapshot: snapshot,
      stageFraction: snapshot.total <= 0
          ? 1
          : snapshot.safeVisualIndexed / snapshot.total,
      status: summary.cancelled
          ? 'Visual indexing stopped safely.'
          : 'Visual search ready: ${snapshot.safeVisualIndexed}/${snapshot.total}; ${summary.failed} failed in this pass.',
    );
  }

  Future<void> _waitForGalleryIdle() async {
    if (!_galleryIndexer.progress.value.running) return;
    final completer = Completer<void>();
    void listener() {
      if (!_galleryIndexer.progress.value.running && !completer.isCompleted) {
        completer.complete();
      }
    }
    _galleryIndexer.progress.addListener(listener);
    try {
      listener();
      if (!completer.isCompleted) await completer.future;
    } finally {
      _galleryIndexer.progress.removeListener(listener);
    }
  }

  Future<void> _waitForFaceIdle() async {
    if (!_faceIndexer.isRunning) return;
    final completer = Completer<void>();
    void listener() {
      if (!_faceIndexer.progress.value.running && !completer.isCompleted) {
        completer.complete();
      }
    }
    _faceIndexer.progress.addListener(listener);
    try {
      listener();
      if (!completer.isCompleted) await completer.future;
    } finally {
      _faceIndexer.progress.removeListener(listener);
    }
  }

  Future<void> _finishStopped() async {
    final snapshot = await _safeRefreshSnapshot();
    progress.value = CompleteSmartIndexState(
      running: false,
      stage: CompleteSmartIndexStage.stopped,
      snapshot: snapshot,
      status:
          'Smart Index stopped safely. Completed media stages are saved; Continue Smart Index will resume only what is missing.',
      stageFraction: null,
    );
  }

  Future<CompleteSmartIndexSnapshot> _safeRefreshSnapshot() async {
    try {
      return await refresh();
    } catch (_) {
      return progress.value.snapshot;
    }
  }
}
