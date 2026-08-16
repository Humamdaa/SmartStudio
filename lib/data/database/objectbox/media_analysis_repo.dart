import 'dart:convert';
import 'dart:typed_data';
import 'package:objectbox/objectbox.dart';
import '../../../objectbox.g.dart';
import 'entities.dart';
import 'objectbox_store.dart';

// ═══════════════════════════════════════════════════════════════
// MediaAnalysisRepo — كل العمليات على جدول MediaAnalysis
//
// هاد الـ repo فيه ثلاثة أنواع من العمليات:
//
// 1. CRUD عادي: حفظ/جلب/حذف تحليل صورة معينة
//
// 2. Vector search: إيجاد صور مشابهة بالـ embedding
//    هاد هو السبب الرئيسي لاختيار ObjectBox
//
// 3. Batch queries: جلب صور غير محللة بعد
//    عشان نشغّل الـ AI عليها بالخلفية
// ═══════════════════════════════════════════════════════════════
class MediaAnalysisRepo {
  final ObjectBoxStore _store;

  MediaAnalysisRepo(this._store);

  Box<MediaAnalysis> get _box => _store.analysisBox;

  // ─────────────────────────────────────────
  // حفظ أو تحديث تحليل صورة
  // put() = insert إذا id=0، update إذا id موجود
  // ─────────────────────────────────────────
  Future<void> saveAnalysis(MediaAnalysis analysis) async {
    _box.put(analysis);
  }

  // ─────────────────────────────────────────
  // جلب تحليل صورة بالـ assetId
  //
  // query() = بناء استعلام
  // MediaAnalysis_.assetId.equals(id) = شرط WHERE
  // .findFirst() = أول نتيجة فقط
  // ─────────────────────────────────────────
  MediaAnalysis? getByAssetId(String assetId) {
    return _box
        .query(MediaAnalysis_.assetId.equals(assetId))
        .build()
        .findFirst();
  }

  // ─────────────────────────────────────────
  // Vector Semantic Search
  //
  // هاد الميثود هو سبب وجود ObjectBox
  //
  // queryVector = ابحث عن أقرب vectors لـ queryEmbedding
  // limit: 20   = أرجع أقرب 20 صورة
  //
  // ObjectBox يستخدم HNSW داخلياً:
  // بدلاً من مقارنة queryEmbedding بكل صورة (O(n))
  // يتنقل خلال شبكة من الـ nodes للوصول للأقرب (O(log n))
  // مع 24 ألف صورة = الفرق ضخم جداً
  // ─────────────────────────────────────────
  // Vector Semantic Search — يقبل List<double> ويحوله داخلياً
  List<MediaAnalysis> findSimilar(
    List<double> queryEmbedding, {
    int limit = 20,
  }) {
    // ObjectBox 5.x يحتاج Float32List للـ vector search
    final f32 = Float32List.fromList(queryEmbedding);
    return _box
        .query(
          MediaAnalysis_.embedding.nearestNeighborsF32(f32, limit),
        )
        .build()
        .find();
  }

  // ─────────────────────────────────────────
  // جلب الصور اللي لم تُحلَّل بعد
  // مفيد لتشغيل الـ AI بالخلفية على دفعات
  // ─────────────────────────────────────────
  List<MediaAnalysis> getUnanalyzed({int limit = 50}) {
    return _box
        .query(MediaAnalysis_.isAnalyzed.equals(false))
        .build()
        .find()
        .take(limit)
        .toList();
  }

  // ─────────────────────────────────────────
  // هل تم تحليل هاد الـ asset؟
  // ─────────────────────────────────────────
  bool isAnalyzed(String assetId) {
    return getByAssetId(assetId)?.isAnalyzed ?? false;
  }

  // ─────────────────────────────────────────
  // تسجيل asset جديد (قبل التحليل)
  // نسجله أولاً عشان ما نحلله مرتين
  // ─────────────────────────────────────────
  void registerAsset(String assetId) {
    final existing = getByAssetId(assetId);
    if (existing != null) return; // مسجل مسبقاً

    _box.put(MediaAnalysis(
      assetId: assetId,
      analyzedAt: DateTime.now(),
      isAnalyzed: false,
    ));
  }

  // ─────────────────────────────────────────
  // تخزين نتيجة OCR والـ labels
  // ─────────────────────────────────────────
  void saveOcrResult(String assetId, {
    String? text,
    String? sentiment,
    List<String>? labels,
  }) {
    final item = getByAssetId(assetId) ??
        MediaAnalysis(assetId: assetId, analyzedAt: DateTime.now());

    item.extractedText = text;
    item.sentiment = sentiment;
    item.labelsJson = labels != null ? jsonEncode(labels) : null;
    item.analyzedAt = DateTime.now();
    _box.put(item);
  }

  // ─────────────────────────────────────────
  // تخزين الـ embedding — يقبل List<double> ويحوله لـ Float32List
  void saveEmbedding(String assetId, List<double> embedding) {
    final item = getByAssetId(assetId) ??
        MediaAnalysis(assetId: assetId, analyzedAt: DateTime.now());

    item.embedding = Float32List.fromList(embedding);
    item.isAnalyzed = true;
    item.analyzedAt = DateTime.now();
    _box.put(item);
  }

  // labels كـ List<String> (يفك JSON)
  List<String> getLabels(String assetId) {
    final json = getByAssetId(assetId)?.labelsJson;
    if (json == null) return [];
    return List<String>.from(jsonDecode(json));
  }

  int get totalAnalyzed =>
      _box.query(MediaAnalysis_.isAnalyzed.equals(true)).build().count();
}
