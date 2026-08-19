import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../data/repositories/media_repository.dart';
import '../ai/face_service.dart';
import '../ai/heavy_ai_coordinator.dart';
import '../device/device_health_service.dart';

@immutable
class FaceIndexProgress {
  const FaceIndexProgress({
    required this.running,
    required this.processed,
    required this.total,
    required this.failed,
    required this.detected,
    required this.ignored,
    required this.status,
    this.background = false,
  });

  const FaceIndexProgress.idle()
      : running = false,
        processed = 0,
        total = 0,
        failed = 0,
        detected = 0,
        ignored = 0,
        status = 'Face Lab v3 جاهز.',
        background = false;

  final bool running;
  final bool background;
  final int processed;
  final int total;
  final int failed;
  final int detected;
  final int ignored;
  final String status;

  double? get fraction {
    if (!running || total <= 0) return null;
    return (processed / total).clamp(0.0, 1.0).toDouble();
  }

  FaceIndexProgress copyWith({
    bool? running,
    bool? background,
    int? processed,
    int? total,
    int? failed,
    int? detected,
    int? ignored,
    String? status,
  }) {
    return FaceIndexProgress(
      running: running ?? this.running,
      background: background ?? this.background,
      processed: processed ?? this.processed,
      total: total ?? this.total,
      failed: failed ?? this.failed,
      detected: detected ?? this.detected,
      ignored: ignored ?? this.ignored,
      status: status ?? this.status,
    );
  }
}

class FaceBackgroundSliceSummary {
  const FaceBackgroundSliceSummary({
    required this.processed,
    required this.failed,
    required this.hasMore,
    required this.busy,
  });

  final int processed;
  final int failed;
  final bool hasMore;
  final bool busy;
}

/// App-wide Face v3 queue runner.
///
/// Unlike the old PeopleScreen loop, this singleton is not owned by a widget.
/// A foreground run therefore keeps going when the user leaves the People
/// page. Progress remains resumable in SQLite through FaceService/face_scans.
/// WorkManager uses [processBackgroundSlice] for tiny persistent Android
/// slices after the app leaves the foreground.
class FaceIndexService {
  FaceIndexService._();
  static final FaceIndexService instance = FaceIndexService._();

  final MediaRepository _mediaRepository = MediaRepository();

  final ValueNotifier<FaceIndexProgress> progress =
      ValueNotifier<FaceIndexProgress>(const FaceIndexProgress.idle());

  bool _cancelRequested = false;

  bool get isRunning => progress.value.running;

  void stop() => _cancelRequested = true;

  /// Starts an in-app run and returns immediately after validating access.
  /// [limit] = 20 for "next 20", null for all remaining photos.
  Future<bool> start({int? limit}) async {
    if (isRunning) return false;

    final permission = await _mediaRepository.checkPermission();
    if (!permission.hasAccess) {
      throw StateError('لا يوجد إذن للوصول إلى الصور.');
    }

    _cancelRequested = false;
    final total = await _mediaRepository.getTotalCount(RequestType.image);
    final completed = await FaceService.instance.completedAssetIds();
    final estimatedRemaining =
        (total - completed.length).clamp(0, total).toInt();
    final displayTarget = limit ?? estimatedRemaining;

    progress.value = FaceIndexProgress(
      running: true,
      processed: 0,
      total: displayTarget,
      failed: 0,
      detected: 0,
      ignored: 0,
      status: 'تجهيز Face Lab v3 واستعادة التقدم…',
    );

    unawaited(_runForeground(limit: limit));
    return true;
  }

  Future<void> _runForeground({int? limit}) async {
    try {
      final summary = await _run(
        limit: limit,
        background: false,
        updateNotifier: true,
      );
      final current = progress.value;
      if (_cancelRequested) {
        progress.value = current.copyWith(
          running: false,
          status:
              'تم إيقاف Face Lab بعد ${current.processed} صورة. التقدم محفوظ؛ المرة القادمة سيكمل من الصور غير المفهرسة.',
        );
      } else if (summary.processed == 0 && current.processed == 0) {
        progress.value = current.copyWith(
          running: false,
          total: 0,
          status: 'كل الصور الحالية مفهرسة للوجوه بالفعل.',
        );
      } else {
        progress.value = current.copyWith(
          running: false,
          total: current.processed,
          status:
              'اكتمل Face Lab: عالج ${current.processed} صورة جديدة، '
              'كشف ${current.detected} وجهًا وتجاهل ${current.ignored} وجهًا بعيدًا/ضعيفًا. '
              'تعذر ${current.failed} صورة.',
        );
      }
    } catch (error, stackTrace) {
      debugPrint('PixMind Face Lab failed: $error\n$stackTrace');
      progress.value = progress.value.copyWith(
        running: false,
        status: 'تعذر Face Lab: $error',
      );
    }
  }

  /// Tiny WorkManager slice. It never waits behind another heavy pipeline;
  /// instead it yields quickly and lets the scheduler try again later.
  Future<FaceBackgroundSliceSummary> processBackgroundSlice({
    int maxPhotos = 4,
  }) async {
    if (maxPhotos <= 0) {
      return const FaceBackgroundSliceSummary(
        processed: 0,
        failed: 0,
        hasMore: false,
        busy: false,
      );
    }
    return _run(
      limit: maxPhotos,
      background: true,
      updateNotifier: false,
    );
  }

