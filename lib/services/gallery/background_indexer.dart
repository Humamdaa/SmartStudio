import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../data/database/db_helper.dart';
import '../../data/prefs/app_prefs.dart';
import 'precise_indexer.dart';

const _backgroundTaskName = 'pixmind.private.index.slice';
const _periodicUniqueName = 'pixmind.private.index.periodic';
const _backgroundTag = 'pixmind.private.index';

@pragma('vm:entry-point')
void pixMindCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      if (!await AppPrefs.instance.backgroundIndexingEnabled) return true;
      final indexer = PreciseIndexer();
      // Walks newest -> oldest across the whole library, so successive wake-ups
      // keep making progress. The old call enqueued only the newest 500 photos
      // every time, so once those were indexed the queue stayed empty for good
      // and the rest of the library was never reached.
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
        await BackgroundIndexService.instance.scheduleNextSlice();
      }
      return true;
    } catch (_) {
      // WorkManager retries with exponential backoff. The persistent queue
      // also releases stale claimed rows after an interrupted worker.
      return false;
    }
  });
}

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
      await ensureScheduled();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    await AppPrefs.instance.setBackgroundIndexingEnabled(enabled);
    if (!Platform.isAndroid) return;
    if (!_initialized) await initialize();
    if (enabled) {
      await ensureScheduled();
    } else {
      await Workmanager().cancelByTag(_backgroundTag);
    }
  }

  Future<void> ensureScheduled() async {
    if (!Platform.isAndroid) return;
    await Workmanager().registerPeriodicTask(
      _periodicUniqueName,
      _backgroundTaskName,
      frequency: const Duration(hours: 6),
      constraints: _constraints,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 10),
      tag: _backgroundTag,
    );
    await scheduleNextSlice(initialDelay: const Duration(seconds: 10));
  }

  Future<void> scheduleNextSlice({
    Duration initialDelay = const Duration(minutes: 1),
  }) async {
    if (!Platform.isAndroid) return;
    final pending = await DatabaseHelper.instance.getPendingQueueCount();
    if (pending == 0 && initialDelay >= const Duration(minutes: 1)) return;
    final uniqueName =
        'pixmind.private.index.once.${DateTime.now().millisecondsSinceEpoch}';
    await Workmanager().registerOneOffTask(
      uniqueName,
      _backgroundTaskName,
      initialDelay: initialDelay,
      constraints: _constraints,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 10),
      tag: _backgroundTag,
    );
  }
}
