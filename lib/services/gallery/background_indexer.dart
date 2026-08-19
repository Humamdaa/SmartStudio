import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../data/database/db_helper.dart';
import '../../data/prefs/app_prefs.dart';
import 'face_index_service.dart';
import 'precise_indexer.dart';

const _contentTaskName = 'pixmind.private.index.slice';
const _contentPeriodicUniqueName = 'pixmind.private.index.periodic';
const _contentTag = 'pixmind.private.index';

const _faceTaskName = 'pixmind.private.face.slice';
const _facePeriodicUniqueName = 'pixmind.private.face.periodic';
const _faceTag = 'pixmind.private.face';

@pragma('vm:entry-point')
void pixMindCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();

    if (taskName == _faceTaskName) {
      try {
        if (!await AppPrefs.instance.backgroundFaceIndexingEnabled) return true;
        final result = await FaceIndexService.instance.processBackgroundSlice(
          maxPhotos: 4,
        );
        await Workmanager().reportProgress({
          'processed': result.processed,
          'failed': result.failed,
          'busy': result.busy ? 1 : 0,
        });
        if ((result.hasMore || result.busy) &&
            await AppPrefs.instance.backgroundFaceIndexingEnabled) {
          await BackgroundIndexService.instance.scheduleNextFaceSlice(
            initialDelay: result.busy
                ? const Duration(minutes: 3)
                : const Duration(minutes: 2),
          );
        }
        return true;
      } catch (_) {
        // WorkManager's exponential retry plus Face v3's persistent face_scans
        // resume state makes an interrupted slice safe to retry.
        return false;
      }
    }

    // Default/background content task: YOLO + scene + OCR + named colors.
    try {
      if (!await AppPrefs.instance.backgroundIndexingEnabled) return true;
      final indexer = PreciseIndexer();
      await indexer.enqueueNextUnindexed(limit: 200);
      final result = await indexer.processQueueBatch(
        batchSize: 12,
        onProgress: (_) {},
        shouldCancel: () => false,
        waitWhilePaused: () async {},
        respectDeviceHealth: true,
        mode: 'background',
      );
      await Workmanager().reportProgress({
        'processed': result.processed,
        'pending': result.pending,
      });
      if (result.pending > 0 &&
          await AppPrefs.instance.backgroundIndexingEnabled) {
        await BackgroundIndexService.instance.scheduleNextContentSlice();
      }
      return true;
    } catch (_) {
      return false;
    }
  });
}

/// Android persistent background scheduler for the two heavy queues.
///
/// Content and Face use separate switches/tags, while the SQLite heavy-AI
/// lease prevents them from actually competing for CPU at the same time.
class BackgroundIndexService {
  BackgroundIndexService._();
  static final BackgroundIndexService instance = BackgroundIndexService._();

  bool _initialized = false;

  Constraints get _constraints => Constraints(
    networkType: NetworkType.notRequired,
    requiresBatteryNotLow: true,
    requiresStorageNotLow: true,
  );

  Future<void> initialize() async {
    if (_initialized || !Platform.isAndroid) return;
    await Workmanager().initialize(pixMindCallbackDispatcher);
    _initialized = true;

    if (await AppPrefs.instance.backgroundIndexingEnabled) {
      await ensureContentScheduled();
    }
    if (await AppPrefs.instance.backgroundFaceIndexingEnabled) {
      await ensureFaceScheduled();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    await AppPrefs.instance.setBackgroundIndexingEnabled(enabled);
    if (!Platform.isAndroid) return;
    if (!_initialized) await initialize();
    if (enabled) {
      await ensureContentScheduled();
    } else {
      await Workmanager().cancelByTag(_contentTag);
    }
  }

  Future<void> setFaceEnabled(bool enabled) async {
    await AppPrefs.instance.setBackgroundFaceIndexingEnabled(enabled);
    if (!Platform.isAndroid) return;
    if (!_initialized) await initialize();
    if (enabled) {
      await ensureFaceScheduled();
    } else {
      await Workmanager().cancelByTag(_faceTag);
    }
  }

  Future<void> ensureContentScheduled() async {
    if (!Platform.isAndroid) return;
    await Workmanager().registerPeriodicTask(
      _contentPeriodicUniqueName,
      _contentTaskName,
      frequency: const Duration(hours: 6),
      constraints: _constraints,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 10),
      tag: _contentTag,
    );
    await scheduleNextContentSlice(initialDelay: const Duration(seconds: 10));
  }

  Future<void> ensureFaceScheduled() async {
    if (!Platform.isAndroid) return;
    await Workmanager().registerPeriodicTask(
      _facePeriodicUniqueName,
      _faceTaskName,
      frequency: const Duration(hours: 6),
      constraints: _constraints,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 10),
      tag: _faceTag,
    );
    await scheduleNextFaceSlice(initialDelay: const Duration(seconds: 20));
  }

  // Kept for existing callers from v2.3.5.
  Future<void> scheduleNextSlice({
    Duration initialDelay = const Duration(minutes: 1),
  }) => scheduleNextContentSlice(initialDelay: initialDelay);

  Future<void> scheduleNextContentSlice({
    Duration initialDelay = const Duration(minutes: 1),
  }) async {
    if (!Platform.isAndroid) return;
    final pending = await DatabaseHelper.instance.getPendingQueueCount();
    if (pending == 0 && initialDelay >= const Duration(minutes: 1)) return;
    final uniqueName =
        'pixmind.private.index.once.${DateTime.now().millisecondsSinceEpoch}';
    await Workmanager().registerOneOffTask(
      uniqueName,
      _contentTaskName,
      initialDelay: initialDelay,
      constraints: _constraints,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 10),
      tag: _contentTag,
    );
  }

  Future<void> scheduleNextFaceSlice({
    Duration initialDelay = const Duration(minutes: 2),
  }) async {
    if (!Platform.isAndroid) return;
    if (!await AppPrefs.instance.backgroundFaceIndexingEnabled) return;
    final uniqueName =
        'pixmind.private.face.once.${DateTime.now().millisecondsSinceEpoch}';
    await Workmanager().registerOneOffTask(
      uniqueName,
      _faceTaskName,
      initialDelay: initialDelay,
      constraints: _constraints,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 10),
      tag: _faceTag,
    );
  }
}
