import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

// ═══════════════════════════════════════════════════════════════
// تحليل الصور — المرحلة الأولى: بدون أي نموذج ذكاء اصطناعي.
//
// كل الحسابات هون رياضية بحتة وتشتغل offline بالكامل:
//   • pHash    → بصمة إدراكية لكشف المكرّر
//   • اللون    → اللون السائد للبحث باللون
//   • الجودة   → حدّة + إضاءة لاقتراح صورة شخصية/غلاف
//
// الدوال هون نقية (pure) وما بتلمس Flutter، عشان نقدر
// نشغّلها بـ Isolate منفصل فما تجمّد الواجهة.
// ═══════════════════════════════════════════════════════════════

/// نتيجة تحليل صورة واحدة.
class ImageAnalysis {
  final int phash;
  final int dominantColor; // ARGB
  final double qualityScore; // 0..100
  final double sharpness;
  final double brightness; // 0..1

  const ImageAnalysis({
    required this.phash,
    required this.dominantColor,
    required this.qualityScore,
    required this.sharpness,
    required this.brightness,
  });
}

// ═══════════════════════════════════════════════════════════════
// نقاط الدخول للـ Isolate
//
// مهم للأداء: منحلّل **دفعة كاملة** بنداء Isolate واحد بدل
// نداء لكل صورة. إنشاء Isolate مكلف (~10-50 ملّي ثانية)، فلو
// عملناه لكل صورة بتصير التكلفة أكبر من التحليل نفسه.
// ═══════════════════════════════════════════════════════════════

/// مفاتيح نتيجة التحليل بالترتيب داخل القائمة المُعادة.
const kIdxPhash = 0;
const kIdxColor = 1;
const kIdxQuality = 2;
const kIdxSharpness = 3;
const kIdxBrightness = 4;

/// يحلّل دفعة صور دفعة وحدة داخل Isolate واحد.
///
/// المدخل : assetId → بايتات الصورة المصغّرة
/// المخرج : assetId → [phash, color, quality, sharpness, brightness]
///
/// منستخدم أنواع بسيطة (Map/List/num) لأنها مضمونة النقل بين
/// الـ Isolates بدون مشاكل تسلسل.
Map<String, List<num>> analyzeBatch(Map<String, Uint8List> jobs) {
  final out = <String, List<num>>{};
  for (final entry in jobs.entries) {
    final a = analyzeImageBytes(entry.value);
    if (a == null) continue;
    out[entry.key] = [
      a.phash,
      a.dominantColor,
      a.qualityScore,
      a.sharpness,
      a.brightness,
    ];
  }
  return out;
}

/// بايتات صورة مصغّرة → تحليل كامل.
ImageAnalysis? analyzeImageBytes(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final gray32 = _toGrayscaleMatrix(decoded, 32);
  final phash = computePHash(gray32);
  final sharp = computeSharpness(gray32);
  final bright = computeBrightness(gray32);
  final blur = computeBlurRatio(gray32);

  return ImageAnalysis(
    phash: phash,
    dominantColor: computeDominantColor(decoded),
    sharpness: sharp,
    brightness: bright,
    qualityScore: computeQualityScore(
      sharpness: sharp,
      brightness: bright,
      blurRatio: blur,
      width: decoded.width,
      height: decoded.height,
    ),
  );
}

