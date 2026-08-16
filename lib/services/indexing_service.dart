import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:objectbox/objectbox.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/database/db_helper.dart';
import '../data/database/objectbox/entities.dart';
import '../data/database/objectbox/objectbox_store.dart';
import '../objectbox.g.dart';
import 'image_analysis.dart';

// ═══════════════════════════════════════════════════════════════
// خدمة الفهرسة — تحلّل المكتبة مرة وحدة وتخزّن النتيجة.
//
// ملاحظات أداء مهمة (تعلّمناها من التجربة الأولى البطيئة):
//
//  1. التحليل بـ **دفعات** — نداء Isolate واحد لكل 24 صورة
//     بدل نداء لكل صورة. إنشاء الـ Isolate كان أغلى من
//     التحليل نفسه.
//
//  2. صورة مصغّرة 128 بدل 160 — pHash بيشتغل على 32×32
//     واللون على 48×48، فـ 128 أكثر من كافية.
//
//  3. الحفظ بمعاملة (transaction) واحدة لكل دفعة بدل
//     كتابة منفصلة لكل صف.
//
//  4. استراحة قصيرة بين الدفعات حتى الواجهة تتنفّس.
// ═══════════════════════════════════════════════════════════════

class IndexProgress {
  final int done;
  final int total;
  final bool running;

  const IndexProgress({
    this.done = 0,
    this.total = 0,
    this.running = false,
  });

  double get fraction => total == 0 ? 0 : done / total;
  bool get isComplete => total > 0 && done >= total;
}

class IndexingService {
  IndexingService(this._store);

  final ObjectBoxStore _store;

  /// حجم الدفعة — موازنة بين سرعة الفهرسة وسلاسة الواجهة.
  /// أصغر = توقّفات أقصر على الخيط الرئيسي = واجهة أنعم.
  static const _batchSize = 12;
  static const _thumbSize = 128;

  Box<MediaAnalysis> get _box => _store.analysisBox;

  final ValueNotifier<IndexProgress> progress =
      ValueNotifier(const IndexProgress());

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  Set<String> _indexedIds() => _box
      .query(MediaAnalysis_.isAnalyzed.equals(true))
      .build()
      .property(MediaAnalysis_.assetId)
      .find()
      .toSet();

  /// يفهرس الصور غير المحلّلة.
  ///
  /// [background] = فهرسة تلقائية بالخلفية: منترك استراحة أطول
  /// بين الدفعات حتى التطبيق يضل سريع الاستجابة أثناء استخدام
  /// المستخدم العادي. الفهرسة اليدوية (زر Scan) بتكون أسرع.
  Future<void> indexLibrary({int? limit, bool background = false}) async {
    if (progress.value.running) return;
    _cancelled = false;

    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    if (albums.isEmpty) return;

    final total = await albums.first.assetCountAsync;
    final count = limit != null && limit < total ? limit : total;
    final assets = await albums.first.getAssetListRange(start: 0, end: count);

    // ننظّف صفوف الصور اللي انحذفت من الجهاز — بدونها بيضل
    // العدّاد يحسبها وبتضل تظهر بنتائج المكرّرات.
    _pruneDeleted(assets.map((a) => a.id).toSet());

    final already = _indexedIds();
    final pending = assets.where((a) => !already.contains(a.id)).toList();

    if (pending.isEmpty) {
      progress.value = IndexProgress(
          done: 0, total: 0, running: false);
      return;
    }

    progress.value =
        IndexProgress(done: 0, total: pending.length, running: true);

    var done = 0;
    for (var i = 0; i < pending.length; i += _batchSize) {
      if (_cancelled) break;

      final end = math.min(i + _batchSize, pending.length);
      final batch = pending.sublist(i, end);

      // 1) نجمع الصور المصغّرة (نداءات منصّة — لازم بالخيط الرئيسي)
      final jobs = <String, Uint8List>{};
      final byId = <String, AssetEntity>{};
      for (final asset in batch) {
        if (_cancelled) break;
        try {
          final bytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize.square(_thumbSize),
          );
          if (bytes != null) {
            jobs[asset.id] = bytes;
            byId[asset.id] = asset;
          }
        } catch (_) {
          // صورة تالفة — نتجاهلها
        }
      }

      if (jobs.isNotEmpty) {
        // 2) التحليل الثقيل — Isolate واحد للدفعة كاملة
        final results = await compute(analyzeBatch, jobs);

        // 3) الحفظ بمعاملة وحدة (أسرع بكثير من put لكل صف)
        _saveBatch(results);
      }

      done = end;
      progress.value =
          IndexProgress(done: done, total: pending.length, running: true);

      // 4) نترك الواجهة تلتقط أنفاسها بين الدفعات.
      //    بالخلفية منمدّد الاستراحة أكثر حتى ما نزاحم المستخدم.
      await Future<void>.delayed(
        background ? const Duration(milliseconds: 120) : Duration.zero,
      );
    }

