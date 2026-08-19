import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../data/database/db_helper.dart';
import '../../data/prefs/app_prefs.dart';
import '../../data/repositories/media_repository.dart';
import '../../features/search/search_vocabulary.dart';
import '../ai/heavy_ai_coordinator.dart';
import '../ai/ocr_service.dart';
import '../device/device_health_service.dart';

@immutable
class OcrIndexProgress {
  const OcrIndexProgress({
    required this.running,
    required this.processed,
    required this.total,
    required this.failed,
    required this.status,
    required this.arabicEnabled,
  });

  const OcrIndexProgress.idle()
      : running = false,
        processed = 0,
        total = 0,
        failed = 0,
        status = 'Text Recognition is ready.',
        arabicEnabled = true;

  final bool running;
  final int processed;
  final int total;
  final int failed;
  final String status;
  final bool arabicEnabled;

  double? get fraction => total <= 0
      ? null
      : (processed / total).clamp(0.0, 1.0).toDouble();

  OcrIndexProgress copyWith({
    bool? running,
    int? processed,
    int? total,
    int? failed,
    String? status,
    bool? arabicEnabled,
  }) {
    return OcrIndexProgress(
      running: running ?? this.running,
      processed: processed ?? this.processed,
      total: total ?? this.total,
      failed: failed ?? this.failed,
      status: status ?? this.status,
      arabicEnabled: arabicEnabled ?? this.arabicEnabled,
    );
  }
}

@immutable
class OcrIndexRunSummary {
  const OcrIndexRunSummary({
    required this.processed,
    required this.failed,
    required this.cancelled,
  });

  final int processed;
  final int failed;
  final bool cancelled;
}

/// Independent, resumable OCR stage introduced in v2.3.8.
///
/// Content indexing no longer waits for OCR. Objects/scenes/colors/metadata are
/// searchable first, while this service fills text into the same search row
/// later. Completion is tracked separately in SQLite, so Content, Face and
/// Visual indexing never have to be repeated just because OCR is slow.
class OcrIndexService {
  OcrIndexService._();
  static final OcrIndexService instance = OcrIndexService._();

  final MediaRepository _media = MediaRepository();
  final DatabaseHelper _database = DatabaseHelper.instance;

  final ValueNotifier<OcrIndexProgress> progress =
      ValueNotifier<OcrIndexProgress>(const OcrIndexProgress.idle());

  bool _cancelRequested = false;

  bool get isRunning => progress.value.running;

  void stop() => _cancelRequested = true;

  Future<int> indexedCount() async {
    final arabic = await AppPrefs.instance.arabicOcrEnabled;
    return _database.getOcrIndexedCount(arabicRequired: arabic);
  }

  Future<int> failedCount() => _database.getOcrFailedCount();

  /// Starts a foreground OCR run and returns immediately.
  ///
  /// [limit] = 20 means the next 20 photos missing OCR. null means all missing.
  /// [refreshRecent] deliberately re-OCRs the latest [limit] photos, useful for
  /// testing/tuning without touching Content/People/Visual indexes.
  Future<bool> start({int? limit, bool refreshRecent = false}) async {
    if (isRunning) return false;
    final permission = await _media.checkPermission();
    if (!permission.hasAccess) {
      throw StateError('صلاحية الصور مطلوبة قبل فهرسة النصوص.');
    }
    _cancelRequested = false;
    final arabic = await AppPrefs.instance.arabicOcrEnabled;
    final totalPhotos = await _media.getTotalCount(RequestType.image);
    final completed = refreshRecent
        ? const <String>{}
        : await _database.getOcrIndexedAssetIds(arabicRequired: arabic);
    final remaining = refreshRecent
        ? (limit ?? totalPhotos).clamp(0, totalPhotos).toInt()
        : (totalPhotos - completed.length).clamp(0, totalPhotos).toInt();
    final target = limit == null ? remaining : remaining.clamp(0, limit).toInt();

    progress.value = OcrIndexProgress(
      running: true,
      processed: 0,
      total: target,
      failed: 0,
      status: refreshRecent
          ? 'Refreshing text recognition for the latest $target photos…'
          : 'Preparing independent Text Recognition…',
      arabicEnabled: arabic,
    );
    unawaited(_run(limit: limit, refreshRecent: refreshRecent, arabic: arabic));
    return true;
  }

