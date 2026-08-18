import 'dart:typed_data';

import '../../data/database/db_helper.dart';
import 'visual_search_config.dart';

final class SimilarImageResult {
  const SimilarImageResult({required this.assetId, required this.similarity});

  final String assetId;
  final double similarity;

  double get similarityPercent {
    return similarity.clamp(0.0, 1.0).toDouble() * 100.0;
  }
}

final class VisualSearchResults {
  const VisualSearchResults({
    required this.topMatches,
    required this.otherMatches,
  });

  final List<SimilarImageResult> topMatches;
  final List<SimilarImageResult> otherMatches;

  bool get isEmpty => topMatches.isEmpty && otherMatches.isEmpty;
}

final class VisualSearchRepository {
  VisualSearchRepository({DatabaseHelper? database})
    : _database = database ?? DatabaseHelper.instance;

  final DatabaseHelper _database;

  Future<List<SimilarImageResult>> findSimilarByEmbedding({
    required Float32List queryEmbedding,
    int limit = 60,
    int pageSize = 250,
  }) async {
    final results = await findSimilarImages(
      // Text queries have no source AssetEntity to exclude.
      // This value can never be a real photo_manager asset id.
      queryAssetId: '__pixmind_text_query__',
      queryEmbedding: queryEmbedding,
      topCount: limit,
      pageSize: pageSize,
    );

    return results.topMatches;
  }

  Future<void> saveEmbedding({
    required String assetId,
    required Float32List embedding,
  }) async {
    if (embedding.isEmpty) {
      throw ArgumentError('Cannot save an empty visual embedding.');
    }

    await _database.saveVisualImageEmbedding(
      assetId: assetId,
      embedding: _encodeEmbedding(embedding),
      dimension: embedding.length,
      modelVersion: VisualSearchConfig.modelVersion,
    );
  }

  Future<Float32List?> getEmbedding(String assetId) async {
    final row = await _database.getVisualImageEmbedding(
      assetId: assetId,
      modelVersion: VisualSearchConfig.modelVersion,
    );

    if (row == null) {
      return null;
    }

    return _decodeEmbedding(row);
  }

  Future<Set<String>> getIndexedAssetIds() {
    return _database.getVisualImageEmbeddingAssetIds(
      modelVersion: VisualSearchConfig.modelVersion,
    );
  }

  Future<int> countIndexedImages() {
    return _database.countVisualImageEmbeddings(
      modelVersion: VisualSearchConfig.modelVersion,
    );
  }

  Future<VisualSearchResults> findSimilarImages({
    required String queryAssetId,
    required Float32List queryEmbedding,
    int topCount = 10,
    int pageSize = 250,
  }) async {
    if (queryEmbedding.isEmpty) {
      throw ArgumentError('Query embedding cannot be empty.');
    }

    final matches = <SimilarImageResult>[];
    var offset = 0;

    while (true) {
      final rows = await _database.getVisualImageEmbeddingPage(
        modelVersion: VisualSearchConfig.modelVersion,
        limit: pageSize,
        offset: offset,
        excludeAssetId: queryAssetId,
      );

      if (rows.isEmpty) {
        break;
      }

      for (final row in rows) {
        final candidate = _decodeEmbedding(row);
        if (candidate.length != queryEmbedding.length) {
          continue;
        }

        final similarity = _dotProduct(queryEmbedding, candidate);
        if (!similarity.isFinite) {
          continue;
        }

        matches.add(
          SimilarImageResult(
            assetId: row['asset_id'].toString(),
            similarity: similarity,
          ),
        );
      }

      offset += rows.length;
      if (rows.length < pageSize) {
        break;
      }
    }

    matches.sort((a, b) => b.similarity.compareTo(a.similarity));

    final splitIndex = matches.length < topCount ? matches.length : topCount;

    return VisualSearchResults(
      topMatches: List.unmodifiable(matches.take(splitIndex)),
      otherMatches: List.unmodifiable(matches.skip(splitIndex)),
    );
  }

  double _dotProduct(Float32List first, Float32List second) {
    var score = 0.0;
    for (var i = 0; i < first.length; i++) {
      score += first[i] * second[i];
    }
    return score;
  }

  Uint8List _encodeEmbedding(Float32List embedding) {
    final byteData = ByteData(embedding.length * Float32List.bytesPerElement);

    for (var i = 0; i < embedding.length; i++) {
      byteData.setFloat32(
        i * Float32List.bytesPerElement,
        embedding[i],
        Endian.little,
      );
    }

    return byteData.buffer.asUint8List();
  }

  Float32List _decodeEmbedding(Map<String, Object?> row) {
    final dimension = (row['dimension'] as num?)?.toInt();
    if (dimension == null || dimension <= 0) {
      throw StateError('Invalid stored visual embedding dimension.');
    }

    final rawEmbedding = row['embedding'];
    final Uint8List bytes;

    if (rawEmbedding is Uint8List) {
      bytes = rawEmbedding;
    } else if (rawEmbedding is List<int>) {
      bytes = Uint8List.fromList(rawEmbedding);
    } else {
      throw StateError('Invalid visual embedding BLOB.');
    }

    final expectedBytes = dimension * Float32List.bytesPerElement;
    if (bytes.lengthInBytes != expectedBytes) {
      throw StateError('Stored embedding size does not match dimension.');
    }

    final byteData = ByteData.sublistView(bytes);
    final embedding = Float32List(dimension);

    for (var i = 0; i < dimension; i++) {
      embedding[i] = byteData.getFloat32(
        i * Float32List.bytesPerElement,
        Endian.little,
      );
    }

    return embedding;
  }
}
