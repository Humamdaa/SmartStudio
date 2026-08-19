import '../database/db_helper.dart';
import '../models/search_index_entry.dart';
import '../../features/search/search_query.dart';
import '../../features/search/search_scope.dart';
import '../../features/search/search_vocabulary.dart';

class PreciseSearchRepository {
  PreciseSearchRepository({DatabaseHelper? database})
    : _database = database ?? DatabaseHelper.instance;

  final DatabaseHelper _database;

  Future<void> save(SearchIndexEntry entry) {
    return _database.saveSearchIndex(entry.toDatabase());
  }

  Future<void> saveContent(SearchIndexEntry entry) {
    return _database.upsertContentIndex(entry.toDatabase());
  }

  Future<int> indexedCount() => _database.getIndexedCount();

  Future<Set<String>> indexedAssetIds() {
    return _database.getIndexedAssetIds();
  }

  Future<List<SearchHit>> search(
    String query, {
    SearchScope scope = SearchScope.general,
    int limit = 120,
  }) async {
    final parsed = SearchQueryParser.parse(query, scope: scope);
    if (parsed.isEmpty) return const [];

    final conditions = parsed.clauses
        .map(
          (clause) => SearchIndexCondition(
            field: clause.databaseField,
            value: clause.value,
          ),
        )
        .toList(growable: false);
    final rowLimit = limit < 300 ? 300 : limit;
    final rows = await _database.searchIndexAdvanced(
      conditions,
      limit: rowLimit,
    );
    final hits = rows.map((row) => _rank(row, parsed)).toList();
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return b.takenAt.compareTo(a.takenAt);
    });
    return hits.take(limit).toList(growable: false);
  }

  SearchHit _rank(Map<String, dynamic> row, ParsedSearchQuery parsed) {
    final objects = SearchIndexEntry.decodeLabels(row['objects']);
    final scenes = SearchIndexEntry.decodeLabels(row['scenes']);
    final colors = SearchIndexEntry.decodeLabels(row['colors']);
    final ocrText = row['ocr_text']?.toString() ?? '';
    final metadata = [
      row['title']?.toString() ?? '',
      row['metadata']?.toString() ?? '',
    ].join(' ');
    final peopleText = row['person_display_names']?.toString() ?? '';
    final people = peopleText
        .split('،')
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);

    final normalizedObjects = objects.map(SearchVocabulary.normalize).toList();
    final normalizedScenes = scenes.map(SearchVocabulary.normalize).toList();
    final normalizedColors = colors.map(SearchVocabulary.normalize).toList();
    final normalizedOcr = SearchVocabulary.normalize(ocrText);
    final normalizedMetadata = SearchVocabulary.normalize(metadata);
    final normalizedPeople = people.map(SearchVocabulary.normalize).toList();
    final normalizedGeneral = SearchVocabulary.normalize(
      [
        row['title']?.toString() ?? '',
        objects.join(' '),
        scenes.join(' '),
        colors.join(' '),
        ocrText,
        metadata,
        people.join(' '),
      ].join(' '),
    );

    var score = 0.0;
    final reasons = <String>[];
    for (final clause in parsed.clauses) {
      final term = clause.value;
      switch (clause.field) {
        case SearchField.people:
          final personIndex = normalizedPeople.indexWhere(
            (name) => name.contains(term),
          );
          if (personIndex >= 0) {
            score += clause.exactPhrase ? 12 : 10;
            _addReason(reasons, 'شخص: ${people[personIndex]}');
          }
          break;
        case SearchField.ocr:
          if (normalizedOcr.contains(term)) {
            score += clause.exactPhrase ? 9 : 7;
            _addReason(
              reasons,
              clause.exactPhrase ? 'عبارة OCR مطابقة' : 'نص داخل الصورة',
            );
          }
          break;
        case SearchField.objects:
          final objectIndex = normalizedObjects.indexWhere(
            (label) => label.contains(term),
          );
          if (objectIndex >= 0) {
            score += 8;
            _addReason(
              reasons,
              'عنصر: ${SearchVocabulary.arabicName(objects[objectIndex])}',
            );
          }
          break;
        case SearchField.colors:
          final colorIndex = normalizedColors.indexWhere(
            (label) => label.contains(term),
          );
          if (colorIndex >= 0) {
            score += 5;
            _addReason(
              reasons,
              'لون: ${SearchVocabulary.arabicName(colors[colorIndex])}',
            );
          }
          break;
        case SearchField.scenes:
          final sceneIndex = normalizedScenes.indexWhere(
            (label) => label.contains(term),
          );
          if (sceneIndex >= 0) {
            score += 5;
            _addReason(
              reasons,
              'مشهد: ${SearchVocabulary.arabicName(scenes[sceneIndex])}',
            );
          }
          break;
        case SearchField.date:
          if (normalizedMetadata.contains(term)) {
            score += 3;
            _addReason(reasons, 'تاريخ أو بيانات الصورة');
          }
          break;
        case SearchField.general:
          if (normalizedGeneral.contains(term)) {
            // General search remains convenient, but explicit typed filters get
            // higher ranking weight because the user's intent is unambiguous.
            score += clause.exactPhrase ? 4 : 2;
            _addGeneralReason(
              reasons,
              term,
              objects: objects,
              normalizedObjects: normalizedObjects,
              scenes: scenes,
              normalizedScenes: normalizedScenes,
              colors: colors,
              normalizedColors: normalizedColors,
              normalizedOcr: normalizedOcr,
              people: people,
              normalizedPeople: normalizedPeople,
            );
          }
          break;
      }
    }

    return SearchHit(
      assetId: row['asset_id'] as String,
      takenAt: DateTime.fromMillisecondsSinceEpoch(row['taken_at'] as int),
      objects: objects,
      scenes: scenes,
      colors: colors,
      ocrText: ocrText,
      metadata: metadata,
      people: people,
      score: score,
      reasons: reasons.take(3).toList(growable: false),
    );
  }

  void _addGeneralReason(
    List<String> reasons,
    String term, {
    required List<String> objects,
    required List<String> normalizedObjects,
    required List<String> scenes,
    required List<String> normalizedScenes,
    required List<String> colors,
    required List<String> normalizedColors,
    required String normalizedOcr,
    required List<String> people,
    required List<String> normalizedPeople,
  }) {
    final personIndex = normalizedPeople.indexWhere(
      (name) => name.contains(term),
    );
    if (personIndex >= 0) {
      _addReason(reasons, 'شخص: ${people[personIndex]}');
      return;
    }
    final objectIndex = normalizedObjects.indexWhere(
      (label) => label.contains(term),
    );
    if (objectIndex >= 0) {
      _addReason(
        reasons,
        'عنصر: ${SearchVocabulary.arabicName(objects[objectIndex])}',
      );
      return;
    }
    if (normalizedOcr.contains(term)) {
      _addReason(reasons, 'نص داخل الصورة');
      return;
    }
    final sceneIndex = normalizedScenes.indexWhere(
      (label) => label.contains(term),
    );
    if (sceneIndex >= 0) {
      _addReason(
        reasons,
        'مشهد: ${SearchVocabulary.arabicName(scenes[sceneIndex])}',
      );
      return;
    }
    final colorIndex = normalizedColors.indexWhere(
      (label) => label.contains(term),
    );
    if (colorIndex >= 0) {
      _addReason(
        reasons,
        'لون: ${SearchVocabulary.arabicName(colors[colorIndex])}',
      );
      return;
    }
    _addReason(reasons, 'تطابق عام');
  }

  void _addReason(List<String> reasons, String reason) {
    if (!reasons.contains(reason)) reasons.add(reason);
  }
}
