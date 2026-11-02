/// AI Interaction Benchmark — Layer 1 core (pure Dart, Flutter-free).
///
/// The core knows only abstract concepts: Task, Agent, Environment,
/// Envelope, Metric, Verdict (spec §1.1). Adapters live in aib_flutter,
/// aib_protocol and aib_agents; test doubles in `package:aib_core/testing.dart`.
library;

export 'src/aggregation/aggregator.dart';
export 'src/aggregation/comparability.dart';
export 'src/aggregation/compare.dart';
export 'src/aggregation/regression_gate.dart';
export 'src/aggregation/routing.dart';
export 'src/aggregation/stats.dart';
export 'src/common/condition.dart';
export 'src/common/draw.dart';
export 'src/common/descriptions.dart';
export 'src/common/json.dart';
export 'src/common/simple_query.dart';
export 'src/common/truncation.dart';
export 'src/engine/engine.dart';
export 'src/engine/perturbation.dart';
export 'src/engine/provenance.dart';
export 'src/engine/run_manifest.dart';
export 'src/engine/run_store.dart';
export 'src/engine/runner.dart';
export 'src/evaluation/artifact_rubric.dart';
export 'src/evaluation/assertions.dart';
export 'src/evaluation/calibration.dart';
export 'src/evaluation/evaluator.dart';
export 'src/evaluation/judge_provenance.dart';
export 'src/evaluation/oracle_selftest.dart';
export 'src/evaluation/run_evaluation.dart';
export 'src/evaluation/verdict.dart';
export 'src/metrics/consistency.dart';
export 'src/metrics/harm.dart';
export 'src/metrics/metrics.dart';
export 'src/metrics/pricing.dart';
export 'src/ports/agent.dart';
export 'src/ports/envelope.dart';
export 'src/ports/environment.dart';
export 'src/ports/user_simulator.dart';
export 'src/evaluation/episode_evidence.dart';
export 'src/metrics/calibration_metrics.dart';
export 'src/reporting/catalog_lint.dart';
export 'src/reporting/preflight.dart';
export 'src/reporting/intent_health.dart';
export 'src/reporting/html_reporter.dart';
export 'src/reporting/junit_reporter.dart';
export 'src/reporting/reporting.dart';
export 'src/task/suite_loader.dart';
export 'src/task/task.dart';
export 'src/trace/jsonl_trace_observer.dart';
export 'src/trace/trace.dart';
export 'src/trace/trace_observer.dart';
