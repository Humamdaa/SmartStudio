import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Android-native frame extraction for Smart Video Index.
///
/// Uses MediaMetadataRetriever through a tiny MethodChannel instead of adding
/// a full FFmpeg dependency. Returned bytes are JPEG frames sized for on-device
/// YOLO/Face inference.
class VideoFrameExtractor {
  VideoFrameExtractor._();
  static final VideoFrameExtractor instance = VideoFrameExtractor._();

  static const MethodChannel _channel = MethodChannel('pixmind/video_frame');

  Future<Uint8List?> extractJpeg({
    required String path,
    required int timestampMs,
    int maxWidth = 640,
    int maxHeight = 640,
    int jpegQuality = 84,
  }) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('extractFrame', {
        'path': path,
        'timestampUs': timestampMs * 1000,
        'maxWidth': maxWidth,
        'maxHeight': maxHeight,
        'jpegQuality': jpegQuality,
      });
      return bytes == null || bytes.isEmpty ? null : bytes;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
