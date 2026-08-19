import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../data/database/db_helper.dart';
import '../../data/repositories/media_repository.dart';
import '../../features/search/search_vocabulary.dart';
import '../ai/face_service.dart';
import '../ai/heavy_ai_coordinator.dart';
import '../ai/object_detection_service.dart';
import 'video_frame_extractor.dart';

@immutable
class VideoIndexProgress {
  const VideoIndexProgress({
    required this.running,
    required this.phase,
    required this.processed,
    required this.total,
    required this.failed,
    this.assetName,
    this.frame,
    this.frameTotal,
  });

  const VideoIndexProgress.idle()
      : running = false,
        phase = 'Video index is ready.',
        processed = 0,
        total = 0,
        failed = 0,
        assetName = null,
        frame = null,
        frameTotal = null;

  final bool running;
  final String phase;
  final int processed;
  final int total;
  final int failed;
  final String? assetName;
  final int? frame;
  final int? frameTotal;

  double? get fraction => total <= 0 ? null : processed / total;
}

@immutable
class VideoIndexSummary {
  const VideoIndexSummary({
    required this.processed,
    required this.failed,
    required this.cancelled,
  });

  final int processed;
  final int failed;
  final bool cancelled;
}

/// Experimental Smart Video Index v1.
///
/// Content stage samples frames and stores YOLO object terms plus timestamps
/// where a person was seen. People stage later revisits only those candidate
/// frames, after photo Face v3 has built stable identities, and matches them
/// conservatively without adding video frames to the Face Lab clusters.
class VideoIndexService {
  VideoIndexService({
    MediaRepository? mediaRepository,
    DatabaseHelper? database,
    VideoFrameExtractor? extractor,
  })  : _mediaRepository = mediaRepository ?? MediaRepository(),
        _database = database ?? DatabaseHelper.instance,
        _extractor = extractor ?? VideoFrameExtractor.instance;

  final MediaRepository _mediaRepository;
  final DatabaseHelper _database;
  final VideoFrameExtractor _extractor;

  final ValueNotifier<VideoIndexProgress> progress =
      ValueNotifier<VideoIndexProgress>(const VideoIndexProgress.idle());

  bool _cancelRequested = false;
  bool get isRunning => progress.value.running;

  void stop() => _cancelRequested = true;

  Future<int> totalVideos() => _mediaRepository.getTotalCount(RequestType.video);
  Future<int> objectIndexedCount() => _database.getCompletedVideoObjectCount();
  Future<int> peopleIndexedCount() => _database.getCompletedVideoPeopleCount();

