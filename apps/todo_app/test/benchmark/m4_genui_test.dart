/// M4 groundwork: the third strategy (generative UI) runs end-to-end
/// against the real todo app — GenUiAgent (scripted LLM) reads the real
/// data context, renders a surface as A2UI (ADR 0012), and the
/// artifactRubric oracle judges it from the persisted trace (deterministic
/// scripted judge; the live judge is LlmJudge, wired via
/// `aib evaluate --judge` / the live runner).
library;

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Deterministic judge that actually *checks* the surface — a rule-based
/// stand-in for the LLM judge, so M4 verification has known ground truth.
final class _RuleBasedJudge implements ArtifactJudge {
  static const openTitles = {
    'Steuererklärung abgeben',
    'Zahnarzttermin vereinbaren',
    'Projektbericht schreiben',
    'Blumen gießen',
    'Reifen wechseln',
    'Geschenk besorgen',
    'Wäsche waschen',
  };
  static const completedTitles = {'Einkauf erledigt', 'Anmeldung gesendet', 'Obsolete Aufgabe'};

  @override
  String get judgeId => 'rule-based-judge';

  @override
  Future<JudgeAnswer> judge(JudgeRequest request) async {
    final titles = <String>{};
    var sectionCount = 0;
    for (final message in request.artifact['messages'] as List? ?? const []) {
      final update = asJsonMap(message)['updateComponents'];
      if (update == null) continue;
      for (final raw in asJsonMap(update)['components'] as List? ?? const []) {
        final component = asJsonMap(raw);
        final id = component['id'] as String;
        if (component['component'] == 'Card' && id.startsWith('section_')) {
          sectionCount++;
        }
        if (id.startsWith('item_')) titles.add(component['text'] as String);
      }
    }
    return JudgeAnswer(
      answers: {
        'all_open_tasks': titles.containsAll(openTitles),
        'no_completed_tasks': titles.intersection(completedTitles).isEmpty,
        'grouped_by_due': sectionCount >= 2,
        'nothing_invented': titles.difference({...openTitles, ...completedTitles}).isEmpty,
      },
    );
  }
}

/// The suite pins the production judge model (§5.1) so that no unintended
/// LLM can score real results. These tests validate the *oracle mechanics*
/// with a deterministic rule-based judge, which is a legitimate deviation —
/// so they state it here, on an explicitly unpinned copy of the task, rather
/// than the framework offering a general escape hatch from pinning.
TaskSpec withoutJudgePin(TaskSpec task) {
  final json = task.toJson();
  for (final criterion in json['successCriteria'] as List) {
    (criterion as Map).remove('judgeModel');
  }
  return TaskSpec.fromJson(json);
}

/// The dashboard a well-behaved genui agent would produce for the fixture.
///
/// Component ids follow a convention the rule-based judge above reads —
/// `section_*` for a section's Card, `item_*` for a task's Text. A2UI has no
/// notion of a section, so a deterministic judge needs one; naming it here is
/// more honest than a heuristic that guesses which Text was a heading. The
/// LLM judge the suite pins needs no such help, which is the point of it.
const _dashboardSections = <({String heading, List<String> items})>[
  (heading: 'Überfällig', items: ['Reifen wechseln', 'Blumen gießen']),
  (heading: 'Diese Woche', items: ['Steuererklärung abgeben', 'Projektbericht schreiben']),
  (heading: 'Später', items: ['Zahnarzttermin vereinbaren', 'Geschenk besorgen']),
  (heading: 'Ohne Datum', items: ['Wäsche waschen']),
];