  Future<FaceBackgroundSliceSummary> _run({
    required int? limit,
    required bool background,
    required bool updateNotifier,
  }) async {
    final permission = await _mediaRepository.checkPermission();
    if (!permission.hasAccess) {
      return const FaceBackgroundSliceSummary(
        processed: 0,
        failed: 0,
        hasMore: false,
        busy: false,
      );
    }

    final libraryTotal =
        await _mediaRepository.getTotalCount(RequestType.image);
    if (libraryTotal <= 0) {
      return const FaceBackgroundSliceSummary(
        processed: 0,
        failed: 0,
        hasMore: false,
        busy: false,
      );
    }

    final completedIds = await FaceService.instance.completedAssetIds();
    final estimatedRemaining =
        (libraryTotal - completedIds.length).clamp(0, libraryTotal).toInt();

    if (updateNotifier) {
      final current = progress.value;
      progress.value = current.copyWith(
        total: limit ?? estimatedRemaining,
        status:
            'متبقٍ تقريبًا $estimatedRemaining صورة للوجوه؛ جاري التحقق من المكتبة…',
      );
    }

    const pageSize = 60;
    var processed = 0;
    var failed = 0;
    var detected = 0;
    var ignored = 0;
    var page = 0;
    var reachedLibraryEnd = false;
    var busy = false;

    while ((limit == null || processed < limit) &&
        !(updateNotifier && _cancelRequested)) {
      final assets = await _mediaRepository.loadRawPage(
        type: RequestType.image,
        page: page,
        pageSize: pageSize,
      );
      if (assets.isEmpty) {
        reachedLibraryEnd = true;
        break;
      }
      page++;

      for (final asset in assets) {
        if ((limit != null && processed >= limit) ||
            (updateNotifier && _cancelRequested)) {
          break;
        }
        if (completedIds.contains(asset.id)) continue;

        final gate = await DeviceHealthService.instance.canContinueIndexing(
          checkLowBattery: background,
          checkThermal: true,
        );
        if (!gate.allowed) {
          if (updateNotifier) {
            progress.value = progress.value.copyWith(status: gate.reason);
          }
          return FaceBackgroundSliceSummary(
            processed: processed,
            failed: failed,
            hasMore: true,
            busy: false,
          );
        }

        final lease = await HeavyAiCoordinator.instance.acquire(
          task: background ? 'face-background' : 'face-foreground',
          wait: !background,
        );
        if (lease == null) {
          busy = true;
          if (updateNotifier) {
            progress.value = progress.value.copyWith(
              status: 'محرك ذكاء آخر يعمل الآن؛ Face Lab ينتظر دوره…',
            );
          }
          return FaceBackgroundSliceSummary(
            processed: processed,
            failed: failed,
            hasMore: true,
            busy: true,
          );
        }

        try {
          final file = await asset.file;
          if (file == null) {
            failed++;
          } else {
            if (updateNotifier) {
              progress.value = progress.value.copyWith(
                status: limit == null
                    ? 'Face Lab: ${asset.title ?? 'صورة'}  ${processed + 1} صورة جديدة'
                    : 'Face Lab: ${asset.title ?? 'صورة'}  ${processed + 1}/$limit',
              );
            }
            try {
              final result = await FaceService.instance.analyzeAndStore(
                assetId: asset.id,
                imagePath: file.path,
                force: false,
              );
              detected += result.detectedFaceCount;
              ignored += result.ignoredFaceCount;
            } catch (error, stackTrace) {
              failed++;
              debugPrint(
                'PixMind Face ${background ? 'background' : 'foreground'} '
                '${asset.id}: $error\n$stackTrace',
              );
            }
          }
        } finally {
          await lease.release();
        }

        processed++;
        if (updateNotifier) {
          progress.value = progress.value.copyWith(
            processed: processed,
            failed: failed,
            detected: detected,
            ignored: ignored,
          );
        }

        // Give Flutter/Android breathing room without meaningfully stretching
        // the overall run. Background work is intentionally gentler.
        await Future<void>.delayed(
          background
              ? const Duration(milliseconds: 90)
              : const Duration(milliseconds: 14),
        );

        if (processed > 0 && processed % 20 == 0) {
          await _refine(background: background, maxMerges: 80);
        }
      }
    }

    if (processed > 0 && !(updateNotifier && _cancelRequested)) {
      await _refine(
        background: background,
        maxMerges: background ? 32 : 160,
      );
    }

    if (updateNotifier && reachedLibraryEnd) {
      progress.value = progress.value.copyWith(total: processed);
    }

    final hasMore = !reachedLibraryEnd &&
        (limit != null && processed >= limit || estimatedRemaining > processed);
    return FaceBackgroundSliceSummary(
      processed: processed,
      failed: failed,
      hasMore: hasMore,
      busy: busy,
    );
  }

  Future<void> _refine({
    required bool background,
    required int maxMerges,
  }) async {
    final lease = await HeavyAiCoordinator.instance.acquire(
      task: background ? 'face-refine-background' : 'face-refine-foreground',
      wait: !background,
      maxWait: const Duration(seconds: 8),
    );
    if (lease == null) return;
    try {
      await FaceService.instance.refineClusters(maxMerges: maxMerges);
    } finally {
      await lease.release();
    }
  }
}