/// نسبة المناطق المموّهة بالصورة (0 = كلها واضحة · 1 = كلها مموّهة).
///
/// ليش منحتاجها: الحدّة العامة بتعطي رقم واحد للصورة كاملة، فصورة
/// فيها جزء مموّه متعمّد (إخفاء وجه مثلًا) بتضل تبان "حادّة" لأن
/// باقي الصورة واضح. هون منقسّم الصورة لمربّعات ومنشوف كم مربّع
/// منها ضعيف التفاصيل — هيك منكشف التمويه الموضعي.
double computeBlurRatio(List<List<double>> gray, {int blocks = 4}) {
  final n = gray.length;
  final step = n ~/ blocks;
  if (step < 3) return 0;

  var blurred = 0;
  var counted = 0;

  for (var by = 0; by < blocks; by++) {
    for (var bx = 0; bx < blocks; bx++) {
      // تباين لابلاسي داخل هذا المربّع فقط
      final values = <double>[];
      for (var y = by * step + 1; y < (by + 1) * step - 1; y++) {
        for (var x = bx * step + 1; x < (bx + 1) * step - 1; x++) {
          values.add(
            4 * gray[y][x] -
                gray[y - 1][x] -
                gray[y + 1][x] -
                gray[y][x - 1] -
                gray[y][x + 1],
          );
        }
      }
      if (values.isEmpty) continue;

      final mean = values.reduce((a, b) => a + b) / values.length;
      final variance =
          values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
          values.length;

      counted++;
      // عتبة منخفضة = المربّع شبه خالي من الحواف → مموّه
      if (variance < 60) blurred++;
    }
  }

  return counted == 0 ? 0 : blurred / counted;
}

// ═══════════════════════════════════════════════════════════════
// 1) pHash — بصمة إدراكية 64-bit
//
// الفكرة: نصغّر الصورة ونحوّلها لتدرّج رمادي، بعدين نطبّق DCT
// (تحويل جيب التمام المتقطّع) — نفس الفكرة المستخدمة بضغط JPEG.
// الزاوية العلوية اليسرى من مصفوفة DCT بتحمل "الشكل العام"
// للصورة وبتتجاهل التفاصيل الدقيقة.
//
// بعدين منقارن كل معامل بالوسيط: أكبر = 1، أصغر = 0 → 64 بت.
//
// النتيجة: صورتين متشابهتين بصريًا (حتى لو اختلف الحجم أو
// الضغط أو السطوع قليلًا) بيطلع إلهم بصمة متقاربة جدًا.
// ═══════════════════════════════════════════════════════════════
int computePHash(List<List<double>> gray32) {
  final dct = _dct2d(gray32);

  // ناخد أول 8×8 معامل (الترددات المنخفضة = الشكل العام)
  final coeffs = <double>[];
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      coeffs.add(dct[y][x]);
    }
  }

  // نتجاهل أول معامل (DC) لأنه متوسط السطوع — مش مميّز للشكل
  final withoutDc = coeffs.sublist(1);
  final sorted = List<double>.from(withoutDc)..sort();
  final median = sorted[sorted.length ~/ 2];

  var hash = 0;
  for (var i = 0; i < 64; i++) {
    if (coeffs[i] > median) {
      hash |= (1 << i);
    }
  }
  return hash;
}

/// عدد البتّات المختلفة بين بصمتين (مسافة هامينغ).
/// 0 = متطابقتان · أقل من ~10 = متشابهتان جدًا
///
/// ⚠️ لازم إزاحة **بدون إشارة** (>>>) مش (>>).
/// أعداد Dart صحيحة 64-bit بإشارة، والبت رقم 63 من البصمة
/// بيخلّي القيمة سالبة. الإزاحة العادية (>>) بتحافظ على بت
/// الإشارة، فالحلقة ما بتوصل صفر أبدًا = تعليق لا نهائي.
int hammingDistance(int a, int b) {
  var x = a ^ b;
  var count = 0;
  while (x != 0) {
    count += x & 1;
    x >>>= 1;
  }
  return count;
}

/// هل الصورتان تُعتبران مكرّرتين؟
/// [threshold] أصغر = تطابق أدق.
bool areDuplicates(int hashA, int hashB, {int threshold = 10}) =>
    hammingDistance(hashA, hashB) <= threshold;

