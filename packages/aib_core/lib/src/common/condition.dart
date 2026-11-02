import 'json.dart';

/// Tiny boolean expression evaluator over a JSON context.
///
/// Used for `partialCredit.condition` in task definitions (spec §5.1, e.g.
/// `count == 1 && fields.dueDate != '2026-07-10'`) and for `where(...)`
/// clauses of [SimpleQuery]-style state queries.
///
/// Grammar:
///   or    := and ('||' and)*
///   and   := unary ('&&' unary)*
///   unary := '!' unary | '(' or ')' | comparison
///   comparison := operand (('=='|'!='|'<='|'>='|'<'|'>') operand)?
///   operand    := 'string' | "string" | number | true | false | null | path
///   path       := ident ('.' ident)*   — resolved against the context map
class ConditionExpr {
  ConditionExpr._(this._tokens);

  final List<String> _tokens;
  int _pos = 0;

  /// Parses and evaluates [expression] against [context].
  /// Throws [FormatException] on syntax errors.
  static bool evaluate(String expression, JsonMap context) {
    final expr = ConditionExpr._(_tokenize(expression));
    final result = expr._parseOr(context);
    if (expr._pos != expr._tokens.length) {
      throw FormatException('Unexpected token "${expr._tokens[expr._pos]}" in: $expression');
    }
    return _truthy(result);
  }

  bool _parseOr(JsonMap ctx) {
    var value = _parseAnd(ctx);
    while (_peek() == '||') {
      _pos++;
      final rhs = _parseAnd(ctx);
      value = value || rhs;
    }
    return value;
  }

  bool _parseAnd(JsonMap ctx) {
    var value = _parseUnary(ctx);
    while (_peek() == '&&') {
      _pos++;
      final rhs = _parseUnary(ctx);
      value = value && rhs;
    }
    return value;
  }

  bool _parseUnary(JsonMap ctx) {
    if (_peek() == '!') {
      _pos++;
      return !_parseUnary(ctx);
    }
    if (_peek() == '(') {
      _pos++;
      final value = _parseOr(ctx);
      _expect(')');
      return value;
    }
    return _parseComparison(ctx);
  }

  bool _parseComparison(JsonMap ctx) {
    final left = _parseOperand(ctx);
    final op = _peek();
    if (op == null || !const {'==', '!=', '<', '<=', '>', '>='}.contains(op)) {
      return _truthy(left);
    }
    _pos++;
    final right = _parseOperand(ctx);
    switch (op) {
      case '==':
        return jsonEquals(left, right);
      case '!=':
        return !jsonEquals(left, right);
    }
    if (left is num && right is num) {
      return switch (op) {
        '<' => left < right,
        '<=' => left <= right,
        '>' => left > right,
        _ => left >= right,
      };
    }
    if (left is String && right is String) {
      final cmp = left.compareTo(right);
      return switch (op) {
        '<' => cmp < 0,
        '<=' => cmp <= 0,
        '>' => cmp > 0,
        _ => cmp >= 0,
      };
    }
    return false;
  }

  Object? _parseOperand(JsonMap ctx) {
    final token = _peek();
    if (token == null) throw const FormatException('Unexpected end of input');
    _pos++;
    if (token.startsWith("'") || token.startsWith('"')) {
      return token.substring(1, token.length - 1);
    }
    final number = num.tryParse(token);
    if (number != null) return number;
    return switch (token) {
      'true' => true,
      'false' => false,
      'null' => null,
      _ => _resolvePath(token, ctx),
    };
  }

  static Object? _resolvePath(String path, JsonMap ctx) {
    Object? current = ctx;
    for (final segment in path.split('.')) {
      if (current is Map) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }

  static bool _truthy(Object? value) => value == true;

  String? _peek() => _pos < _tokens.length ? _tokens[_pos] : null;

  void _expect(String token) {
    if (_peek() != token) {
      throw FormatException('Expected "$token", got "${_peek()}"');
    }
    _pos++;
  }

  static final _word = RegExp(r'[\p{L}\p{N}_.\-]+', unicode: true);

  static List<String> _tokenize(String input) {
    final tokens = <String>[];
    var i = 0;
    while (i < input.length) {
      final c = input[i];
      if (c == ' ' || c == '\t' || c == '\n') {
        i++;
        continue;
      }
      if (c == "'" || c == '"') {
        final end = input.indexOf(c, i + 1);
        if (end < 0) throw FormatException('Unterminated string in: $input');
        tokens.add(input.substring(i, end + 1));
        i = end + 1;
        continue;
      }
      final two = i + 1 < input.length ? input.substring(i, i + 2) : '';
      if (const {'==', '!=', '<=', '>=', '&&', '||'}.contains(two)) {
        tokens.add(two);
        i += 2;
        continue;
      }
      if (const {'(', ')', '!', '<', '>'}.contains(c)) {
        tokens.add(c);
        i++;
        continue;
      }
      // Letters of any script: German field names (`Größe`) are paths too.
      final match = _word.matchAsPrefix(input, i);
      if (match == null) {
        throw FormatException('Unexpected character "$c" in: $input');
      }
      tokens.add(match.group(0)!);
      i = match.end;
    }
    return tokens;
  }
}