  Future<VideoIndexSummary> indexMissingObjects({
    bool Function()? shouldCancel,
  }) async {
    if (isRunning) {
      return const VideoIndexSummary(processed: 0, failed: 0, cancelled: true);
    }
    _cancelRequested = false;

    final completed = await _database.getCompletedVideoObjectAssetIds();
    final videos = await _allVideos();
    final pending = videos.where((video) => !completed.contains(video.id)).toList();
    var processed = 0;
    var failed = 0;

    progress.value = VideoIndexProgress(
      running: true,
      phase: 'Video content: preparing sampled frames…',
      processed: 0,
      total: pending.length,
      failed: 0,
    );

    final lease = await HeavyAiCoordinator.instance.acquire(
      task: 'video-content',
      wait: true,
      maxWait: const Duration(seconds: 30),
    );
    if (lease == null) {
      progress.value = const VideoIndexProgress.idle();
      return const VideoIndexSummary(processed: 0, failed: 0, cancelled: true);
    }

    try {
      for (final video in pending) {
        if (_shouldStop(shouldCancel)) break;
        try {
          await _indexVideoObjects(video, processed: processed, total: pending.length, failed: failed);
          if (_shouldStop(shouldCancel)) break;
          processed++;
        } catch (error, stackTrace) {
          failed++;
          debugPrint('PixMind video object index failed ${video.id}: $error\n$stackTrace');
          await _database.markVideoObjectFailed(video.id, error);
        }
        await lease.refresh();
        progress.value = VideoIndexProgress(
          running: true,
          phase: 'Video content: ${processed + failed}/${pending.length} videos checked.',
          processed: processed + failed,
          total: pending.length,
          failed: failed,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      await lease.release();
    }

    final cancelled = _shouldStop(shouldCancel);
    progress.value = VideoIndexProgress(
      running: false,
      phase: cancelled
          ? 'Video content stopped safely; completed videos are saved.'
          : 'Video content ready: $processed indexed, $failed failed.',
      processed: processed + failed,
      total: pending.length,
      failed: failed,
    );
    return VideoIndexSummary(
      processed: processed,
      failed: failed,
      cancelled: cancelled,
    );
  }

  Future<VideoIndexSummary> indexMissingPeople({
    bool Function()? shouldCancel,
  }) async {
    if (isRunning) {
      return const VideoIndexSummary(processed: 0, failed: 0, cancelled: true);
    }
    _cancelRequested = false;

    final objectDone = await _database.getCompletedVideoObjectAssetIds();
    final peopleDone = await _database.getCompletedVideoPeopleAssetIds();
    final videos = await _allVideos();
    final pending = videos
        .where((video) => objectDone.contains(video.id) && !peopleDone.contains(video.id))
        .toList();
    var processed = 0;
    var failed = 0;

    progress.value = VideoIndexProgress(
      running: true,
      phase: 'Video people: matching sampled person frames to existing People…',
      processed: 0,
      total: pending.length,
      failed: 0,
    );

    final lease = await HeavyAiCoordinator.instance.acquire(
      task: 'video-people',
      wait: true,
      maxWait: const Duration(seconds: 30),
    );
    if (lease == null) {
      progress.value = const VideoIndexProgress.idle();
      return const VideoIndexSummary(processed: 0, failed: 0, cancelled: true);
    }

    try {
      for (final video in pending) {
        if (_shouldStop(shouldCancel)) break;
        try {
          await _indexVideoPeople(video, processed: processed, total: pending.length, failed: failed);
          if (_shouldStop(shouldCancel)) break;
          processed++;
        } catch (error, stackTrace) {
          failed++;
          debugPrint('PixMind video people index failed ${video.id}: $error\n$stackTrace');
          await _database.markVideoPeopleFailed(video.id, error);
        }
        await lease.refresh();
        progress.value = VideoIndexProgress(
          running: true,
          phase: 'Video people: ${processed + failed}/${pending.length} videos checked.',
          processed: processed + failed,
          total: pending.length,
          failed: failed,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      await lease.release();
    }

    final cancelled = _shouldStop(shouldCancel);
    progress.value = VideoIndexProgress(
      running: false,
      phase: cancelled
          ? 'Video people stopped safely; completed videos are saved.'
          : 'Video people ready: $processed indexed, $failed failed.',
      processed: processed + failed,
      total: pending.length,
      failed: failed,
    );
    return VideoIndexSummary(
      processed: processed,
      failed: failed,
      cancelled: cancelled,
    );
  }

  Future<void> _indexVideoObjects(
    AssetEntity video, {
    required int processed,
    required int total,
    required int failed,
  }) async {
    final file = await video.file;
    if (file == null) throw StateError('Video file is not accessible.');
    final durationMs = video.videoDuration.inMilliseconds;
    final timestamps = _sampleTimestamps(durationMs);
    final firstTimestamp = <String, int>{};
    final hitCounts = <String, int>{};
    final personCandidates = <int>[];
    var extracted = 0;

    for (var index = 0; index < timestamps.length; index++) {
      if (_cancelRequested) break;
      final timestamp = timestamps[index];
      progress.value = VideoIndexProgress(
        running: true,
        phase: 'Video content: sampling frame ${index + 1}/${timestamps.length}',
        processed: processed,
        total: total,
        failed: failed,
        assetName: video.title ?? video.id,
        frame: index + 1,
        frameTotal: timestamps.length,
      );
      final jpeg = await _extractor.extractJpeg(
        path: file.path,
        timestampMs: timestamp,
      );
      if (jpeg == null) continue;
      extracted++;
      final labels = await ObjectDetectionService.instance.detect(jpeg);
      var hasPerson = false;
      for (final raw in labels) {
        final label = SearchVocabulary.normalize(raw);
        if (label.isEmpty) continue;
        firstTimestamp.putIfAbsent(label, () => timestamp);
        hitCounts[label] = (hitCounts[label] ?? 0) + 1;
        if (label == 'person' || label == 'people' || label == 'human') {
          hasPerson = true;
        }
      }
      if (hasPerson) personCandidates.add(timestamp);
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }

    if (_cancelRequested) return;
    if (timestamps.isNotEmpty && extracted == 0) {
      throw StateError('Could not extract any sampled video frame.');
    }
    await _database.replaceVideoObjectIndex(
      assetId: video.id,
      durationMs: durationMs,
      sampledFrames: extracted,
      firstTimestampMs: firstTimestamp,
      hitCounts: hitCounts,
      personCandidateTimestampsMs: personCandidates,
    );
  }

  Future<void> _indexVideoPeople(
    AssetEntity video, {
    required int processed,
    required int total,
    required int failed,
  }) async {
    final file = await video.file;
    if (file == null) throw StateError('Video file is not accessible.');
    var candidates = await _database.getVideoPersonCandidateTimestamps(video.id);
    if (candidates.length > 24) {
      candidates = _evenlyReduce(candidates, 24);
    }

    final firstTimestamp = <String, int>{};
    final hitCounts = <String, int>{};
    var extracted = 0;
    for (var index = 0; index < candidates.length; index++) {
      if (_cancelRequested) break;
      final timestamp = candidates[index];
      progress.value = VideoIndexProgress(
        running: true,
        phase: 'Video people: frame ${index + 1}/${candidates.length}',
        processed: processed,
        total: total,
        failed: failed,
        assetName: video.title ?? video.id,
        frame: index + 1,
        frameTotal: candidates.length,
      );
      final jpeg = await _extractor.extractJpeg(
        path: file.path,
        timestampMs: timestamp,
      );
      if (jpeg == null) continue;
      extracted++;
      final people = await FaceService.instance.matchExistingPeopleInJpeg(jpeg);
      for (final person in people) {
        firstTimestamp.putIfAbsent(person.id, () => timestamp);
        hitCounts[person.id] = (hitCounts[person.id] ?? 0) + 1;
      }
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }

    if (_cancelRequested) return;
    if (candidates.isNotEmpty && extracted == 0) {
      throw StateError('Could not extract any candidate frame for video people matching.');
    }
    await _database.replaceVideoPeopleIndex(
      assetId: video.id,
      firstTimestampMs: firstTimestamp,
      hitCounts: hitCounts,
    );
  }

  bool _shouldStop(bool Function()? external) =>
      _cancelRequested || (external?.call() ?? false);

  List<int> _sampleTimestamps(int durationMs) {
    if (durationMs <= 0) return const [0];
    final seconds = durationMs / 1000.0;
    var intervalMs = seconds <= 30
        ? 2000
        : seconds <= 120
            ? 3000
            : 5000;
    const maxFrames = 60;
    if ((durationMs / intervalMs).ceil() > maxFrames) {
      intervalMs = (durationMs / maxFrames).ceil();
    }

    final result = <int>[];
    var timestamp = durationMs < intervalMs ? durationMs ~/ 2 : intervalMs ~/ 2;
    while (timestamp < durationMs && result.length < maxFrames) {
      result.add(timestamp);
      timestamp += intervalMs;
    }
    if (result.isEmpty) result.add(0);
    return result;
  }

  List<int> _evenlyReduce(List<int> input, int maxItems) {
    if (input.length <= maxItems) return input;
    final result = <int>[];
    for (var i = 0; i < maxItems; i++) {
      final index = ((i * (input.length - 1)) / (maxItems - 1)).round();
      result.add(input[index]);
    }
    return result.toSet().toList()..sort();
  }

  Future<List<AssetEntity>> _allVideos() async {
    final total = await totalVideos();
    if (total <= 0) return const [];
    final videos = <AssetEntity>[];
    const pageSize = 80;
    for (var page = 0; videos.length < total; page++) {
      final batch = await _mediaRepository.loadRawPage(
        type: RequestType.video,
        page: page,
        pageSize: pageSize,
      );
      if (batch.isEmpty) break;
      videos.addAll(batch);
      if (batch.length < pageSize) break;
    }
    return videos;
  }
}