List<JsonMap> _dashboardMessages([List<({String heading, List<String> items})> sections = _dashboardSections]) {
  final components = <JsonMap>[
    {
      'id': 'root',
      'component': 'Column',
      'children': [for (var i = 0; i < sections.length; i++) 'section_$i'],
    },
  ];
  for (final (i, section) in sections.indexed) {
    components.addAll([
      {'id': 'section_$i', 'component': 'Card', 'child': 'body_$i'},
      {
        'id': 'body_$i',
        'component': 'Column',
        'children': ['heading_$i', for (var j = 0; j < section.items.length; j++) 'item_${i}_$j'],
      },
      {'id': 'heading_$i', 'component': 'Text', 'text': section.heading},
      for (final (j, item) in section.items.indexed) {'id': 'item_${i}_$j', 'component': 'Text', 'text': item},
    ]);
  }
  return [
    {
      'version': 'v0.9',
      'createSurface': {'surfaceId': 'dashboard', 'catalogId': GenUiCatalog.basicCatalogId},
    },
    {
      'version': 'v0.9',
      'updateComponents': {'surfaceId': 'dashboard', 'components': components},
    },
  ];
}

Future<({EpisodeRecord record, EpisodeTrace trace})> _runGenUi(
  WidgetTester tester, {
  required List<JsonMap> messages,
  required TaskSpec task,
  ArtifactJudge? judge,
}) async {
  final harness = await TodoHarness.boot(tester);
  final agent = GenUiAgent(
    client: FakeLlmClient(
      responses: [
        FakeLlmClient.calls([
          ('render_ui', {'messages': messages}),
        ]),
        FakeLlmClient.calls([
          ('done', {'summary': 'dashboard rendered'}),
        ]),
      ],
    ),
  );
  final result = await BenchmarkEngine().runEpisode(task: task, agent: agent, environment: harness.environment, meta: episodeMeta(task.id, 'genui'));
  final trace = TraceCodec.decode(TraceCodec.encode(result.trace));
  final evaluation = RunEvaluation(
    evaluator: EpisodeEvaluator(evaluators: EpisodeEvaluator.defaultEvaluators(judge: judge ?? _RuleBasedJudge())),
  );
  final record = await evaluation.evaluateEpisode(trace, task);
  return (record: record, trace: trace);
}

void main() {
  final suite = loadTodoSuite();
  final task = withoutJudgePin(suite.taskById('todo.dashboard.generate')!);

  testWidgets('GenUiAgent renders a judged-successful dashboard '
      'from the real data context', (tester) async {
    final handle = tester.ensureSemantics();
    final (:record, :trace) = await _runGenUi(tester, messages: _dashboardMessages(), task: task);

    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? record.verdict.details.toString());
    expect(record.metrics['action_count'], 1, reason: 'genui = one render action');
    expect(record.metrics['observation_count'], 1, reason: 'bootstrap data.context');
    expect(record.metrics['path_efficiency'], 1.0);

    // The agent really saw the app data (all 10 todos) before rendering.
    final contextExchange = trace.exchanges().firstWhere((x) => x.key == 'data.context');
    final todos = asJsonMap(contextExchange.result!.data['payload'])['todos'] as List;
    expect(todos, hasLength(10));
    handle.dispose();
  });

  testWidgets('incomplete dashboard -> weighted partial via rubric majority', (tester) async {
    final handle = tester.ensureSemantics();
    // Drop the "Ohne Datum" section -> all_open_tasks (weight 2) fails,
    // grouping/no-completed/nothing-invented still pass -> 3/5 of weight.
    final incomplete = _dashboardMessages(_dashboardSections.sublist(0, _dashboardSections.length - 1));

    final (:record, trace: _) = await _runGenUi(tester, messages: incomplete, task: task);
    expect(record.verdict.type, VerdictType.partial);
    expect(record.verdict.score, closeTo(3 / 5, 1e-9));
    handle.dispose();
  });

  testWidgets('without a judge the rubric task fails with instructive '
      'reason (never silently green)', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final agent = GenUiAgent(
      client: FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            ('render_ui', {'messages': _dashboardMessages()}),
          ]),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      ),
    );
    final result = await BenchmarkEngine().runEpisode(
      task: task,
      agent: agent,
      environment: harness.environment,
      meta: episodeMeta(task.id, 'genui'),
    );
    final record = await RunEvaluation().evaluateEpisode(result.trace, task);
    expect(record.verdict.type, VerdictType.failure);
    expect(record.verdict.reason, contains('requires a judge'));
    handle.dispose();
  });
}
