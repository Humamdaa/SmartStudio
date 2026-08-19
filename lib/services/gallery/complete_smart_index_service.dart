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
  });

  const CompleteSmartIndexSnapshot.empty()
      : total = 0,
        galleryAnalyzed = 0,
        contentIndexed = 0,
        ocrIndexed = 0,
        peopleIndexed = 0,
        visualIndexed = 0,
        arabicOcrEnabled = true;

  final int total;
  final int galleryAnalyzed;
  final int contentIndexed;
  final int ocrIndexed;
  final int peopleIndexed;
  final int visualIndexed;
  final bool arabicOcrEnabled;

  int _safe(int value) => total <= 0 ? 0 : value.clamp(0, total).toInt();

  int get safeGalleryAnalyzed => _safe(galleryAnalyzed);
  int get safeContentIndexed => _safe(contentIndexed);
  int get safeOcrIndexed => _safe(ocrIndexed);
  int get safePeopleIndexed => _safe(peopleIndexed);
  int get safeVisualIndexed => _safe(visualIndexed);

  bool get galleryComplete => total > 0 && safeGalleryAnalyzed >= total;
  bool get contentComplete => total > 0 && safeContentIndexed >= total;
  bool get ocrComplete => total > 0 && safeOcrIndexed >= total;
  bool get peopleComplete => total > 0 && safePeopleIndexed >= total;
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
    final done = safeGalleryAnalyzed +
        safeContentIndexed +
        safeOcrIndexed +
        safePeopleIndexed +
        safeVisualIndexed;
    return (done / (total * 5)).clamp(0.0, 1.0).toDouble();
  }

  CompleteSmartIndexSnapshot copyWith({
    int? total,
    int? galleryAnalyzed,
    int? contentIndexed,
    int? ocrIndexed,
    int? peopleIndexed,
    int? visualIndexed,
    bool? arabicOcrEnabled,
  }) {
    return CompleteSmartIndexSnapshot(
      total: total ?? this.total,
      galleryAnalyzed: galleryAnalyzed ?? this.galleryAnalyzed,
      contentIndexed: contentIndexed ?? this.contentIndexed,
      ocrIndexed: ocrIndexed ?? this.ocrIndexed,
      peopleIndexed: peopleIndexed ?? this.peopleIndexed,
      visualIndexed: visualIndexed ?? this.visualIndexed,
      arabicOcrEnabled: arabicOcrEnabled ?? this.arabicOcrEnabled,
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

    final persistedCurrentStage = switch (stage) {
      CompleteSmartIndexStage.gallery => snapshot.safeGalleryAnalyzed,
      CompleteSmartIndexStage.content => snapshot.safeContentIndexed,
      CompleteSmartIndexStage.ocr => snapshot.safeOcrIndexed,
      CompleteSmartIndexStage.people => snapshot.safePeopleIndexed,
      CompleteSmartIndexStage.visual => snapshot.safeVisualIndexed,
      _ => -1,
    };
    if (persistedCurrentStage < 0) return base;

    final persistedDone = snapshot.safeGalleryAnalyzed +
        snapshot.safeContentIndexed +
        snapshot.safeOcrIndexed +
        snapshot.safePeopleIndexed +
        snapshot.safeVisualIndexed;
    final liveCurrentStage =
        (snapshot.total * stageFraction!).round().clamp(0, snapshot.total);
    final done = persistedDone -
        persistedCurrentStage +
        (liveCurrentStage > persistedCurrentStage
            ? liveCurrentStage
            : persistedCurrentStage);
    return (done / (snapshot.total * 5)).clamp(base, 1.0).toDouble();
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
  })  : _galleryIndexer = galleryIndexer,
        _contentBridge = contentBridge,
        _visualIndexer = visualIndexer,
        _visualRepository = visualRepository,
        _mediaRepository = mediaRepository ?? MediaRepository(),
        _database = database ?? DatabaseHelper.instance,
        _faceIndexer = faceIndexer ?? FaceIndexService.instance,
        _ocrIndexer = ocrIndexer ?? OcrIndexService.instance;

  final IndexingService _galleryIndexer;
  final SmartSearchBridge _contentBridge;
  final VisualSearchIndexer _visualIndexer;
  final VisualSearchRepository _visualRepository;
  final MediaRepository _mediaRepository;
  final DatabaseHelper _database;
  final FaceIndexService _faceIndexer;
  final OcrIndexService _ocrIndexer;

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
    final ocr = await _database.getOcrIndexedCount(arabicRequired: arabic);
    final people = await _database.getCompletedFaceScanCount(
      FaceService.facePipelineVersion,
    );
    final visual = await _visualRepository.countIndexedImages();

    final snapshot = CompleteSmartIndexSnapshot(
      total: total,
      galleryAnalyzed: _galleryIndexer.analyzedCount,
      contentIndexed: content,
      ocrIndexed: ocr,
      peopleIndexed: people,
      visualIndexed: visual,
      arabicOcrEnabled: arabic,
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
            ? 'Complete Smart Index finished. Every current photo is ready.'
            : 'Smart Index pass finished. Some photos remain and can be retried safely.',
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

    progress.value = progress.value.copyWith(
      running: true,
      stage: CompleteSmartIndexStage.content,
      snapshot: snapshot,
      status: 'Content: YOLO, scene, named colors and metadata — OCR runs next as a separate stage…',
      stageFraction: snapshot.total <= 0
          ? 0
          : snapshot.safeContentIndexed / snapshot.total,
    );

    final startingCount = snapshot.safeContentIndexed;
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
        final fraction = progress.value.snapshot.total <= 0
            ? null
            : liveCount / progress.value.snapshot.total;
        progress.value = progress.value.copyWith(
          stageFraction: fraction,
          status: p.assetName == null
              ? 'Content: ${p.phase}'
              : 'Content: ${p.phase}\n${p.assetName}',
        );
      },
    );

    snapshot = await refresh();
    progress.value = progress.value.copyWith(
      snapshot: snapshot,
      stageFraction: snapshot.total <= 0
          ? 1
          : snapshot.safeContentIndexed / snapshot.total,
      status: result.pausedReason ??
          'Content ready: ${snapshot.safeContentIndexed}/${snapshot.total}; ${result.failed} failed in this pass. Text Recognition can continue independently.',
    );

    // A thermal/device-health pause is a signal to stop the entire heavy
    // sequence instead of immediately starting Face/Visual work.
    if (result.pausedReason != null) {
      _cancelRequested = true;
    }
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
    progress.value = progress.value.copyWith(
      running: true,
      stage: CompleteSmartIndexStage.people,
      snapshot: snapshot,
      status: 'People: continuing Face v3 only for photos not already scanned…',
      stageFraction: snapshot.total <= 0
          ? 0
          : startingCount / snapshot.total,
    );

    void listener() {
      final p = _faceIndexer.progress.value;
      if (!progress.value.running ||
          progress.value.stage != CompleteSmartIndexStage.people) {
        return;
      }
      final total = progress.value.snapshot.total;
      final liveCount = (startingCount + p.processed).clamp(0, total).toInt();
      progress.value = progress.value.copyWith(
        snapshot: progress.value.snapshot.copyWith(peopleIndexed: liveCount),
        stageFraction: total <= 0 ? null : liveCount / total,
        status: p.status,
      );
    }

    _faceIndexer.progress.addListener(listener);
    try {
      if (!_faceIndexer.isRunning) {
        await _faceIndexer.start(limit: null);
      }
      await _waitForFaceIdle();
    } finally {
      _faceIndexer.progress.removeListener(listener);
    }

    snapshot = await refresh();
    progress.value = progress.value.copyWith(
      snapshot: snapshot,
      stageFraction: snapshot.total <= 0
          ? 1
          : snapshot.safePeopleIndexed / snapshot.total,
      status: 'People ready: ${snapshot.safePeopleIndexed}/${snapshot.total} photos completed for Face v3.',
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
          'Smart Index stopped safely. Completed stages/photos are saved; Continue Smart Index will resume only what is missing.',
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