  Future<void> _run({
    required int? limit,
    required bool refreshRecent,
    required bool arabic,
  }) async {
    var processed = 0;
    var failed = 0;
    try {
      final completedIds = refreshRecent
          ? <String>{}
          : await _database.getOcrIndexedAssetIds(arabicRequired: arabic);
      final libraryTotal = await _media.getTotalCount(RequestType.image);
      const pageSize = 60;
      var page = 0;

      while (!_cancelRequested && (limit == null || processed < limit)) {
        final assets = await _media.loadRawPage(
          type: RequestType.image,
          page: page,
          pageSize: pageSize,
        );
        if (assets.isEmpty) break;
        page++;

        for (final asset in assets) {
          if (_cancelRequested || (limit != null && processed >= limit)) break;
          if (!refreshRecent && completedIds.contains(asset.id)) continue;

          final gate = await DeviceHealthService.instance.canContinueIndexing(
            checkLowBattery: false,
            checkThermal: true,
          );
          if (!gate.allowed) {
            progress.value = progress.value.copyWith(
              running: false,
              processed: processed,
              failed: failed,
              status: '${gate.reason} التقدم محفوظ ويمكن المتابعة لاحقًا.',
            );
            return;
          }

          final lease = await HeavyAiCoordinator.instance.acquire(
            task: 'ocr-foreground',
            wait: true,
          );
          if (lease == null) continue;

          try {
            progress.value = progress.value.copyWith(
              processed: processed,
              failed: failed,
              status: arabic
                  ? 'Text Recognition: ${asset.title ?? 'صورة'} — English + Arabic when needed'
                  : 'Text Recognition: ${asset.title ?? 'صورة'} — English only',
            );
            final file = await asset.file;
            if (file == null) {
              throw StateError('تعذر فتح ملف الصورة');
            }
            final extraction = await OcrService.instance.extractCombinedText(
              file.path,
              arabic: arabic
                  ? (refreshRecent ? ArabicOcrMode.force : ArabicOcrMode.auto)
                  : ArabicOcrMode.off,
            );
            await _database.upsertOcrIndex(
              assetId: asset.id,
              title: asset.title ?? '',
              takenAt: asset.createDateTime.millisecondsSinceEpoch,
              width: asset.width,
              height: asset.height,
              ocrText: extraction.text,
              ocrSearchText: SearchVocabulary.normalize(extraction.text),
              ocrScriptsJson: jsonEncode(extraction.scripts),
              arabicEnabled: arabic,
              engine: arabic ? 'mlkit-latin+tesseract-ara' : 'mlkit-latin',
            );
          } catch (error, stackTrace) {
            failed++;
            await _database.markOcrFailed(
              asset.id,
              error,
              arabicEnabled: arabic,
              engine: arabic ? 'mlkit-latin+tesseract-ara' : 'mlkit-latin',
            );
            debugPrint('PixMind OCR index error for ${asset.id}: $error\n$stackTrace');
          } finally {
            await lease.release();
          }

          processed++;
          progress.value = progress.value.copyWith(
            processed: processed,
            failed: failed,
          );
          // A tiny yield keeps scrolling responsive without materially slowing
          // the already much heavier OCR work.
          await Future<void>.delayed(const Duration(milliseconds: 12));
        }

        if (refreshRecent && limit != null && processed >= limit) break;
        if (page * pageSize >= libraryTotal && !refreshRecent) break;
      }

      progress.value = progress.value.copyWith(
        running: false,
        processed: processed,
        total: processed,
        failed: failed,
        status: _cancelRequested
            ? 'Text Recognition stopped safely after $processed photos. Progress is saved.'
            : processed == 0
                ? 'Text Recognition is already complete for the current OCR mode.'
                : 'Text Recognition finished: $processed photos, $failed failed.',
      );
    } catch (error, stackTrace) {
      debugPrint('PixMind Text Recognition failed: $error\n$stackTrace');
      progress.value = progress.value.copyWith(
        running: false,
        processed: processed,
        failed: failed,
        status: 'Text Recognition stopped: $error',
      );
    }
  }
}