    progress.value =
        IndexProgress(done: done, total: pending.length, running: false);
  }

  /// حفظ دفعة النتائج.
  ///
  /// مهم للأداء: استعلام واحد + كتابة واحدة للدفعة كاملة.
  /// كنا نعمل استعلام وكتابة لكل صورة (24 + 24 لكل دفعة)، وكلها
  /// عمليات متزامنة على الخيط الرئيسي — وهذا كان يسبب تقطيع
  /// واضح بالواجهة.
  void _saveBatch(Map<String, List<num>> results) {
    if (results.isEmpty) return;

    final ids = results.keys.toList();

    // استعلام واحد يجيب كل الصفوف الموجودة مسبقًا
    final existing =
        _box.query(MediaAnalysis_.assetId.oneOf(ids)).build().find();
    final byId = {for (final e in existing) e.assetId: e};

    final now = DateTime.now();
    final rows = <MediaAnalysis>[];

    for (final entry in results.entries) {
      final v = entry.value;
      final row = byId[entry.key] ??
          MediaAnalysis(assetId: entry.key, analyzedAt: now);

      row
        ..phash = v[kIdxPhash].toInt()
        ..dominantColor = v[kIdxColor].toInt()
        ..qualityScore = v[kIdxQuality].toDouble()
        ..sharpness = v[kIdxSharpness].toDouble()
        ..brightness = v[kIdxBrightness].toDouble()
        ..analyzedAt = now
        ..isAnalyzed = true;

      rows.add(row);
    }

    // كتابة واحدة للدفعة كاملة
    _box.putMany(rows);
  }

  // ── قراءات جاهزة للواجهات ──────────────────────────────────

  List<MediaAnalysis> allAnalyzed() =>
      _box.query(MediaAnalysis_.isAnalyzed.equals(true)).build().find();

  int get analyzedCount =>
      _box.query(MediaAnalysis_.isAnalyzed.equals(true)).build().count();

  /// يشيل صفوف التحليل لصور ما عادت موجودة على الجهاز.
  /// [liveIds] = معرّفات الصور الموجودة فعليًا الآن.
  int _pruneDeleted(Set<String> liveIds) {
    final dead = _box
        .getAll()
        .where((r) => !liveIds.contains(r.assetId))
        .map((r) => r.id)
        .toList();
    if (dead.isNotEmpty) _box.removeMany(dead);
    return dead.length;
  }

  /// يشيل تحليل صور محدّدة — منستدعيها فور حذف صور من التطبيق
  /// حتى تختفي من النتائج بدون ما نستنى فحص جديد.
  void removeAnalysisFor(List<String> assetIds) {
    if (assetIds.isEmpty) return;
    final rows =
        _box.query(MediaAnalysis_.assetId.oneOf(assetIds)).build().find();
    if (rows.isNotEmpty) {
      _box.removeMany(rows.map((r) => r.id).toList());
    }
  }

  /// إجمالي صور الجهاز — لعرض "X من Y محلّلة".
  Future<int> totalPhotoCount() async {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    if (albums.isEmpty) return 0;
    return albums.first.assetCountAsync;
  }

  /// مجموعات المكرّرات — التجميع O(n²) فمنشغّله بـ Isolate.
  /// يرجع قوائم من assetId، الأفضل جودةً أول واحد بكل مجموعة.
  Future<List<List<String>>> findDuplicateGroups({int threshold = 10}) async {
    final rows = allAnalyzed().where((e) => e.phash != null).toList();
    if (rows.length < 2) return [];

    final items = rows
        .map((e) => [e.assetId, e.phash!, e.qualityScore ?? 0.0])
        .toList();

    return compute(groupDuplicates, {
      'threshold': threshold,
      'items': items,
    });
  }

  /// درجات الجودة مفهرسة بالـ assetId — للعرض السريع.
  Map<String, double> qualityByAssetId() {
    final map = <String, double>{};
    for (final r in allAnalyzed()) {
      if (r.qualityScore != null) map[r.assetId] = r.qualityScore!;
    }
    return map;
  }

  /// الصور الأقرب للون معيّن، مرتّبة من الأقرب.
  List<MediaAnalysis> searchByColor(int targetArgb,
      {double maxDistance = 0.25}) {
    final scored = allAnalyzed()
        .where((e) => e.dominantColor != null)
        .map((e) => (e, colorDistance(targetArgb, e.dominantColor!)))
        .where((t) => t.$2 <= maxDistance)
        .toList()
      ..sort((a, b) => a.$2.compareTo(b.$2));

    return scored.map((t) => t.$1).toList();
  }

  /// أفضل الصور جودةً — لاقتراح صورة شخصية/غلاف.
  List<MediaAnalysis> bestByQuality({int take = 20}) {
    final rows = allAnalyzed().where((e) => e.qualityScore != null).toList()
      ..sort((a, b) => b.qualityScore!.compareTo(a.qualityScore!));
    return rows.take(take).toList();
  }

  /// مرشّحو الصورة الشخصية/الغلاف.
  ///
  /// الترتيب = جودة الصورة + مدى ملاءمة أبعادها للاستخدام:
  ///   • شخصية → تميل للمربّع (1:1)
  ///   • غلاف   → عريضة (16:9)
  ///
  /// بنجيب الأصول الحقيقية عشان نعرف أبعادها الأصلية.
  Future<List<({
    AssetEntity asset,
    double score,
    double quality,
    double fit,
    double faceScore,
    int faceCount,
    bool faceIndexed,
  })>> suggestPhotos({required bool forProfile, int take = 12}) async {
    // Start from a wider pool of already-analyzed photos. For You must stay a
    // cheap read-only feature: it never runs another detector/model here.
    final candidates = bestByQuality(take: take * 4);
    final faceSignals = forProfile
        ? await DatabaseHelper.instance
            .getFaceSuggestionSignals(candidates.map((row) => row.assetId))
        : const <String,
            ({
              int faceCount,
              double bestQuality,
              double bestPose,
              double bestArea,
            })>{};

    final scored = <({
      AssetEntity asset,
      double score,
      double quality,
      double fit,
      double faceScore,
      int faceCount,
      bool faceIndexed,
    })>[];

    for (final row in candidates) {
      final asset = await AssetEntity.fromId(row.assetId);
      if (asset == null || asset.width == 0 || asset.height == 0) continue;

      final fit = aspectFitScore(
        width: asset.width,
        height: asset.height,
        forProfile: forProfile,
      );
      final quality = (row.qualityScore ?? 0).clamp(0.0, 100.0).toDouble();

      // qualityScore was computed from a tiny thumbnail, so its internal
      // resolution term cannot distinguish the original camera resolutions.
      // Add a small real-resolution contribution here using AssetEntity dims.
      final pixels = asset.width * asset.height;
      final resolution = (math.log(1 + pixels) / math.log(1 + 12000000))
          .clamp(0.0, 1.0)
          .toDouble();

      var faceScore = 55.0; // neutral when this photo has not been face-indexed
      var faceCount = 0;
      var faceIndexed = false;
      if (forProfile) {
        final signal = faceSignals[row.assetId];
        if (signal != null) {
          faceIndexed = true;
          faceCount = signal.faceCount;
          if (signal.faceCount <= 0) {
            faceScore = 0;
          } else {
            final areaScore = ((math.sqrt(signal.bestArea.clamp(0.0, 1.0)) -
                            0.08) /
                        0.27)
                    .clamp(0.0, 1.0)
                    .toDouble();
            final baseFace = (signal.bestQuality * 0.70 +
                    signal.bestPose * 0.20 +
                    areaScore * 0.10)
                .clamp(0.0, 1.0)
                .toDouble();
            final crowdPenalty = signal.faceCount == 1
                ? 1.0
                : signal.faceCount == 2
                    ? 0.84
                    : 0.68;
            faceScore = (baseFace * crowdPenalty * 100)
                .clamp(0.0, 100.0)
                .toDouble();
          }
        }
      }

      final score = forProfile
          ? quality * 0.50 +
              fit * 100 * 0.20 +
              resolution * 100 * 0.05 +
              faceScore * 0.25
          : quality * 0.65 + fit * 100 * 0.30 + resolution * 100 * 0.05;

      scored.add((
        asset: asset,
        score: score.clamp(0.0, 100.0).toDouble(),
        quality: quality,
        fit: fit * 100,
        faceScore: faceScore,
        faceCount: faceCount,
        faceIndexed: faceIndexed,
      ));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(take).toList();
  }
}
