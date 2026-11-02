import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Small probe app: a labelled button, a text field and duplicate labels —
/// enough to verify serialization, pruning, addressing and actions.
class _ProbeApp extends StatefulWidget {
  const _ProbeApp();

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  int taps = 0;
  final controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Text('Taps: $taps'),
            ElevatedButton(onPressed: () => setState(() => taps++), child: const Text('Increment')),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const Text('Twin'),
            const Text('Twin'),
          ],
        ),
      ),
    );
  }
}

/// A field that reports its value to the form only when it loses focus —
/// the shape SYSco Mobile+'s `DataMaskTextField` has, and a common one.
///
/// It is the whole point of the commit test below: with this widget, a
/// `setText` that leaves the field focused changes the screen and nothing
/// else, and every check available from inside the bridge still passes.
class _BlurCommitApp extends StatefulWidget {
  const _BlurCommitApp({required this.onCommit});

  final ValueChanged<String> onCommit;

  @override
  State<_BlurCommitApp> createState() => _BlurCommitAppState();
}

class _BlurCommitAppState extends State<_BlurCommitApp> {
  final controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Focus(
          canRequestFocus: false,
          onFocusChange: (hasFocus) {
            if (!hasFocus) widget.onCommit(controller.text);
          },
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Subject'),
          ),
        ),
      ),
    );
  }
}

