// import 'dart:io';
// import 'dart:typed_data';
// import 'package:image/image.dart' as img;
//
// class ImageQualityService {
//   ImageQualityService._();
//   static final ImageQualityService instance = ImageQualityService._();
//
//   /// يرجع نسبة مئوية من 0 إلى 100
//   Future<double> analyzeQuality(String imagePath) async {
//     try {
//       final bytes = await File(imagePath).readAsBytes();
//       final image = img.decodeImage(bytes);
//       if (image == null) return 0;
//
//       final sharpness   = _calcSharpness(image);
//       final brightness  = _calcBrightness(image);
//       final aspectScore = _calcAspectScore(image);
//
//       // وزن: sharpness 50%، brightness 30%، aspect 20%
//       return (sharpness * 0.5 + brightness * 0.3 + aspectScore * 0.2)
//           .clamp(0, 100);
//     } catch (_) {
//       return 0;
//     }
//   }
//
//   double _calcSharpness(img.Image image) {
//     // Laplacian variance — كلما ارتفع، كلما كانت الصورة أوضح
//     final gray = img.grayscale(image);
//     double variance = 0;
//     double mean = 0;
//     int count = 0;
//
//     for (int y = 1; y < gray.height - 1; y++) {
//       for (int x = 1; x < gray.width - 1; x++) {
//         final center  = img.getLuminance(gray.getPixel(x, y));
//         final top     = img.getLuminance(gray.getPixel(x, y - 1));
//         final bottom  = img.getLuminance(gray.getPixel(x, y + 1));
//         final left    = img.getLuminance(gray.getPixel(x - 1, y));
//         final right   = img.getLuminance(gray.getPixel(x + 1, y));
//         final lap = (4 * center - top - bottom - left - right).abs();
//         mean += lap;
//         count++;
//       }
//     }
//     if (count == 0) return 0;
//     mean /= count;
//
//     // normalize إلى 0-100
//     return (mean / 50 * 100).clamp(0, 100);
//   }
//
//   double _calcBrightness(img.Image image) {
//     double total = 0;
//     int count = 0;
//     // sample كل 4 بكسل للأداء
//     for (int y = 0; y < image.height; y += 4) {
//       for (int x = 0; x < image.width; x += 4) {
//         total += img.getLuminanceNormalized(image.getPixel(x, y));
//         count++;
//       }
//     }
//     if (count == 0) return 0;
//     final avg = total / count;
//     // أفضل brightness بين 0.3 و 0.7
//     final score = 1 - (2 * (avg - 0.5)).abs() * 2;
//     return (score * 100).clamp(0, 100);
//   }
//
//   double _calcAspectScore(img.Image image) {
//     final ratio = image.width / image.height;
//     // أفضل نسب: 1:1 (100%)، 4:3 (90%)، 16:9 (80%)
//     if ((ratio - 1.0).abs() < 0.1) return 100;
//     if ((ratio - 4 / 3).abs() < 0.1) return 90;
//     if ((ratio - 16 / 9).abs() < 0.1) return 80;
//     if ((ratio - 9 / 16).abs() < 0.1) return 75;
//     return 60;
//   }
//
//   // pHash للكشف عن الصور المكررة
//   Future<String?> computePhash(String imagePath) async {
//     try {
//       final bytes = await File(imagePath).readAsBytes();
//       final image = img.decodeImage(bytes);
//       if (image == null) return null;
//
//       final small = img.copyResize(image, width: 8, height: 8);
//       final gray  = img.grayscale(small);
//
//       double mean = 0;
//       final pixels = <double>[];
//       for (int y = 0; y < 8; y++) {
//         for (int x = 0; x < 8; x++) {
//           final l = img.getLuminanceNormalized(gray.getPixel(x, y));
//           pixels.add(l);
//           mean += l;
//         }
//       }
//       mean /= 64;
//
//       return pixels.map((p) => p > mean ? '1' : '0').join();
//     } catch (_) {
//       return null;
//     }
//   }
//
//   int hammingDistance(String hash1, String hash2) {
//     if (hash1.length != hash2.length) return 64;
//     int dist = 0;
//     for (int i = 0; i < hash1.length; i++) {
//       if (hash1[i] != hash2[i]) dist++;
//     }
//     return dist;
//   }
//
//   bool areDuplicates(String hash1, String hash2, {int threshold = 6}) {
//     return hammingDistance(hash1, hash2) <= threshold;
//   }
// }
