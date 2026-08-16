import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

class SceneLabelService {
  SceneLabelService._();
  static final SceneLabelService instance = SceneLabelService._();

  final ImageLabeler _labeler = ImageLabeler(
    options: ImageLabelerOptions(confidenceThreshold: 0.55),
  );

  Future<List<String>> labelImage(String imagePath) async {
    try {
      final input = InputImage.fromFilePath(imagePath);
      final labels = await _labeler.processImage(input);
      final unique = <String>{};
      for (final label in labels) {
        final value = label.label.trim().toLowerCase();
        if (value.isNotEmpty) unique.add(value);
      }
      return unique.take(12).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}
