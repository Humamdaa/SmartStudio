abstract final class VisualSearchConfig {
  static const String imageEncoderAsset =
      'assets/models/visual_search/EfficientNetB0_quant.tflite';

  static const String imageProjectionAsset =
      'assets/models/visual_search/image_projection.tflite';

  static const int inputWidth = 224;
  static const int inputHeight = 224;
  static const int inputChannels = 3;
  static const int encoderEmbeddingDimension = 1280;

  static const String modelVersion = 'efficientnetb0-image-projection-v1';

  static const int encoderThreads = 2;
  static const int projectionThreads = 1;

  const VisualSearchConfig._();
}
