import 'package:flutter/foundation.dart';

enum TodoFilter { all, open, done }

/// Transient UI state (search text, filter). Lives outside the widgets so a
/// fixture reset can restore it deterministically together with the data
/// (spec §5.3 — the *complete* app state is part of the fixture contract).
final class UiState extends ChangeNotifier {
  String _searchQuery = '';
  TodoFilter _filter = .all;

  String get searchQuery => _searchQuery;
  TodoFilter get filter => _filter;

  /// [filter] as the `completed` argument of `TodoUseCases.findTodos` — the
  /// single definition shared by the list screen and the benchmark state
  /// queries, so a probe always sees exactly what the UI shows.
  bool? get completedFilter => switch (_filter) {
    .all => null,
    .open => false,
    .done => true,
  };

  set searchQuery(String value) {
    if (value == _searchQuery) return;
    _searchQuery = value;
    notifyListeners();
  }

  set filter(TodoFilter value) {
    if (value == _filter) return;
    _filter = value;
    notifyListeners();
  }

  void reset() {
    _searchQuery = '';
    _filter = .all;
    notifyListeners();
  }
}
