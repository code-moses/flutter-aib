import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

void main() {
  const context = {
    'count': 1,
    'fields': {'dueDate': '2026-07-11', 'completed': false, 'priority': 2},
    'title': 'Milch kaufen',
  };

  bool eval(String expr) => ConditionExpr.evaluate(expr, context);

  test('equality and inequality on paths and literals', () {
    expect(eval('count == 1'), isTrue);
    expect(eval('count != 1'), isFalse);
    expect(eval("fields.dueDate == '2026-07-11'"), isTrue);
    expect(eval("title == 'Milch kaufen'"), isTrue);
    expect(eval('fields.completed == false'), isTrue);
    expect(eval('fields.missing == null'), isTrue);
  });

  test('numeric and string ordering', () {
    expect(eval('fields.priority > 1'), isTrue);
    expect(eval('fields.priority <= 2'), isTrue);
    expect(eval("fields.dueDate > '2026-07-10'"), isTrue);
  });

  test('boolean combinators, negation, parentheses', () {
    expect(eval("count == 1 && fields.dueDate != '2026-07-10'"), isTrue);
    expect(eval('count == 2 || fields.priority == 2'), isTrue);
    expect(eval('!(count == 2)'), isTrue);
    expect(eval('count == 1 && (count == 2 || fields.priority == 2)'), isTrue);
  });

  test('mismatched types compare unequal, ordering yields false', () {
    expect(eval("count == '1'"), isFalse);
    expect(eval("count > 'x'"), isFalse);
  });

  test('syntax errors throw FormatException', () {
    expect(() => eval('count =='), throwsFormatException);
    expect(() => eval('count == 1 &&'), throwsFormatException);
    expect(() => eval("title == 'unterminated"), throwsFormatException);
  });
}
