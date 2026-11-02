/// M3 live benchmark runner: semantics vs intent vs genui agents against a
/// real LLM on the todo_v1 suite, producing a complete run directory
/// (run_manifest.json, traces, verdicts, metrics.csv, reports).
///
/// Gated on environment variables so CI stays key-free and free of cost.
/// The model is configured declaratively — same file format the CLI uses:
///
///   AIB_LLM_CONFIG=../../suites/agents/ollama.yaml \
///     flutter test test/benchmark/live/m3_live_benchmark_test.dart
///
/// or purely from the environment:
///
///   AIB_LLM_PROVIDER=anthropic AIB_LLM_MODEL=claude-sonnet-4-6 \
///     flutter test test/benchmark/live/m3_live_benchmark_test.dart
///
/// Environment variables override single fields of the config file, so one
/// pinned file plus `AIB_LLM_MODEL=…` is enough for a cross-model run
/// (§6.4 `cross_model_variance`).
///
/// Optional: AIB_REPS (default 5 — the M3 criterion), AIB_LLM_BASE_URL,
/// AIB_TASKS (comma-separated task-id filter for cheap smoke runs),
/// AIB_AGENTS (default semantics,intent,genui), AIB_JUDGE_CONFIG (judge for
/// artifactRubric tasks; defaults to the agent model), AIB_OUT (run
/// directory; an existing one is resumed), AIB_SEMANTICS_QUALITY=good|bad
/// (degraded build variant, §6.4).
library;

import 'dart:convert';
import 'dart:io';

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/src/semantics_quality.dart';
import 'package:yaml/yaml.dart';

import '../harness.dart';

/// LLM config from a YAML file (as in `suites/agents/*.yaml`), with single
/// fields overridable from the environment: `AIB_LLM_CONFIG` +
/// `AIB_LLM_{PROVIDER,MODEL,BASE_URL}` for the agents, `AIB_JUDGE_CONFIG` +
/// `AIB_JUDGE_{PROVIDER,MODEL,BASE_URL}` for the judge. The two never share
/// overrides: a cross-model run (`AIB_LLM_MODEL=…`) must not silently swap
/// the pinned judge as well.
JsonMap _llmConfig({String prefix = 'AIB_LLM'}) {
  final env = Platform.environment;
  final path = env['${prefix}_CONFIG'];
  return {
    if (path != null) ...asJsonMap(jsonDecode(jsonEncode(loadYaml(File(path).readAsStringSync())))),
    if (env['${prefix}_PROVIDER'] != null) 'provider': env['${prefix}_PROVIDER'],
    if (env['${prefix}_MODEL'] != null) 'model': env['${prefix}_MODEL'],
    if (env['${prefix}_BASE_URL'] != null) 'baseUrl': env['${prefix}_BASE_URL'],
  };
}

TaskSuite _filtered(TaskSuite suite, bool Function(TaskSpec) keep) => TaskSuite(
  name: suite.name,
  schema: suite.schema,
  defaultRepetitions: suite.defaultRepetitions,
  tasks: [
    for (final task in suite.tasks)
      if (keep(task)) task,
  ],
  sourcePath: suite.sourcePath,
  sourceHash: suite.sourceHash,
);

/// Judge models the suite pins for its `artifactRubric` criteria (§5.1).
Set<String> _pinnedJudges(TaskSpec task) => {
  for (final criterion in task.successCriteria)
    if (criterion.type == CriterionTypes.artifactRubric) ?JudgeProvenance.pinnedModelOf(criterion),
};

