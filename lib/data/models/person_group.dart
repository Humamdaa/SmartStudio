import 'dart:convert';
import 'dart:typed_data';

class PersonGroup {
  final String id;
  final String name;
  final String searchName;
  final String? coverAssetId;
  final String? coverFaceKey;
  final Uint8List? coverFaceJpeg;
  final double coverQuality;
  final List<double> centroid;
  final int sampleCount;
  final int photoCount;
  final bool isNamed;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PersonGroup({
    required this.id,
    required this.name,
    required this.searchName,
    required this.coverAssetId,
    required this.coverFaceKey,
    required this.coverFaceJpeg,
    required this.coverQuality,
    required this.centroid,
    required this.sampleCount,
    required this.photoCount,
    required this.isNamed,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PersonGroup.fromDatabase(Map<String, Object?> row) {
    final rawCover = row['cover_face_jpeg'];
    return PersonGroup(
      id: row['id'] as String,
      name: row['name']?.toString() ?? 'شخص غير مسمى',
      searchName: row['search_name']?.toString() ?? '',
      coverAssetId: row['cover_asset_id']?.toString(),
      coverFaceKey: row['cover_face_key']?.toString(),
      coverFaceJpeg: rawCover is Uint8List
          ? rawCover
          : rawCover is List<int>
          ? Uint8List.fromList(rawCover)
          : null,
      coverQuality: (row['cover_quality'] as num?)?.toDouble() ?? 0,
      centroid: decodeEmbedding(row['centroid']),
      sampleCount: (row['sample_count'] as num?)?.toInt() ?? 0,
      photoCount: (row['photo_count'] as num?)?.toInt() ?? 0,
      isNamed: ((row['is_named'] as num?)?.toInt() ?? 0) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['updated_at'] as num?)?.toInt() ??
            (row['created_at'] as num?)?.toInt() ??
            0,
      ),
    );
  }

  static List<double> decodeEmbedding(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final value = jsonDecode(raw);
      if (value is List) {
        return value
            .whereType<num>()
            .map((item) => item.toDouble())
            .toList(growable: false);
      }
    } catch (_) {
      // A damaged development row should not break the People screen.
    }
    return const [];
  }
}

class PersonFaceOccurrence {
  final int id;
  final String faceKey;
  final String assetId;
  final String personId;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double confidence;
  final double qualityScore;
  final double poseScore;
  final List<double> embedding;

  const PersonFaceOccurrence({
    required this.id,
    required this.faceKey,
    required this.assetId,
    required this.personId,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.confidence,
    required this.qualityScore,
    required this.poseScore,
    required this.embedding,
  });
}
