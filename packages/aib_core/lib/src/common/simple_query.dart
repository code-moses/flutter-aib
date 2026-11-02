import 'condition.dart';
import 'json.dart';

/// Interpreter for the state-query convention of the reference environments:
///
///   `db.todos`                                -> all rows under that path
///   `db.todos.where(title == 'Milch kaufen')` -> filtered rows
///
/// A convention of the adapters, not a core contract: environments may
/// interpret `StateQuery.query` however they want.
class SimpleQuery {
  SimpleQuery._(this.path, this.whereExpression);

  /// Dot-separated path into the state document.
  final List<String> path;

  /// Optional `where(...)` filter, evaluated per row via [ConditionExpr].
  final String? whereExpression;

  static final _wherePattern = RegExp(r'^(.*?)\.where\((.*)\)\s*$');

  static SimpleQuery parse(String query) {
    final match = _wherePattern.firstMatch(query.trim());
    if (match != null) {
      return SimpleQuery._(match.group(1)!.split('.'), match.group(2));
    }
    return SimpleQuery._(query.trim().split('.'), null);
  }

  /// Runs the query against [root]. Rows are expected to be a JSON list of
  /// objects at [path]; a single object counts as one row.
  ({int count, List<JsonMap> items}) run(JsonMap root) {
    Object? current = root;
    for (final segment in path) {
      if (current is Map) {
        current = current[segment];
      } else {
        current = null;
        break;
      }
    }
    var rows = switch (current) {
      List() => current.map(asJsonMap).toList(),
      Map() => [asJsonMap(current)],
      _ => <JsonMap>[],
    };
    final where = whereExpression;
    if (where != null) {
      rows = rows.where((row) => ConditionExpr.evaluate(where, row)).toList();
    }
    return (count: rows.length, items: rows);
  }
}
