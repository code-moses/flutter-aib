import 'package:flutter/material.dart';

import '../app/use_cases.dart';
import '../model/todo.dart';
import '../semantics_quality.dart';

/// Create/edit form. In the `bad` variant the fields carry no labels (only
/// visual hints inside the layout) and the save button is a generic "OK" —
/// functionally identical, semantically degraded.
class EditScreen extends StatefulWidget {
  const EditScreen({super.key, required this.useCases, required this.quality, this.existing});

  final TodoUseCases useCases;
  final SemanticsQuality quality;
  final Todo? existing;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _dueDate = TextEditingController(text: widget.existing?.dueDate);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  String? _error;

  bool get _good => widget.quality == .good;

  @override
  void dispose() {
    _title.dispose();
    _dueDate.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final existing = widget.existing;
      if (existing == null) {
        widget.useCases.createTodo(title: _title.text, dueDate: _dueDate.text, notes: _notes.text);
      } else {
        widget.useCases.updateTodo(existing.id, title: _title.text, dueDate: _dueDate.text, notes: _notes.text);
      }
      Navigator.of(context).pop();
    } on DomainError catch (e) {
      setState(() => _error = e.message);
    }
  }

  TextField _field(TextEditingController controller, String label) => TextField(
    controller: controller,
    decoration: _good ? InputDecoration(labelText: label) : const InputDecoration(),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'New todo' : 'Edit todo')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: .stretch,
          children: [
            _field(_title, 'Title'),
            const SizedBox(height: 8),
            _field(_dueDate, 'Due date (YYYY-MM-DD)'),
            const SizedBox(height: 8),
            _field(_notes, 'Notes'),
            const SizedBox(height: 16),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            FilledButton(onPressed: _save, child: Text(_good ? 'Save todo' : 'OK')),
          ],
        ),
      ),
    );
  }
}
