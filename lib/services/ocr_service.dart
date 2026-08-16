// ⚠️ معطّل مؤقتاً — مكتبة google_mlkit_text_recognition مشالة من pubspec لتسريع البناء.
// هاي الخدمة مش مستخدمة بأي شاشة حالياً. لإعادة التفعيل:
//   1) شيل التعليق عن السطر بـ pubspec.yaml   2) احذف /* و */ تحت   3) flutter pub get
/*
import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class OcrService {
  OcrService._();
  static final OcrService instance = OcrService._();

  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final _recognizerArabic = TextRecognizer(script: TextRecognitionScript.latin);

  Future<String?> extractText(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final result = await _recognizer.processImage(inputImage);
      return result.text.isNotEmpty ? result.text : null;
    } catch (e) {
      return null;
    }
  }

  Future<List<TextBlock>> extractTextBlocks(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final result = await _recognizer.processImage(inputImage);
      return result.blocks;
    } catch (e) {
      return [];
    }
  }

  // تحليل مشاعر بسيط بناء على قاموس كلمات
  String analyzeSentiment(String text) {
    final lower = text.toLowerCase();

    const positiveWords = [
      'happy', 'love', 'great', 'amazing', 'wonderful', 'excellent',
      'سعيد', 'جميل', 'رائع', 'ممتاز', 'محبة', 'حب', 'بديع',
    ];
    const negativeWords = [
      'sad', 'hate', 'terrible', 'awful', 'bad', 'worst',
      'حزين', 'كره', 'سيء', 'فظيع', 'رديء', 'مريع',
    ];

    int positiveScore = 0;
    int negativeScore = 0;

    for (final word in positiveWords) {
      if (lower.contains(word)) positiveScore++;
    }
    for (final word in negativeWords) {
      if (lower.contains(word)) negativeScore++;
    }

    if (positiveScore > negativeScore) return 'positive';
    if (negativeScore > positiveScore) return 'negative';
    return 'neutral';
  }

  void dispose() {
    _recognizer.close();
    _recognizerArabic.close();
  }
}
*/
