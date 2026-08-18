import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final class TextEmbeddingApi {
  TextEmbeddingApi({String? baseUrl})
    : baseUrl =
          baseUrl ??
          const String.fromEnvironment(
            'PIX_MIND_TEXT_API',
            defaultValue: 'http://192.168.137.1:8000',
          );

  final String baseUrl;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  Future<Float32List> embed(String text) async {
    final clean = text.trim();

    if (clean.isEmpty) {
      throw ArgumentError('Text query cannot be empty.');
    }

    final uri = Uri.parse('$baseUrl/embed');

    final request = await _client.postUrl(uri);

    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'text': clean}));

    final response = await request.close().timeout(const Duration(seconds: 30));

    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Embedding server returned ${response.statusCode}: $body',
      );
    }

    final decoded = jsonDecode(body);

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid embedding response.');
    }

    final rawDimension = (decoded['dimension'] as num?)?.toInt();
    final values = decoded['embedding'];

    if (rawDimension == null || rawDimension != 256) {
      throw StateError(
        'Expected a 256-D text embedding, received $rawDimension.',
      );
    }

    final int dimension = rawDimension;

    if (values is! List || values.length != dimension) {
      throw const FormatException('Embedding response has an invalid vector.');
    }

    final embedding = Float32List(dimension);

    for (var i = 0; i < dimension; i++) {
      final value = values[i];

      if (value is! num) {
        throw const FormatException('Embedding contains a non-numeric value.');
      }

      embedding[i] = value.toDouble();
    }

    return embedding;
  }

  void close() {
    _client.close(force: true);
  }
}