/// تجميع المكرّرات — يشتغل بـ Isolate لأنه O(n²):
/// 500 صورة = 125 ألف مقارنة، وهذا بيجمّد الواجهة لو صار
/// على الخيط الرئيسي.
///
/// المدخل : {'threshold': int, 'items': [[assetId, phash, quality], ...]}
/// المخرج : قوائم من assetId، كل قائمة مجموعة مكرّرات
///          مرتّبة بحيث الأفضل جودةً أولًا.
List<List<String>> groupDuplicates(Map<String, dynamic> input) {
  final threshold = input['threshold'] as int;
  final items = (input['items'] as List).cast<List>();
  final n = items.length;
  if (n < 2) return [];

  final hashes = List<int>.generate(n, (i) => items[i][1] as int);

  // ── تقسيم نطاقات (banded LSH) بدل مقارنة الكل بالكل ──────────
  //
  // المسح التربيعي القديم كان يقارن كل صورة بكل ما بعدها: مع 85 ألف صورة
  // يعني 3.6 مليار مقارنة — لا ينتهي عمليًا.
  //
  // نقسم البصمة 64-بت إلى (threshold + 1) نطاقًا متجاورًا. أي بصمتين
  // تختلفان بـ threshold بت أو أقل لا بد أن تتطابقا تمامًا في نطاق واحد
  // على الأقل (مبدأ الحمام: البتات المختلفة أقل من عدد النطاقات، فلا
  // يمكن أن تلمس كل النطاقات). فمسح رفقاء النطاق فقط يجد **نفس** الأزواج
  // التي كان يجدها المسح الكامل، بلا أي خسارة في النتائج.
  final bandCount = (threshold + 1).clamp(1, 64);
  final bandStarts = <int>[];
  final bandMasks = <int>[];
  var bit = 0;
  for (var b = 0; b < bandCount; b++) {
    final width = (64 - bit) ~/ (bandCount - b);
    bandStarts.add(bit);
    bandMasks.add(width >= 64 ? -1 : (1 << width) - 1);
    bit += width;
  }

  final buckets = List.generate(bandCount, (_) => <int, List<int>>{});
  for (var i = 0; i < n; i++) {
    final h = hashes[i];
    for (var b = 0; b < bandCount; b++) {
      final key = (h >> bandStarts[b]) & bandMasks[b];
      buckets[b].putIfAbsent(key, () => <int>[]).add(i);
    }
  }

  final groups = <List<String>>[];
  final used = List<bool>.filled(n, false);

  for (var i = 0; i < n; i++) {
    if (used[i]) continue;
    final hashI = hashes[i];

    final members = <int>[i];
    used[i] = true;

    final seen = <int>{};
    for (var b = 0; b < bandCount; b++) {
      final mates = buckets[b][(hashI >> bandStarts[b]) & bandMasks[b]];
      if (mates == null) continue;
      for (final j in mates) {
        if (j <= i || used[j] || !seen.add(j)) continue;
        if (areDuplicates(hashI, hashes[j], threshold: threshold)) {
          members.add(j);
          used[j] = true;
        }
      }
    }

    if (members.length > 1) {
      // الأعلى جودة أولًا — هي المرشّحة للاحتفاظ
      members.sort(
        (a, b) => (items[b][2] as num).compareTo(items[a][2] as num),
      );
      groups.add(members.map((k) => items[k][0] as String).toList());
    }
  }

  groups.sort((a, b) => b.length.compareTo(a.length));
  return groups;
}

