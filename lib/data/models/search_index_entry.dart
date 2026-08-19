import 'dart:convert';

import '../../features/search/search_vocabulary.dart';

class SearchIndexEntry {
  final String assetId;
  final String title;
  final DateTime takenAt;
  final int width;
  final int height;
  final List<String> objects;
  final List<String> scenes;
  final List<String> colors;
  final String ocrText;
  final List<String> ocrScripts;
  final String metadata;
  final List<String> people;
  final int faceCount;
  final DateTime indexedAt;

  const SearchIndexEntry({
    required this.assetId,
    required this.title,
    required this.takenAt,
    required this.width,
    required this.height,
    required this.objects,
    required this.scenes,
    required this.colors,
    required this.ocrText,
    required this.ocrScripts,
    required this.metadata,
    required this.people,
    required this.faceCount,
    required this.indexedAt,
  });

  String get searchableText => SearchVocabulary.normalize(
    [
      title,
      objects.join(' '),
      scenes.join(' '),
      colors.join(' '),
      ocrText,
      metadata,
    ].join(' '),
  );

  Map<String, dynamic> toDatabase() {
    return {
      'asset_id': assetId,
      'title': title,
      'taken_at': takenAt.millisecondsSinceEpoch,
      'width': width,
      'height': height,
      'objects': jsonEncode(objects),
      'scenes': jsonEncode(scenes),
      'colors': jsonEncode(colors),
      'ocr_text': ocrText,
      'ocr_search_text': SearchVocabulary.normalize(ocrText),
      'ocr_scripts': jsonEncode(ocrScripts),
      'metadata': metadata,
      'people': jsonEncode(people),
      'face_count': faceCount,
      'searchable_text': searchableText,
      'indexed_at': indexedAt.millisecondsSinceEpoch,
      'model_version':
          'content-v2.3.8:yolo11n+mlkit-scene+named-colors+metadata',
    };
  }

  static List<String> decodeLabels(Object? value) {
    if (value is! String || value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.map((item) => item.toString()).toList(growable: false);
      }
    } catch (_) {
      // Old development rows may contain a plain comma-separated value.
      return value
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }
}

class SearchHit {
  final String assetId;
  final DateTime takenAt;
  final List<String> objects;
  final List<String> scenes;
  final List<String> colors;
  final String ocrText;
  final String metadata;
  final List<String> people;
  final double score;
  final List<String> reasons;

  const SearchHit({
    required this.assetId,
    required this.takenAt,
    required this.objects,
    required this.scenes,
    required this.colors,
    required this.ocrText,
    required this.metadata,
    required this.people,
    required this.score,
    required this.reasons,
  });
}
