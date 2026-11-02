import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/src/app/use_cases.dart';
import 'package:todo_app/src/data/todo_store.dart';

void main() {
  late TodoStore store;
  late TodoUseCases useCases;

  setUp(() {
    store = TodoStore()
      ..seed(const {
        'db': {
          'todos': [
            {'id': 't-1', 'title': 'Existing', 'completed': false},
          ],
        },
      });
    useCases = TodoUseCases(store);
  });

  test('createTodo validates title and date format', () {
    expect(() => useCases.createTodo(title: '  '), throwsA(isA<DomainError>()));
    expect(() => useCases.createTodo(title: 'X', dueDate: '10.07.2026'), throwsA(isA<DomainError>()));
    final id = useCases.createTodo(title: ' X ', dueDate: '2026-07-10');
    final todo = store.byId(id)!;
    expect(todo.title, 'X');
    expect(todo.dueDate, '2026-07-10');
    expect(todo.completed, isFalse);
  });

  test('update, toggle, delete resolve targets and mutate the store', () {
    useCases.updateTodo('t-1', dueDate: '2026-07-20');
    expect(store.byId('t-1')!.dueDate, '2026-07-20');
    expect(useCases.toggleComplete('t-1'), isTrue);
    expect(store.byId('t-1')!.completed, isTrue);
    useCases.deleteTodo('t-1');
    expect(store.byId('t-1'), isNull);
    expect(() => useCases.deleteTodo('t-1'), throwsA(isA<DomainError>()));
  });

  test('resolveTarget by exact title; find by substring and state', () {
    expect(useCases.resolveTarget(title: 'Existing').id, 't-1');
    expect(() => useCases.resolveTarget(title: 'Nope'), throwsA(isA<DomainError>()));
    useCases.createTodo(title: 'Another thing');
    expect(useCases.findTodos(query: 'thing'), hasLength(1));
    expect(useCases.findTodos(completed: false), hasLength(2));
  });

  test('seed restores byte-identical state (fingerprint contract)', () {
    final before = store.fingerprint();
    useCases.createTodo(title: 'Dirty');
    useCases.toggleComplete('t-1');
    expect(store.fingerprint(), isNot(before));
    store.seed(const {
      'db': {
        'todos': [
          {'id': 't-1', 'title': 'Existing', 'completed': false},
        ],
      },
    });
    expect(store.fingerprint(), before);
  });
}