// ═══════════════════════════════════════════════════════════════
// 2) اللون السائد
//
// منقسّم فضاء RGB لـ 4×4×4 = 64 صندوق، منعدّ بكسلات كل صندوق،
// وناخد متوسط لون الصندوق الأكثر تكرارًا.
//
// منتجاهل البكسلات شبه البيضاء وشبه السوداء لأنها عادة خلفية
// أو ظل — مش "لون الصورة" اللي بيدور عليه المستخدم.
// ═══════════════════════════════════════════════════════════════
int computeDominantColor(img.Image src) {
  final small = img.copyResize(src, width: 48, height: 48);

  final counts = List<int>.filled(64, 0);
  final sumR = List<int>.filled(64, 0);
  final sumG = List<int>.filled(64, 0);
  final sumB = List<int>.filled(64, 0);

  for (var y = 0; y < small.height; y++) {
    for (var x = 0; x < small.width; x++) {
      final p = small.getPixel(x, y);
      final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();

      final maxC = math.max(r, math.max(g, b));
      final minC = math.min(r, math.min(g, b));
      // نتجاهل شبه الأبيض/الأسود/الرمادي الباهت
      if (maxC < 28 || minC > 232) continue;

      final bucket = (r >> 6) * 16 + (g >> 6) * 4 + (b >> 6);
      counts[bucket]++;
      sumR[bucket] += r;
      sumG[bucket] += g;
      sumB[bucket] += b;
    }
  }

  var best = 0;
  for (var i = 1; i < 64; i++) {
    if (counts[i] > counts[best]) best = i;
  }
  if (counts[best] == 0) return 0xFF808080; // صورة رمادية بالكامل

  final n = counts[best];
  return _argb(sumR[best] ~/ n, sumG[best] ~/ n, sumB[best] ~/ n);
}

/// مدى تقارب لونين (0 = مطابق تمامًا · 1 = أقصى اختلاف).
/// منقارن بفضاء HSV لأنه أقرب لإدراك العين البشرية من RGB:
/// الأحمر الفاتح والأحمر الغامق "نفس اللون" عند المستخدم.
double colorDistance(int argbA, int argbB) {
  final a = _toHsv(argbA);
  final b = _toHsv(argbB);

  // فرق درجة اللون دائري (0 و 360 نفس الشي)
  var dh = (a[0] - b[0]).abs();
  if (dh > 180) dh = 360 - dh;

  final hueDiff = dh / 180.0;
  final satDiff = (a[1] - b[1]).abs();
  final valDiff = (a[2] - b[2]).abs();

  // الوزن الأكبر لدرجة اللون لأنها الأهم بصريًا
  return (hueDiff * 0.6 + satDiff * 0.25 + valDiff * 0.15).clamp(0.0, 1.0);
}

// ═══════════════════════════════════════════════════════════════
// 3) الجودة — حدّة + إضاءة
//
// الحدّة: تباين مُرشِّح لابلاسي. المُرشِّح بيبرز الحواف، فصورة
// حادّة = حواف قوية = تباين عالي، وصورة ضبابية = تباين منخفض.
//
// الإضاءة: أفضل نتيجة عند متوسط 0.5 — لا مظلمة ولا محروقة.
// ═══════════════════════════════════════════════════════════════
double computeSharpness(List<List<double>> gray) {
  final h = gray.length, w = gray[0].length;
  final values = <double>[];

  // نواة لابلاسي: مركز 4 وجيرانه -1
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final lap =
          4 * gray[y][x] -
          gray[y - 1][x] -
          gray[y + 1][x] -
          gray[y][x - 1] -
          gray[y][x + 1];
      values.add(lap);
    }
  }
  if (values.isEmpty) return 0;

  final mean = values.reduce((a, b) => a + b) / values.length;
  final variance =
      values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
      values.length;
  return variance;
}

double computeBrightness(List<List<double>> gray) {
  var sum = 0.0;
  var n = 0;
  for (final row in gray) {
    for (final v in row) {
      sum += v;
      n++;
    }
  }
  return n == 0 ? 0 : (sum / n) / 255.0;
}

