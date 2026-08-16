import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'visual_search_config.dart';

final class VisualEmbeddingService {
  Interpreter? _imageEncoder;
  Interpreter? _imageProjection;

  Future<void> initialize() async {
    if (_imageEncoder != null && _imageProjection != null) {
      return;
    }

    final encoderOptions = InterpreterOptions()
      ..threads = VisualSearchConfig.encoderThreads;
    final projectionOptions = InterpreterOptions()
      ..threads = VisualSearchConfig.projectionThreads;

    final encoder = await Interpreter.fromAsset(
      VisualSearchConfig.imageEncoderAsset,
      options: encoderOptions,
    );
    final projection = await Interpreter.fromAsset(
      VisualSearchConfig.imageProjectionAsset,
      options: projectionOptions,
    );

    try {
      _validateEncoder(encoder);
      _validateProjection(projection);
      _imageEncoder = encoder;
      _imageProjection = projection;
    } catch (_) {
      encoder.close();
      projection.close();
      rethrow;
    }
  }

  int get embeddingDimension {
    final projection = _imageProjection;
    if (projection == null) {
      throw StateError('VisualEmbeddingService is not initialized.');
    }
    return projection.getOutputTensor(0).shape.last;
  }

  Future<Float32List> generateEmbedding(Uint8List imageBytes) async {
    await initialize();

    final input = _preprocessImage(imageBytes);
    final encoderEmbedding = _runImageEncoder(input);
    final projectedEmbedding = _runImageProjection(encoderEmbedding);

    return _normalizeL2(projectedEmbedding);
  }

  Float32List _preprocessImage(Uint8List imageBytes) {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw StateError('Unable to decode image.');
    }

    final oriented = img.bakeOrientation(decoded);
    final resized = img.copyResize(
      oriented,
      width: VisualSearchConfig.inputWidth,
      height: VisualSearchConfig.inputHeight,
      interpolation: img.Interpolation.linear,
    );

    final input = Float32List(
      VisualSearchConfig.inputWidth *
          VisualSearchConfig.inputHeight *
          VisualSearchConfig.inputChannels,
    );

    var offset = 0;
    for (var y = 0; y < VisualSearchConfig.inputHeight; y++) {
      for (var x = 0; x < VisualSearchConfig.inputWidth; x++) {
        final pixel = resized.getPixel(x, y);
        input[offset++] = pixel.r.toDouble();
        input[offset++] = pixel.g.toDouble();
        input[offset++] = pixel.b.toDouble();
      }
    }

    return input;
  }

  Float32List _runImageEncoder(Float32List input) {
    final interpreter = _imageEncoder;
    if (interpreter == null) {
      throw StateError('Image encoder is not initialized.');
    }

    final inputTensor = interpreter.getInputTensor(0);
    final outputTensor = interpreter.getOutputTensor(0);

    final inputObject = input.reshape(inputTensor.shape);
    final output = List.generate(
      outputTensor.shape.first,
      (_) => List<double>.filled(outputTensor.shape.last, 0.0),
    );

    interpreter.run(inputObject, output);

    return Float32List.fromList(output.first);
  }

  Float32List _runImageProjection(Float32List encoderEmbedding) {
    final interpreter = _imageProjection;
    if (interpreter == null) {
      throw StateError('Image projection model is not initialized.');
    }

    final inputTensor = interpreter.getInputTensor(0);
    final outputTensor = interpreter.getOutputTensor(0);

    final inputObject = encoderEmbedding.reshape(inputTensor.shape);
    final output = List.generate(
      outputTensor.shape.first,
      (_) => List<double>.filled(outputTensor.shape.last, 0.0),
    );

    interpreter.run(inputObject, output);

    return Float32List.fromList(output.first);
  }

  Float32List _normalizeL2(Float32List embedding) {
    var squaredSum = 0.0;
    for (final value in embedding) {
      squaredSum += value * value;
    }

    final norm = math.sqrt(squaredSum);
    if (!norm.isFinite || norm <= 0.0) {
      throw StateError('Visual embedding has an invalid L2 norm.');
    }

    final normalized = Float32List(embedding.length);
    for (var i = 0; i < embedding.length; i++) {
      normalized[i] = embedding[i] / norm;
    }
    return normalized;
  }

  void _validateEncoder(Interpreter interpreter) {
    final inputTensor = interpreter.getInputTensor(0);
    final outputTensor = interpreter.getOutputTensor(0);

    const expectedInputShape = [
      1,
      VisualSearchConfig.inputHeight,
      VisualSearchConfig.inputWidth,
      VisualSearchConfig.inputChannels,
    ];

    if (!_sameShape(inputTensor.shape, expectedInputShape)) {
      throw StateError(
        'Unexpected EfficientNet input shape: ${inputTensor.shape}.',
      );
    }
    if (inputTensor.type != TensorType.float32) {
      throw StateError(
        'Unexpected EfficientNet input type: ${inputTensor.type}.',
      );
    }
    if (outputTensor.shape.length != 2 ||
        outputTensor.shape.first != 1 ||
        outputTensor.shape.last !=
            VisualSearchConfig.encoderEmbeddingDimension) {
      throw StateError(
        'Unexpected EfficientNet output shape: ${outputTensor.shape}.',
      );
    }
    if (outputTensor.type != TensorType.float32) {
      throw StateError(
        'Unexpected EfficientNet output type: ${outputTensor.type}.',
      );
    }
  }

  void _validateProjection(Interpreter interpreter) {
    final inputTensor = interpreter.getInputTensor(0);
    final outputTensor = interpreter.getOutputTensor(0);

    if (inputTensor.shape.length != 2 ||
        inputTensor.shape.first != 1 ||
        inputTensor.shape.last !=
            VisualSearchConfig.encoderEmbeddingDimension) {
      throw StateError(
        'Unexpected image projection input shape: ${inputTensor.shape}.',
      );
    }
    if (inputTensor.type != TensorType.float32) {
      throw StateError(
        'Unexpected image projection input type: ${inputTensor.type}.',
      );
    }
    if (outputTensor.shape.length != 2 ||
        outputTensor.shape.first != 1 ||
        outputTensor.shape.last <= 0) {
      throw StateError(
        'Unexpected image projection output shape: ${outputTensor.shape}.',
      );
    }
    if (outputTensor.type != TensorType.float32) {
      throw StateError(
        'Unexpected image projection output type: ${outputTensor.type}.',
      );
    }
  }

  bool _sameShape(List<int> first, List<int> second) {
    if (first.length != second.length) {
      return false;
    }
    for (var i = 0; i < first.length; i++) {
      if (first[i] != second[i]) {
        return false;
      }
    }
    return true;
  }

  void dispose() {
    _imageProjection?.close();
    _imageProjection = null;
    _imageEncoder?.close();
    _imageEncoder = null;
  }
}
