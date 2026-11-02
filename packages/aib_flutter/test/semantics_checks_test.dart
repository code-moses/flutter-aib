import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A toggle whose label changes when tapped, a disabled field, and a column
/// long enough that its last buttons start below the fold.
class _ChecksApp extends StatefulWidget {
  const _ChecksApp();

  @override
  State<_ChecksApp> createState() => _ChecksAppState();
}

class _ChecksAppState extends State<_ChecksApp> {
  var running = false;
  final tapped = <int>[];

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            ElevatedButton(onPressed: () => setState(() => running = !running), child: Text(running ? 'Stop' : 'Start')),
            const TextField(enabled: false, decoration: InputDecoration(labelText: 'Locked')),
            for (var i = 0; i < 40; i++)
              SizedBox(
                height: 80,
                child: TextButton(onPressed: () => setState(() => tapped.add(i)), child: Text('Row $i')),
              ),
          ],
        ),
      ),
    ),
  );
}

List<JsonMap> _flatten(List<Object?> nodes) => [
  for (final raw in nodes) ...[raw! as JsonMap, ..._flatten((raw as JsonMap)['children'] as List? ?? const [])],
];

void main() {
  Future<(FlutterEnvironment, SemanticsBridge)> pump(WidgetTester tester, SemanticsBridge bridge) async {
    await tester.pumpWidget(const _ChecksApp());
    final environment = FlutterEnvironment(environmentId: 'checks', settle: () async => tester.pumpAndSettle());
    bridge.install(environment);
    addTearDown(bridge.dispose);
    await tester.pumpAndSettle();
    return (environment, bridge);
  }

  Future<int> idOf(FlutterEnvironment environment, String label) async {
    final tree = await environment.handle(const Envelope(key: 'semantics.tree', kind: .observe));
    return _flatten(tree.payload['tree'] as List).firstWhere((n) => n['label'] == label)['id'] as int;
  }

  Envelope tap(int id) => Envelope(key: 'semantics.tap', kind: .act, payload: {'nodeId': id});

  testWidgets('a node that changed since it was observed is a stale_ref, not a tap on whatever it is now', (tester) async {
    final handle = tester.ensureSemantics();
    final (environment, bridge) = await pump(tester, SemanticsBridge(staleRefCheck: true));
    expect(bridge.options, {'staleRefCheck': true});

    final id = await idOf(environment, 'Start');
    expect((await environment.handle(tap(id))).status, EnvelopeStatus.ok);
    expect(find.text('Stop'), findsOneWidget);

    final again = await environment.handle(tap(id));
    expect(again.status, EnvelopeStatus.failed);
    expect(again.error!.code, 'stale_ref');
    expect(again.error!.message, contains('was "Start", now "Stop"'));
    expect(find.text('Stop'), findsOneWidget, reason: 'nothing ran');

    // Observed again, the id is a reference to the new label.
    await idOf(environment, 'Stop');
    expect((await environment.handle(tap(id))).status, EnvelopeStatus.ok);
    handle.dispose();
  });

  testWidgets('without the check the same id is tapped whatever it now is', (tester) async {
    final handle = tester.ensureSemantics();
    final (environment, _) = await pump(tester, SemanticsBridge());
    final id = await idOf(environment, 'Start');
    await environment.handle(tap(id));
    expect((await environment.handle(tap(id))).status, EnvelopeStatus.ok);
    expect(find.text('Start'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the actionability gate refuses a disabled field and scrolls an off-screen node into view', (tester) async {
    final handle = tester.ensureSemantics();
    final (environment, _) = await pump(tester, SemanticsBridge(actionabilityGate: true));

    final locked = await environment.handle(const Envelope(key: 'semantics.setText', kind: .act, payload: {'label': 'Locked', 'text': 'x'}));
    expect(locked.error?.code, 'disabled');

    final state = tester.state<_ChecksAppState>(find.byType(_ChecksApp));
    final below = await environment.handle(const Envelope(key: 'semantics.tap', kind: .act, payload: {'label': 'Row 30'}));
    expect(below.status, EnvelopeStatus.ok, reason: below.error?.message);
    expect(state.tapped, [30]);
    handle.dispose();
  });

  testWidgets('candidate actions list what is on screen to act on, in reading order', (tester) async {
    final handle = tester.ensureSemantics();
    final (environment, _) = await pump(tester, SemanticsBridge(candidateActions: true));
    final tree = await environment.handle(const Envelope(key: 'semantics.tree', kind: .observe));
    final candidates = [for (final c in tree.payload['candidates'] as List) c as JsonMap];
    expect(candidates.first['id'], isA<int>());
    expect((candidates.first['action'], candidates.first['label']), ('tap', 'Start'));
    final labels = [for (final c in candidates) c['label']];
    expect(labels, contains('Row 0'));
    expect(labels, isNot(contains('Row 39')), reason: 'off screen');
    expect(labels.indexOf('Row 0'), lessThan(labels.indexOf('Row 1')));
    handle.dispose();
  });

  testWidgets('an enricher adds its facts under its name, only where it answers', (tester) async {
    final handle = tester.ensureSemantics();
    final (environment, bridge) = await pump(
      tester,
      SemanticsBridge(
        enrichers: {
          'row': (node) {
            final label = node.getSemanticsData().label;
            return label.startsWith('Row ') ? {'index': int.parse(label.substring(4))} : null;
          },
        },
      ),
    );
    expect(bridge.options, {
      'enrichers': ['row'],
    });
    final tree = await environment.handle(const Envelope(key: 'semantics.tree', kind: .observe));
    final nodes = _flatten(tree.payload['tree'] as List);
    expect(nodes.firstWhere((n) => n['label'] == 'Row 3')['row'], {'index': 3});
    expect(nodes.firstWhere((n) => n['label'] == 'Start'), isNot(contains('row')));
    handle.dispose();
  });

  testWidgets('frame attribution reports the frames and rebuilds of an action as a resource sample', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const _ChecksApp());
    final frames = FrameAttribution();
    addTearDown(frames.stop);
    final environment = FlutterEnvironment(environmentId: 'checks', settle: () async => tester.pumpAndSettle(), frames: frames);
    final bridge = SemanticsBridge()..install(environment);
    addTearDown(bridge.dispose);
    await tester.pumpAndSettle();
    await environment.sampleResources(); // what booting cost

    await environment.handle(const Envelope(key: 'semantics.tap', kind: .act, payload: {'label': 'Start'}));
    final sample = await environment.sampleResources();
    // flutter_test reports no FrameTimings; the rebuilds are what it can see.
    expect(sample['rebuilt'], greaterThan(0));
    expect((sample['rebuiltTypes'] as Map), hasLength(lessThanOrEqualTo(10)));
    expect((sample['rebuiltTypes'] as Map).values.first, greaterThanOrEqualTo((sample['rebuiltTypes'] as Map).values.last));
    expect(await environment.sampleResources(), isEmpty, reason: 'nothing happened since');
    expect(await FlutterEnvironment(environmentId: 'off').sampleResources(), isEmpty);
    handle.dispose();
  });
}