/// دمج المؤشرات بدرجة واحدة 0..100.
double computeQualityScore({
  required double sharpness,
  required double brightness,
  required int width,
  required int height,
  double blurRatio = 0,
}) {
  // الحدّة: تطبيع لوغاريتمي لأن مدى التباين واسع جدًا
  final sharpNorm = (math.log(1 + sharpness) / math.log(1 + 2000)).clamp(
    0.0,
    1.0,
  );

  // الإضاءة: أفضل شي 0.5، وكل ما بعدنا عنها تنزل الدرجة
  final brightScore = (1 - (brightness - 0.5).abs() * 2).clamp(0.0, 1.0);

  // الدقّة: صورة أكبر عادة أفضل — بس بتأثير بسيط
  final pixels = width * height;
  final resNorm = (math.log(1 + pixels) / math.log(1 + 12000000)).clamp(
    0.0,
    1.0,
  );

  final base = sharpNorm * 0.55 + brightScore * 0.30 + resNorm * 0.15;

  // خصم التمويه: صورة نصّها مموّه تنزل درجتها للنصف تقريبًا.
  // هيك ما تنختار كـ"أفضل" لمجرد إن باقيها حادّ.
  final penalty = 1 - (blurRatio * 0.8).clamp(0.0, 0.8);

  return (base * penalty * 100).clamp(0.0, 100.0);
}

/// ملاءمة الصورة لتكون صورة شخصية (تميل للمربّع) أو غلاف (عريضة).
double aspectFitScore({
  required int width,
  required int height,
  required bool forProfile,
}) {
  if (width <= 0 || height <= 0) return 0;
  final ratio = width / height;
  final target = forProfile ? 1.0 : 16 / 9;
  final diff = (ratio - target).abs() / target;
  return (1 - diff).clamp(0.0, 1.0);
}

// ═══════════════════════════════════════════════════════════════
// أدوات داخلية
// ═══════════════════════════════════════════════════════════════

/// تصغير + تحويل لتدرّج رمادي كمصفوفة [size]×[size].
List<List<double>> _toGrayscaleMatrix(img.Image src, int size) {
  final small = img.copyResize(src, width: size, height: size);
  return List.generate(size, (y) {
    return List.generate(size, (x) {
      final p = small.getPixel(x, y);
      // أوزان الإضاءة القياسية (العين أحسّ للأخضر)
      return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    });
  });
}

/// DCT ثنائي الأبعاد — منطبّقه على الصفوف بعدين على الأعمدة.
List<List<double>> _dct2d(List<List<double>> input) {
  final n = input.length;

  // نحضّر جدول معاملات جيب التمام مرة وحدة (أسرع بكثير)
  final cosTable = List.generate(
    n,
    (u) =>
        List.generate(n, (x) => math.cos((2 * x + 1) * u * math.pi / (2 * n))),
  );

  double alpha(int u) => u == 0 ? math.sqrt(1 / n) : math.sqrt(2 / n);

  // على الصفوف
  final rows = List.generate(n, (y) {
    return List.generate(n, (u) {
      var sum = 0.0;
      for (var x = 0; x < n; x++) {
        sum += input[y][x] * cosTable[u][x];
      }
      return alpha(u) * sum;
    });
  });

  // على الأعمدة
  return List.generate(n, (v) {
    return List.generate(n, (u) {
      var sum = 0.0;
      for (var y = 0; y < n; y++) {
        sum += rows[y][u] * cosTable[v][y];
      }
      return alpha(v) * sum;
    });
  });
}

int _argb(int r, int g, int b) => 0xFF000000 | (r << 16) | (g << 8) | b;

/// ARGB → [hue 0..360, sat 0..1, val 0..1]
List<double> _toHsv(int argb) {
  final r = ((argb >> 16) & 0xFF) / 255.0;
  final g = ((argb >> 8) & 0xFF) / 255.0;
  final b = (argb & 0xFF) / 255.0;

  final maxC = math.max(r, math.max(g, b));
  final minC = math.min(r, math.min(g, b));
  final delta = maxC - minC;

  var hue = 0.0;
  if (delta > 0.00001) {
    if (maxC == r) {
      hue = 60 * (((g - b) / delta) % 6);
    } else if (maxC == g) {
      hue = 60 * (((b - r) / delta) + 2);
    } else {
      hue = 60 * (((r - g) / delta) + 4);
    }
  }
  if (hue < 0) hue += 360;

  final sat = maxC == 0 ? 0.0 : delta / maxC;
  return [hue, sat, maxC];
}
