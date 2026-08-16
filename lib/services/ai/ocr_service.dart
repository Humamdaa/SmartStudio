import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:tesseract_ocr/ocr_engine_config.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

class OcrExtraction {
  final String text;
  final List<String> scripts;
  final bool arabicAttempted;

  const OcrExtraction({
    required this.text,
    required this.scripts,
    required this.arabicAttempted,
  });

  static const empty = OcrExtraction(
    text: '',
    scripts: [],
    arabicAttempted: false,
  );
}

class OcrService {
  OcrService._();
  static final OcrService instance = OcrService._();

  final _latinRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  Future<void> _ocrTail = Future<void>.value();

  Future<String?> extractText(String imagePath) async {
    final extraction = await extractCombinedText(imagePath);
    return extraction.text.isEmpty ? null : extraction.text;
  }

  Future<OcrExtraction> extractCombinedText(
    String imagePath, {
    bool runArabic = false,
    bool thoroughArabic = false,
  }) {
    final turn = Completer<void>();
    final previous = _ocrTail;
    _ocrTail = turn.future;
    return previous.then((_) async {
      try {
        return await _extractCombinedText(
          imagePath,
          runArabic: runArabic,
          thoroughArabic: thoroughArabic,
        );
      } finally {
        turn.complete();
      }
    });
  }

  Future<OcrExtraction> _extractCombinedText(
    String imagePath, {
    required bool runArabic,
    required bool thoroughArabic,
  }) async {
    final pieces = <String>[];
    final scripts = <String>[];
    var latinBlocks = <TextBlock>[];

    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final result = await _latinRecognizer.processImage(inputImage);
      latinBlocks = result.blocks;
      final value = _cleanLatinText(result.text);
      if (value.isNotEmpty) {
        pieces.add(value);
        scripts.add('latin');
      }
    } catch (error) {
      debugPrint('PixMind Latin OCR error: $error');
    }

    if (runArabic) {
      String? focusedArabicPath;
      try {
        // Mixed Arabic/English screenshots were a weak spot: the Arabic
        // Tesseract pass sometimes tried to reinterpret a clear English line
        // as Arabic glyphs. Re-use the Latin ML Kit blocks we already paid for,
        // hide only strongly-Latin regions on a temporary copy, and run the
        // Arabic model on the remaining pixels. No extra detector/model is
        // loaded and pure-Arabic photos still use the original image.
        focusedArabicPath = await _createArabicFocusedImage(
          imagePath,
          latinBlocks,
        );
        final arabicInput = focusedArabicPath ?? imagePath;
        // Use both the Arabic language model and Tesseract's Arabic-script
        // model. The script model adds broader glyph/word coverage while the
        // language model keeps Arabic-specific vocabulary. We keep a safe
        // fallback to `ara` in case an upgraded install has not copied the new
        // script asset yet.
        var arabic = await _runArabicTesseract(
          arabicInput,
          language: 'ara+Arabic',
          pageMode: PageSegmentationMode.auto,
        );

        // Auto page segmentation can miss a short/decorative sign. Manual
        // "Live Text" requests are allowed one extra pass; background/full
        // indexing keeps the cheaper single-pass behavior unless the result is
        // nearly empty.
        if (thoroughArabic || _arabicCharCount(arabic) < 6) {
          final sparse = await _runArabicTesseract(
            arabicInput,
            language: 'ara+Arabic',
            pageMode: PageSegmentationMode.sparseText,
          );
          if (_arabicCandidateScore(sparse) > _arabicCandidateScore(arabic)) {
            arabic = sparse;
          }
        }

        // On a user-requested extraction also compare the language-specific
        // model alone. This occasionally handles unusual fonts differently
        // from the combined language+script model, without adding cost to
        // background indexing.
        if (thoroughArabic) {
          final languageOnly = await _runArabicTesseract(
            arabicInput,
            language: 'ara',
            pageMode: PageSegmentationMode.auto,
          );
          if (_arabicCandidateScore(languageOnly) >
              _arabicCandidateScore(arabic)) {
            arabic = languageOnly;
          }
        }

        arabic = _cleanArabicText(arabic);
        if (_containsArabic(arabic)) {
          pieces.add(arabic);
          scripts.add('arabic');
        }
      } catch (combinedError) {
        try {
          final arabic = _cleanArabicText(await _runArabicTesseract(
            imagePath,
            language: 'ara',
            pageMode: PageSegmentationMode.auto,
          ));
          if (_containsArabic(arabic)) {
            pieces.add(arabic);
            scripts.add('arabic');
          }
        } catch (fallbackError) {
          // Arabic OCR is an enhancement. A single unsupported/corrupt image
          // must not discard YOLO, metadata, Latin OCR or face results.
          debugPrint(
            'PixMind Arabic OCR error: $combinedError; fallback: $fallbackError',
          );
        }
      } finally {
        if (focusedArabicPath != null) {
          try {
            await File(focusedArabicPath).delete();
          } catch (_) {}
        }
      }
    }

