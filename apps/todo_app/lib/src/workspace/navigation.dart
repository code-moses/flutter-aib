import 'package:flutter/foundation.dart';

/// One screen of the workspace. The stack of these is app state, not widget
/// state: the UI renders it (Navigator pages) and the intents change it, so
/// a tap and an intent move through the same object, and the set of
/// capabilities in scope is a function of [WorkspaceNav.top].
sealed class Screen {
  const Screen();

  String get name;

  /// Stable per screen *instance* kind and target — a page key.
  String get key;

  Map<String, Object?> toRow();
}

final class HomeScreenRef extends Screen {
  const HomeScreenRef();
  @override
  String get name => 'home';
  @override
  String get key => 'home';
  @override
  Map<String, Object?> toRow() => {'screen': name};
}

final class ProjectScreenRef extends Screen {
  const ProjectScreenRef(this.projectId);
  final String projectId;
  @override
  String get name => 'project';
  @override
  String get key => 'project:$projectId';
  @override
  Map<String, Object?> toRow() => {'screen': name, 'projectId': projectId};
}

final class TodoScreenRef extends Screen {
  const TodoScreenRef(this.todoId);
  final String todoId;
  @override
  String get name => 'todo';
  @override
  String get key => 'todo:$todoId';
  @override
  Map<String, Object?> toRow() => {'screen': name, 'todoId': todoId};
}

final class SettingsScreenRef extends Screen {
  const SettingsScreenRef();
  @override
  String get name => 'settings';
  @override
  String get key => 'settings';
  @override
  Map<String, Object?> toRow() => {'screen': name};
}

final class StatsScreenRef extends Screen {
  const StatsScreenRef();
  @override
  String get name => 'stats';
  @override
  String get key => 'stats';
  @override
  Map<String, Object?> toRow() => {'screen': name};
}

enum ListFilter { all, open, done }

/// The screen stack plus the list view state — the transient half of the
/// app state a fixture reset must restore (spec §5.3).
final class WorkspaceNav extends ChangeNotifier {
  final List<Screen> _stack = [const HomeScreenRef()];
  ListFilter _projectFilter = .all;
  String _search = '';

  List<Screen> get stack => List.unmodifiable(_stack);
  Screen get top => _stack.last;
  ListFilter get projectFilter => _projectFilter;
  String get search => _search;

  /// Opening a screen that is already on the stack returns to it rather than
  /// stacking a second copy.
  void open(Screen screen) {
    final existing = _stack.indexWhere((s) => s.key == screen.key);
    if (existing >= 0) {
      _stack.removeRange(existing + 1, _stack.length);
    } else {
      if (screen is ProjectScreenRef) _projectFilter = .all;
      _stack.add(screen);
    }
    notifyListeners();
  }

  /// One screen back; false on the home screen, which has nothing behind it.
  bool back() {
    if (_stack.length <= 1) return false;
    _stack.removeLast();
    notifyListeners();
    return true;
  }

  /// Called when the Navigator removed a page by itself (system back, the
  /// app bar's back button).
  void removed(String key) {
    final index = _stack.indexWhere((s) => s.key == key);
    if (index <= 0) return;
    _stack.removeRange(index, _stack.length);
    notifyListeners();
  }

  /// Drops every screen showing [test] — a deleted todo, an archived project.
  void closeWhere(bool Function(Screen) test) {
    final index = _stack.indexWhere(test);
    if (index <= 0) return;
    _stack.removeRange(index, _stack.length);
    notifyListeners();
  }

  set projectFilter(ListFilter value) {
    if (value == _projectFilter) return;
    _projectFilter = value;
    notifyListeners();
  }

  set search(String value) {
    if (value == _search) return;
    _search = value;
    notifyListeners();
  }

  void reset() {
    _stack
      ..clear()
      ..add(const HomeScreenRef());
    _projectFilter = .all;
    _search = '';
    notifyListeners();
  }
}