void main() {
  final config = _llmConfig();
  final live = config['provider'] != null && config['model'] != null;

  testWidgets('live-run harness mechanics: engine + real async agent under runAsync', (tester) async {
    // Proves the harness used for live runs works: a FakeLlmClient with a
    // real timer forces genuinely asynchronous completion, exactly like a
    // real HTTP call would.
    final handle = tester.ensureSemantics();
    final suite = loadTodoSuite();
    final harness = await TodoHarness.boot(tester);
    final agent = IntentAgent(
      client: FakeLlmClient(
        delay: const Duration(milliseconds: 20),
        responses: [
          // Catalog schema 3: nothing is callable until it is described.
          FakeLlmClient.calls([
            (
              'describe_intents',
              {
                'names': ['todo.create'],
              },
            ),
          ]),
          FakeLlmClient.calls([
            ('intent_todo_create', {'title': 'Milch kaufen', 'dueDate': '2026-07-10'}),
          ]),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      ),
    );
    final task = suite.taskById('todo.create.simple')!;
    final result = await tester.runAsync(
      () => BenchmarkEngine().runEpisode(task: task, agent: agent, environment: harness.environment, meta: episodeMeta(task.id, 'intent')),
    );
    final record = await RunEvaluation().evaluateEpisode(result!.trace, task);
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    expect(record.metrics['llm_latency_ms'], greaterThanOrEqualTo(60), reason: '3 LLM calls × 20ms real delay must show up in telemetry');
    handle.dispose();
  });

  testWidgets(
    'M3/M4 live: semantics vs intent vs genui on todo_v1 (n=AIB_REPS)',
    (tester) async {
      HttpOverrides.global = null; // flutter_test blocks real HTTP by default
      final handle = tester.ensureSemantics();
      final env = Platform.environment;

      LlmClient makeClient() => LlmClientFactory.fromConfig(config);
      // Judge defaults to the agent model — visible in every report as
      // judgeAgentOverlap ("did the judge grade its own homework?").
      final judgeOverrides = _llmConfig(prefix: 'AIB_JUDGE');
      final judgeConfig = judgeOverrides.isEmpty ? config : judgeOverrides;
      final judgeModel = judgeConfig['model'] as String;

      var suite = loadTodoSuite();
      final taskFilter = env['AIB_TASKS']?.split(',');
      if (taskFilter != null) {
        suite = _filtered(suite, (task) => taskFilter.contains(task.id));
      }
      // §5.1: the suite pins the judge model, and scoring a rubric with any
      // other judge is refused. A run whose judge does not match therefore
      // cannot evaluate those tasks — they are dropped from *execution* too,
      // so the report never contains an episode that only looks like a
      // failure because nobody was allowed to grade it. Execute them in a
      // second run with the pinned judge (P6: evaluation is a separate pass).
      final unjudgeable = suite.tasks.where((task) => _pinnedJudges(task).any((pin) => !judgeModel.contains(pin))).map((task) => task.id).toList();
      if (unjudgeable.isNotEmpty) {
        suite = _filtered(suite, (task) => !unjudgeable.contains(task.id));
        // ignore: avoid_print
        print(
          'SKIP ${unjudgeable.join(', ')}: suite pins another judge model '
          'than "$judgeModel" — run these with the pinned judge.',
        );
      }
      expect(suite.tasks, isNotEmpty, reason: 'no task left to run');

      final reps = int.tryParse(env['AIB_REPS'] ?? '') ?? 5;
      final selected = (env['AIB_AGENTS'] ?? 'semantics,intent,genui').split(',');
      final agents = <String, BenchmarkAgent>{
        if (selected.contains('semantics')) 'semantics': SemanticsAgent(client: makeClient()),
        if (selected.contains('intent')) 'intent': IntentAgent(client: makeClient()),
        if (selected.contains('genui')) 'genui': GenUiAgent(client: makeClient()),
      };
      expect(agents, isNotEmpty, reason: 'AIB_AGENTS selected no known agent');

      // §6.4 `semantics_degradation_delta`: the same suite against the
      // degraded build variant is a second run, compared via `aib compare`.
      final harness = await TodoHarness.boot(
        tester,
        quality: env['AIB_SEMANTICS_QUALITY'] == 'bad' ? SemanticsQuality.bad : SemanticsQuality.good,
        semantics: semanticsBridgeFromEnvironment(env),
        frames: framesFromEnvironment(env),
      );
      final outDir = Directory(env['AIB_OUT'] ?? '../../results/m3-live-${DateTime.now().toIso8601String().replaceAll(':', '-')}');
      final store = RunStore(outDir);

      await tester.runAsync(() async {
        final runner = BenchmarkRunner(
          suite: suite,
          agents: agents,
          environment: harness.environment,
          store: store,
          repetitionsOverride: reps,
          pricing: PriceTable.fromJson(asJsonMap(jsonDecode(jsonEncode(loadYaml(File('../../suites/pricing_2026_08.yaml').readAsStringSync()))))),
          onEpisode: (meta, result) =>
              // ignore: avoid_print
              print('  ${meta.episodeId}: ${result.outcome.reason.name}'),
          onSkipped: (meta, reason) =>
              // ignore: avoid_print
              print('  ${meta.episodeId}: reused ($reason)'),
        );
        final manifest = await runner.run();

        // Evaluation pass, identical in configuration to `aib evaluate`
        // (P6/ADR 0003 — the same thing can be redone on the traces alone).
        const k = 3; // §5.2 judge repetitions
        final needsJudge = suite.tasks.any((task) => task.successCriteria.any((c) => c.type == CriterionTypes.artifactRubric));
        final judge = needsJudge ? LlmJudge(client: LlmClientFactory.fromConfig(judgeConfig)) : null;
        final evaluation = RunEvaluation(
          evaluator: EpisodeEvaluator(
            evaluators: EpisodeEvaluator.defaultEvaluators(judge: judge, judgeRepetitions: k),
          ),
          // cost_usd from the table pinned at execution time (§6.3).
          metrics: MetricsRegistry.builtin(pricing: manifest.pricing),
        );
        final records = await evaluation.evaluateRun(store.readTraces(), suite);
        final provenance = judge == null ? null : JudgeProvenance.forSuite(suite, judgeId: judge.judgeId, k: k);
        store.writeVerdicts({for (final record in records) record.episodeId: record.verdict}, judge: provenance);
        final data = RunReportData(manifest: manifest, records: records, aggregates: Aggregator().aggregate(records), judge: provenance);
        final registry = ReporterRegistry();
        for (final format in ['csv', 'json', 'md', 'html']) {
          registry[format]!.writeTo(data, outDir);
        }
        // ignore: avoid_print
        print('M3 run written to ${outDir.path}');
      });
      handle.dispose();
    },
    // Gated: configure a model (AIB_LLM_CONFIG or AIB_LLM_PROVIDER +
    // AIB_LLM_MODEL) to run live.
    skip: !live,
    timeout: const Timeout(Duration(hours: 6)),
  );
}