    return OcrExtraction(
      text: _deduplicate(pieces),
      scripts: scripts,
      arabicAttempted: runArabic,
    );
  }

  String _cleanLatinText(String value) {
    final kept = <String>[];
    for (final raw in value.split(RegExp(r'[\r\n]+'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final latin = RegExp(r'[A-Za-z]').allMatches(line).length;
      final arabic = RegExp(r'[\u0600-\u06FF]').allMatches(line).length;
      final digits = RegExp(r'[0-9]').allMatches(line).length;
      // Keep clear Latin/digit content. A Latin recognizer occasionally emits
      // short garbage for Arabic glyphs; requiring actual Latin evidence keeps
      // the combined result cleaner without harming normal English OCR.
      if (latin >= 2 || (digits >= 2 && arabic == 0)) kept.add(line);
    }
    return kept.join('\n');
  }

  String _cleanArabicText(String value) {
    final kept = <String>[];
    for (final raw in value.split(RegExp(r'[\r\n]+'))) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      final arabic = _arabicCharCount(line);
      if (arabic < 2) continue;
      // Collapse the most common OCR spacing noise but keep punctuation and
      // numbers because they matter in receipts, screenshots and dates.
      line = line.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
      kept.add(line);
    }
    return kept.join('\n');
  }

  bool _isStrongLatinBlock(String value) {
    final latin = RegExp(r'[A-Za-z]').allMatches(value).length;
    final arabic = RegExp(r'[\u0600-\u06FF]').allMatches(value).length;
    final letters = latin + arabic;
    if (latin < 3 || letters == 0) return false;
    return latin / letters >= 0.70;
  }

  Future<String?> _createArabicFocusedImage(
    String imagePath,
    List<TextBlock> latinBlocks,
  ) async {
    final blocks = latinBlocks
        .where((block) => _isStrongLatinBlock(block.text))
        .toList(growable: false);
    if (blocks.isEmpty) return null;

    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final image = img.bakeOrientation(decoded);

      var masked = 0;
      for (final block in blocks) {
        final rect = block.boundingBox;
        // If detector coordinates clearly do not match the baked image,
        // prefer the unmodified image over masking the wrong region.
        if (rect.left > image.width * 1.15 ||
            rect.top > image.height * 1.15 ||
            rect.right < 0 ||
            rect.bottom < 0) {
          continue;
        }
        const pad = 5;
        final x1 = (rect.left.floor() - pad).clamp(0, image.width - 1).toInt();
        final y1 = (rect.top.floor() - pad).clamp(0, image.height - 1).toInt();
        final x2 = (rect.right.ceil() + pad).clamp(x1, image.width - 1).toInt();
        final y2 = (rect.bottom.ceil() + pad).clamp(y1, image.height - 1).toInt();
        img.fillRect(
          image,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          color: img.ColorRgb8(255, 255, 255),
        );
        masked++;
      }
      if (masked == 0) return null;

      final path = '${Directory.systemTemp.path}/pixmind_ar_focus_'
          '${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File(path).writeAsBytes(img.encodeJpg(image, quality: 94));
      return path;
    } catch (error) {
      debugPrint('PixMind mixed OCR mask skipped: $error');
      return null;
    }
  }

  Future<List<TextBlock>> extractTextBlocks(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final result = await _latinRecognizer.processImage(inputImage);
      return result.blocks;
    } catch (_) {
      return [];
    }
  }

  bool shouldRunArabic({
    required String? title,
    required List<String> scenes,
  }) {
    final source = '${title ?? ''} ${scenes.join(' ')}'.toLowerCase();
    const textHints = [
      'screenshot',
      'screen',
      'document',
      'paper',
      'receipt',
      'invoice',
      'book',
      'poster',
      'menu',
      'sign',
      'text',
      'writing',
      'ocr',
    ];
    return textHints.any(source.contains);
  }

  Future<String> _runArabicTesseract(
    String imagePath, {
    required String language,
    required String pageMode,
  }) async {
    return (await TesseractOcr.extractText(
      imagePath,
      config: OCRConfig(
        language: language,
        engine: OCREngine.tesseract,
        options: {
          TesseractConfig.pageSegMode: pageMode,
          TesseractConfig.preserveInterwordSpaces: '1',
        },
      ),
    ))
        .trim();
  }

  int _arabicCharCount(String value) =>
      RegExp(r'[\u0621-\u064A]').allMatches(value).length;

  double _arabicCandidateScore(String value) {
    if (value.trim().isEmpty) return 0;
    final arabic = _arabicCharCount(value);
    final words = value
        .split(RegExp(r'\s+'))
        .where((word) => word.trim().isNotEmpty)
        .length;
    final noise = RegExp(r'[^\u0600-\u06FFa-zA-Z0-9\s.,:;!?%+\-/]')
        .allMatches(value)
        .length;
    return arabic * 2.0 + words * 1.2 - noise * 0.8;
  }

  bool _containsArabic(String value) =>
      RegExp(r'[\u0600-\u06FF]').hasMatch(value);

  String _deduplicate(List<String> values) {
    final lines = <String>[];
    final seen = <String>{};
    for (final value in values) {
      for (final rawLine in value.split(RegExp(r'[\r\n]+'))) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        final key = line.toLowerCase();
        if (seen.add(key)) lines.add(line);
      }
    }
    return lines.join('\n');
  }

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
    final positive = positiveWords.where(lower.contains).length;
    final negative = negativeWords.where(lower.contains).length;
    if (positive > negative) return 'positive';
    if (negative > positive) return 'negative';
    return 'neutral';
  }

  void dispose() => _latinRecognizer.close();
}
