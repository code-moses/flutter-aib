import 'dart:convert';
import 'dart:io';

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'workspace_harness.dart';

/// Tests todo_v2's oracles, not an agent (A1): every task's reference
/// trajectory must succeed against the real workspace app, and stopping at
/// once must not.
///
/// Headless and key-free for every task that needs no judge. The rubric
/// tasks run with a judge config:
///
/// ```sh
/// AIB_JUDGE_CONFIG=../../suites/agents/ollama_judge.yaml \
///   fvm flutter test test/benchmark/v2_oracle_selftest_test.dart
/// ```
void main() {
  testWidgets('todo_v2 oracles', (tester) async {
    HttpOverrides.global = null; // the judge, when configured, is real HTTP
    final harness = await WorkspaceHarness.boot(tester);
    final suite = loadWorkspaceSuite();

    final judgePath = Platform.environment['AIB_JUDGE_CONFIG'];
    final judge = judgePath == null ? null : LlmJudge(client: LlmClientFactory.fromConfig(_yaml(judgePath)));
    bool needsJudge(TaskSpec task) => task.successCriteria.any(
      (c) =>
          c.type == CriterionTypes.artifactRubric &&
          // The suite-wide faithfulness criterion skips itself without an
          // artifact; a task whose *own* criteria need a judge cannot.
          c.config['skipWhenNoArtifact'] != true,
    );
    final tasks = [
      for (final task in suite.tasks)
        if (judge != null) task else if (!needsJudge(task)) _withoutClaimCheck(task),
    ];
    final selftest = OracleSelfTest(
      environment: harness.environment,
      references: ScriptedAgent.fromJson(_yaml(suitesPath('references/todo_v2.yaml'))),
      evaluator: EpisodeEvaluator(evaluators: EpisodeEvaluator.defaultEvaluators(judge: judge)),
    );
    final checks = (await tester.runAsync(() => selftest.run(tasks)))!;

    String score(OracleCheck check, String probe) => check.probe(probe)?.verdict.score.toStringAsFixed(2) ?? '—';
    for (final check in checks) {
      // ignore: avoid_print
      print(
        '${check.problems.isEmpty ? 'ok  ' : 'FAIL'}  ${check.task.id}  '
        'reference ${check.hasReference ? score(check, 'reference') : 'none'}'
        ' · done ${score(check, 'null.done')} · abort '
        '${score(check, 'null.abort')}',
      );
      for (final line in [...check.problems, ...check.warnings.map((w) => 'warn: $w')]) {
        // ignore: avoid_print
        print('        $line');
      }
    }
    // ignore: avoid_print
    print(
      '${suite.tasks.length - tasks.length} task(s) skipped (rubric without '
      'AIB_JUDGE_CONFIG).',
    );
    expect([for (final check in checks) ...check.problems.map((p) => '${check.task.id}: $p')], isEmpty);
  }, timeout: const Timeout(Duration(minutes: 30)));
}

JsonMap _yaml(String path) => asJsonMap(jsonDecode(jsonEncode(loadYaml(File(path).readAsStringSync()))));

/// [task] without the suite-wide faithfulness criterion, for the key-free
/// run: it judges the closing claim, which only a judge can do, and would
/// otherwise cap every reference at 0.67. The task's own oracles stay.
TaskSpec _withoutClaimCheck(TaskSpec task) => TaskSpec.fromJson({
  ...task.toJson(),
  'successCriteria': [
    for (final criterion in task.successCriteria)
      if (!(criterion.type == CriterionTypes.artifactRubric && criterion.config['skipWhenNoArtifact'] == true)) criterion.toJson(),
  ],
});
