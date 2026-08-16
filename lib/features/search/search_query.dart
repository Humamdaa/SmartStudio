import 'search_scope.dart';
import 'search_vocabulary.dart';

enum SearchField {
  general,
  people,
  ocr,
  objects,
  colors,
  scenes,
  date,
}

class SearchClause {
  final SearchField field;
  final String value;
  final bool exactPhrase;

  const SearchClause({
    required this.field,
    required this.value,
    this.exactPhrase = false,
  });

  String get databaseField => field.name;
}

class ParsedSearchQuery {
  final List<SearchClause> clauses;
  final bool hasTypedFilters;

  const ParsedSearchQuery({
    required this.clauses,
    required this.hasTypedFilters,
  });

  bool get isEmpty => clauses.isEmpty;
}

/// Parses a compact offline query language while keeping normal gallery search
/// fully backwards compatible.
///
/// Examples:
///   person:fouad object:car ocr:ahmad
///   person:"Fouad Dalloul" ocr:"welcome to pixmind" color:red
///
/// Unqualified words continue to use the selected [SearchScope]. Quoted text
/// inside OCR scope is treated as an exact normalized phrase.
class SearchQueryParser {
  SearchQueryParser._();

  static final RegExp _typed = RegExp(
    r'(person|people|شخص|object|obj|عنصر|ocr|text|نص|color|لون|scene|مشهد|date|year|تاريخ)\s*:\s*(?:"([^"]+)"|([^\s]+))',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _quoted = RegExp(r'"([^"]+)"', unicode: true);

  static ParsedSearchQuery parse(
    String query, {
    SearchScope scope = SearchScope.general,
  }) {
    if (query.trim().isEmpty) {
      return const ParsedSearchQuery(clauses: [], hasTypedFilters: false);
    }

    final clauses = <SearchClause>[];
    final consumed = List<bool>.filled(query.length, false);
    var hasTyped = false;

    for (final match in _typed.allMatches(query)) {
      hasTyped = true;
      for (var index = match.start; index < match.end; index++) {
        consumed[index] = true;
      }
      final prefix = (match.group(1) ?? '').toLowerCase();
      final quoted = match.group(2);
      final rawValue = quoted ?? match.group(3) ?? '';
      _appendValue(
        clauses,
        field: _fieldForPrefix(prefix),
        rawValue: rawValue,
        exactPhrase: quoted != null,
      );
    }

    final remainingBuffer = StringBuffer();
    for (var index = 0; index < query.length; index++) {
      remainingBuffer.write(consumed[index] ? ' ' : query[index]);
    }
    var remaining = remainingBuffer.toString();

    // Standalone quotes are useful with a scope chip, e.g. OCR +
    // "welcome to pixmind".
    for (final match in _quoted.allMatches(remaining)) {
      final raw = match.group(1) ?? '';
      _appendValue(
        clauses,
        field: _fieldForScope(scope),
        rawValue: raw,
        exactPhrase: true,
      );
    }
    remaining = remaining.replaceAll(_quoted, ' ');

    final remainingField = _fieldForScope(scope);
    for (final term in _termsForField(remainingField, remaining)) {
      if (term.isNotEmpty) {
        clauses.add(SearchClause(field: remainingField, value: term));
      }
    }

    // Keep deterministic order but avoid duplicate SQL conditions.
    final unique = <String>{};
    final deduped = <SearchClause>[];
    for (final clause in clauses) {
      final key = '${clause.field.name}|${clause.exactPhrase}|${clause.value}';
      if (unique.add(key)) deduped.add(clause);
    }

    return ParsedSearchQuery(
      clauses: deduped,
      hasTypedFilters: hasTyped,
    );
  }

  static void _appendValue(
    List<SearchClause> clauses, {
    required SearchField field,
    required String rawValue,
    required bool exactPhrase,
  }) {
    final raw = rawValue.trim();
    if (raw.isEmpty) return;

    if (exactPhrase) {
      final normalized = SearchVocabulary.normalize(raw);
      if (normalized.isNotEmpty) {
        clauses.add(SearchClause(
          field: field,
          value: normalized,
          exactPhrase: true,
        ));
      }
      return;
    }

    for (final term in _termsForField(field, raw)) {
      if (term.isNotEmpty) {
        clauses.add(SearchClause(field: field, value: term));
      }
    }
  }

  static List<String> _termsForField(SearchField field, String raw) {
    if (raw.trim().isEmpty) return const [];
    switch (field) {
      case SearchField.people:
      case SearchField.ocr:
      case SearchField.date:
        final normalized = SearchVocabulary.normalize(raw);
        return normalized.isEmpty ? const [] : normalized.split(' ');
      case SearchField.objects:
      case SearchField.colors:
      case SearchField.scenes:
      case SearchField.general:
        return SearchVocabulary.queryTerms(raw);
    }
  }

  static SearchField _fieldForPrefix(String prefix) {
    switch (prefix) {
      case 'person':
      case 'people':
      case 'شخص':
        return SearchField.people;
      case 'object':
      case 'obj':
      case 'عنصر':
        return SearchField.objects;
      case 'ocr':
      case 'text':
      case 'نص':
        return SearchField.ocr;
      case 'color':
      case 'لون':
        return SearchField.colors;
      case 'scene':
      case 'مشهد':
        return SearchField.scenes;
      case 'date':
      case 'year':
      case 'تاريخ':
        return SearchField.date;
      default:
        return SearchField.general;
    }
  }

  static SearchField _fieldForScope(SearchScope scope) {
    return switch (scope) {
      SearchScope.people => SearchField.people,
      SearchScope.ocr => SearchField.ocr,
      SearchScope.objects => SearchField.objects,
      SearchScope.colors => SearchField.colors,
      SearchScope.scenes => SearchField.scenes,
      SearchScope.date => SearchField.date,
      SearchScope.general => SearchField.general,
    };
  }
}
