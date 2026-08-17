import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class ObjectDetectionService {
  ObjectDetectionService._();
  static final ObjectDetectionService instance = ObjectDetectionService._();

  YOLO? _model;
  bool _loading = false;
  bool _ready = false;
  String? lastError;

  bool get isReady => _ready;

  Future<bool> initialize() async {
    if (_ready) return true;
    while (_loading) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_ready) return true;

    _loading = true;
    lastError = null;
    try {
      _model ??= YOLO(
        modelPath: 'assets/models/yolo11n_int8.tflite',
        task: YOLOTask.detect,
        useGpu: true,
        numItemsThreshold: 25,
      );
      _ready = await _model!.loadModel();
      if (!_ready) {
        lastError = 'تعذر تحميل YOLO11n';
      }
    } catch (error) {
      _ready = false;
      lastError = error.toString();
      debugPrint('PixMind YOLO load error: $error');
    } finally {
      _loading = false;
    }
    return _ready;
  }

  Future<List<String>> detect(Uint8List imageBytes) async {
    if (!await initialize()) return const [];

    try {
      final result = await _model!.predict(
        imageBytes,
        confidenceThreshold: 0.28,
        iouThreshold: 0.65,
      );
      final rawBoxes = result['boxes'];
      if (rawBoxes is! List) return const [];

      final confidenceByLabel = <String, double>{};
      for (final raw in rawBoxes) {
        if (raw is! Map) continue;
        final box = raw.map((key, value) => MapEntry(key.toString(), value));
        final label = (box['class'] ?? box['className'] ?? box['label'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        if (label.isEmpty) continue;

        final rawConfidence = box['confidence'];
        final confidence = rawConfidence is num
            ? rawConfidence.toDouble()
            : double.tryParse(rawConfidence?.toString() ?? '') ?? 0;
        final previous = confidenceByLabel[label] ?? 0;
        if (confidence > previous) confidenceByLabel[label] = confidence;
      }

      final sorted = confidenceByLabel.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return sorted.map((entry) => entry.key).toList(growable: false);
    } catch (error) {
      lastError = error.toString();
      debugPrint('PixMind YOLO inference error: $error');
      return const [];
    }
  }
}
