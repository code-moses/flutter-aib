import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('json schema', () {
    test('accepts an integer written as a whole double', () {
      // Models emit 5.0 for an integer field; rejecting it would be pedantry
      // the model cannot act on.
      expect(
        validateAgainstSchema(
          const {'n': 5.0},
          const {
            'type': 'object',
            'properties': {
              'n': {'type': 'integer'},
            },
          },
        ),
        isEmpty,
      );
    });

    test('checks enums, nested objects and array items', () {
      final violations = validateAgainstSchema(
        const {
          'mode': 'sideways',
          'row': {'Menge': 'five'},
          'ids': [1, 'two'],
        },
        const {
          'type': 'object',
          'properties': {
            'mode': {
              'type': 'string',
              'enum': ['replace', 'append'],
            },
            'row': {
              'type': 'object',
              'properties': {
                'Menge': {'type': 'number'},
              },
            },
            'ids': {
              'type': 'array',
              'items': {'type': 'integer'},
            },
          },
        },
      );
      expect(violations, hasLength(3));
      expect(violations.join(), contains(r'$.row.Menge'));
      expect(violations.join(), contains(r'$.ids[1]'));
    });

    test('unknown schema keywords are ignored, not guessed at', () {
      expect(
        validateAgainstSchema(
          const {'a': 'x'},
          const {
            'type': 'object',
            'properties': {
              'a': {'type': 'string', 'format': 'email', r'$ref': '#/x'},
            },
          },
        ),
        isEmpty,
      );
    });
  });
}
