import 'package:flutter_test/flutter_test.dart';
import 'package:pixmind/features/search/search_query.dart';
import 'package:pixmind/features/search/search_scope.dart';

void main() {
  test('mixed typed query keeps each condition in its own field', () {
    final parsed = SearchQueryParser.parse(
      'person:fouad object:car ocr:ahmad',
    );

    expect(parsed.hasTypedFilters, isTrue);
    expect(parsed.clauses.length, 3);
    expect(parsed.clauses[0].field, SearchField.people);
    expect(parsed.clauses[0].value, 'fouad');
    expect(parsed.clauses[1].field, SearchField.objects);
    expect(parsed.clauses[1].value, 'car');
    expect(parsed.clauses[2].field, SearchField.ocr);
    expect(parsed.clauses[2].value, 'ahmad');
  });

  test('quoted OCR stays one exact phrase', () {
    final parsed = SearchQueryParser.parse(
      'person:fouad object:سيارة ocr:"Welcome to PixMind"',
    );

    final object = parsed.clauses.firstWhere(
      (clause) => clause.field == SearchField.objects,
    );
    final ocr = parsed.clauses.firstWhere(
      (clause) => clause.field == SearchField.ocr,
    );

    expect(object.value, 'car');
    expect(ocr.value, 'welcome to pixmind');
    expect(ocr.exactPhrase, isTrue);
  });

  test('standalone quoted text uses the selected OCR scope', () {
    final parsed = SearchQueryParser.parse(
      '"Ahmad Software"',
      scope: SearchScope.ocr,
    );

    expect(parsed.clauses.length, 1);
    expect(parsed.clauses.single.field, SearchField.ocr);
    expect(parsed.clauses.single.value, 'ahmad software');
    expect(parsed.clauses.single.exactPhrase, isTrue);
  });

  test('unqualified general search remains backwards compatible', () {
    final parsed = SearchQueryParser.parse('سيارة حمراء 2025');
    expect(
      parsed.clauses.map((clause) => clause.value).toList(),
      ['car', 'red', '2025'],
    );
    expect(
      parsed.clauses.every((clause) => clause.field == SearchField.general),
      isTrue,
    );
  });
}