void main() {
  Future<FlutterEnvironment> pumpProbe(WidgetTester tester) async {
    await tester.pumpWidget(const _ProbeApp());
    final environment = FlutterEnvironment(environmentId: 'probe', settle: () async => tester.pumpAndSettle());
    final bridge = SemanticsBridge()..install(environment);
    addTearDown(bridge.dispose);
    await tester.pumpAndSettle();
    return environment;
  }

  testWidgets('semantics.tree serializes pruned, labelled nodes', (tester) async {
    final handle = tester.ensureSemantics();
    final environment = await pumpProbe(tester);

    final result = await environment.handle(const Envelope(key: 'semantics.tree', kind: .observe));
    expect(result.status, EnvelopeStatus.ok);
    expect(result.payload['nodeCount'], greaterThan(0));

    final flat = _flatten(result.payload['tree'] as List);
    final labels = flat.map((n) => n['label']).toList();
    expect(labels, contains('Increment'));
    expect(labels, contains('Taps: 0'));
    expect(labels.where((l) => l == 'Twin'), hasLength(2));
    final button = flat.firstWhere((n) => n['label'] == 'Increment');
    expect(button['actions'], contains('tap'));
    expect(button['flags'], contains('isButton'));
    expect(button['id'], isA<int>());

    handle.dispose();
  });

  testWidgets('semantics.tap by label changes app state', (tester) async {
    final handle = tester.ensureSemantics();
    final environment = await pumpProbe(tester);

    final result = await environment.handle(const Envelope(key: 'semantics.tap', kind: .act, payload: {'label': 'Increment'}));
    expect(result.status, EnvelopeStatus.ok);
    expect(find.text('Taps: 1'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('semantics.tap by nodeId works', (tester) async {
    final handle = tester.ensureSemantics();
    final environment = await pumpProbe(tester);

    final tree = await environment.handle(const Envelope(key: 'semantics.tree', kind: .observe));
    final button = _flatten(tree.payload['tree'] as List).firstWhere((n) => n['label'] == 'Increment');
    final result = await environment.handle(Envelope(key: 'semantics.tap', kind: .act, payload: {'nodeId': button['id']}));
    expect(result.status, EnvelopeStatus.ok);
    expect(find.text('Taps: 1'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('semantics.setText fills the text field', (tester) async {
    final handle = tester.ensureSemantics();
    final environment = await pumpProbe(tester);

    final result = await environment.handle(
      const Envelope(key: 'semantics.setText', kind: .act, payload: {'label': 'Title', 'text': 'Milch kaufen'}),
    );
    expect(result.status, EnvelopeStatus.ok, reason: result.error?.message ?? '');
    expect(find.text('Milch kaufen'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('semantics.setText commits the edit to the app, not only the '
      'screen', (tester) async {
    final handle = tester.ensureSemantics();
    final committed = <String>[];
    await tester.pumpWidget(_BlurCommitApp(onCommit: committed.add));
    final environment = FlutterEnvironment(environmentId: 'probe', settle: () async => tester.pumpAndSettle());
    final bridge = SemanticsBridge()..install(environment);
    addTearDown(bridge.dispose);
    await tester.pumpAndSettle();

    final result = await environment.handle(
      const Envelope(key: 'semantics.setText', kind: .act, payload: {'label': 'Subject', 'text': 'Wartung Heizung'}),
    );

    expect(result.status, EnvelopeStatus.ok, reason: result.error?.message);
    expect(find.text('Wartung Heizung'), findsOneWidget);
    // The assertion that matters. Without the focus release the text is on
    // screen, the tree reports it, the result is `ok` — and this list is
    // empty, which is what cost the first n=5 SYSco run all six form tasks.
    expect(committed, ['Wartung Heizung']);
    expect(result.payload['committed'], isTrue);

    handle.dispose();
  });

  testWidgets('structured errors: not_found and ambiguous_label', (tester) async {
    final handle = tester.ensureSemantics();
    final environment = await pumpProbe(tester);

    final missing = await environment.handle(const Envelope(key: 'semantics.tap', kind: .act, payload: {'label': 'No such button'}));
    expect(missing.error?.code, 'not_found');

    // Duplicate labels but no tap action -> still not_found for tap;
    // setText on 'Twin' is equally unsupported. Use tree to prove both
    // Twin nodes exist, then address one by nodeId with a wrong action.
    final tree = await environment.handle(const Envelope(key: 'semantics.tree', kind: .observe));
    final twin = _flatten(tree.payload['tree'] as List).firstWhere((n) => n['label'] == 'Twin');
    final wrongAction = await environment.handle(Envelope(key: 'semantics.tap', kind: .act, payload: {'nodeId': twin['id']}));
    expect(wrongAction.error?.code, 'unsupported_action');

    handle.dispose();
  });

  testWidgets('structuralTree strips ids and rects for snapshot comparison', (tester) async {
    final handle = tester.ensureSemantics();
    final environment = await pumpProbe(tester);

    final tree = await environment.handle(const Envelope(key: 'semantics.tree', kind: .observe));
    final structural = structuralTree(tree.payload['tree']);
    final flat = _flatten(structural as List);
    expect(flat.every((n) => !n.containsKey('id') && !n.containsKey('rect')), isTrue);

    handle.dispose();
  });

  testWidgets('a node reports where it sits, not its own origin', (tester) async {
    final handle = tester.ensureSemantics();
    final environment = await pumpProbe(tester);

    final tree = await environment.handle(const Envelope(key: 'semantics.tree', kind: .observe));
    final flat = _flatten(tree.payload['tree'] as List);
    final button = flat.firstWhere((n) => n['label'] == 'Increment');
    final rect = button['rect'] as Map;
    final expected = tester.getRect(find.byType(ElevatedButton));

    // Two ways to be wrong, and both have shipped: `node.rect` alone puts
    // every element at the origin, and composing the root transform as well
    // scales by devicePixelRatio. The published rect has to be the same
    // logical space as `pointer.tap` and the screenshot.
    expect(rect['left'], closeTo(expected.left, 0.5));
    expect(rect['top'], closeTo(expected.top, 0.5));
    expect(rect['width'], closeTo(expected.width, 0.5));
    expect(rect['height'], closeTo(expected.height, 0.5));

    handle.dispose();
  });
}

List<JsonMap> _flatten(List<Object?> tree) {
  final result = <JsonMap>[];
  for (final node in tree.map(asJsonMap)) {
    result.add(node);
    if (node['children'] is List) {
      result.addAll(_flatten(node['children'] as List));
    }
  }
  return result;
}
