import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

const _good =
    'Open a form for filling, by assemblyId and maskId. Its ids come from '
    'app.forms and exist nowhere else.';

CatalogEntry _entry({
  String name = 'form.open',
  String? summary = _good,
  String? description = _good,
  String kind = 'observe',
  String? effect,
  bool? takesParameters,
  JsonMap? schema = const {
    'type': 'object',
    'properties': {
      'assemblyId': {'type': 'integer'},
    },
    'required': ['assemblyId'],
  },
}) => CatalogEntry(
  name: name,
  summary: summary,
  description: description,
  kind: kind,
  effect: effect,
  takesParameters: takesParameters,
  paramsSchema: schema,
);

Set<String> _rules(List<CatalogFinding> findings) => {for (final f in findings) f.rule};

void main() {
  group('catalogLint', () {
    test('a well-formed entry has nothing to say about it', () {
      expect(catalogLint([_entry()]), isEmpty);
    });

    test('the first sentence is what the listing shows, not the whole text', () {
      expect(_entry().firstSentence, 'Open a form for filling, by assemblyId and maskId.');
    });

    test('an entry with no summary cannot be chosen', () {
      final findings = catalogLint([_entry(summary: '  ', description: null)]);
      expect(_rules(findings), contains('no_summary'));
      expect(findings.single.isError, isTrue);
    });

    test('a parameterless intent may publish {} and is not scolded for it', () {
      // `IntentStrategy.objectSchema` normalises it before it reaches an API
      // that would reject it, and nav.back really does take nothing.
      expect(catalogLint([_entry(name: 'nav.back', schema: const {})]), isEmpty);
    });

    test('but {} is wrong when the listing promised parameters', () {
      final findings = catalogLint([_entry(schema: const {}, takesParameters: true)]);
      expect(_rules(findings), contains('undescribed_parameters'));
      expect(findings.single.isError, isTrue);
    });

    test('a schema that is not an object cannot be a function-calling tool', () {
      final findings = catalogLint([
        _entry(schema: const {'type': 'string'}),
      ]);
      expect(_rules(findings), contains('non_object_schema'));
    });

    test('two intents with the same first sentence are both flagged', () {
      final findings = catalogLint([_entry(name: 'a.one'), _entry(name: 'a.two')]);
      final duplicates = findings.where((f) => f.rule == 'duplicate_summary');
      expect(duplicates.map((f) => f.intent), containsAll(['a.one', 'a.two']));
      expect(duplicates.first.message, contains('a.two'));
    });

    test('a description under the floor is flagged', () {
      final findings = catalogLint([_entry(summary: 'Counts things.', description: 'Counts things.')]);
      expect(_rules(findings), contains('short_description'));
    });

    test('an act intent that declares no effect is measured as undeclared', () {
      expect(_rules(catalogLint([_entry(kind: 'act')])), contains('undeclared_effect'));
      expect(_rules(catalogLint([_entry(kind: 'act', effect: 'irreversible')])), isNot(contains('undeclared_effect')));
    });

    test('judgement is not linted: a sentence may name its subject in words', () {
      // A rule requiring the parameter's own spelling fired on six correct
      // entries of the real catalogue and on nothing that was wrong.
      expect(catalogLint([_entry(summary: 'Number of entries of an endpoint matching the given filters.')]), isEmpty);
    });

    test('a listing entry with no schema is not judged on parameters', () {
      // The catalogue lists; the schema arrives only once describe is called.
      expect(catalogLint([_entry(schema: null)]), isEmpty);
    });
  });

  group('promptIntentsNotInCatalog', () {
    final catalog = [_entry(name: 'form.open'), _entry(name: 'data.count')];

    test('names an intent the prompt teaches and the app does not publish', () {
      expect(promptIntentsNotInCatalog('Call form.open, then form.submit.', catalog), ['form.submit']);
    });

    test('ignores prose and names outside the catalogue namespaces', () {
      expect(promptIntentsNotInCatalog('See readme.md and call data.count.', catalog), isEmpty);
    });
  });
}
