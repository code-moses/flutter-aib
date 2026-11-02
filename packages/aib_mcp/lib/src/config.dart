import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// `aib_mcp.yaml`: where the checkout is, what the server may write, how runs
/// are launched and what they may spend. A git-ignored sibling
/// `aib_mcp.local.yaml` is merged over it for what only this machine knows.
final class AibMcpConfig {
  AibMcpConfig({
    required String root,
    this.writable = defaultWritable,
    this.maxChangedPaths = 1,
    this.runners = const {},
    this.hosts = const {},
    this.budget = const BudgetConfig(),
    this.judges = const {},
    this.http = const HttpConfig(),
    this.splits = 'suites/splits',
  }) : root = p.normalize(p.absolute(root));

  static const defaultWritable = ['suites/agents/experiments', 'experiments', 'results'];

  /// The framework checkout; every path a tool takes is resolved under it.
  final String root;

  /// Directories under [root] tools may write to.
  final List<String> writable;

  /// How many config paths one derived arm may change (the `decisions:`
  /// block counts as one when added whole). One change per arm is what
  /// makes a comparison attributable.
  final int maxChangedPaths;

  final Map<String, RunnerRecipe> runners;

  /// Model hosts and how many live runs each takes at once.
  final Map<String, HostLimit> hosts;

  final BudgetConfig budget;

  /// Suite name → judge config name. Pinned here rather than chosen per
  /// call, so a tuning agent cannot pick a lenient judge.
  final Map<String, String> judges;

  /// The Streamable HTTP transport (`--http`); its token comes from the
  /// environment, never from a file.
  final HttpConfig http;

  /// Where the suites' holdout splits live, relative to [root].
  final String splits;

  /// Reads [path] and its `.local.yaml` sibling; a relative `root:` is
  /// relative to the file.
  factory AibMcpConfig.load(String path) {
    var json = asJsonMap(yamlToJson(loadYaml(File(path).readAsStringSync())));
    final local = File(localPathFor(path));
    if (local.existsSync()) {
      json = asJsonMap(deepMerge(json, yamlToJson(loadYaml(local.readAsStringSync()))));
    }
    return AibMcpConfig.fromJson(json, base: p.dirname(p.absolute(path)));
  }

  /// `aib_mcp.yaml` → `aib_mcp.local.yaml`.
  static String localPathFor(String path) => p.join(p.dirname(path), '${p.basenameWithoutExtension(path)}.local${p.extension(path)}');

  factory AibMcpConfig.fromJson(JsonMap json, {required String base}) {
    final root = json['root'] as String? ?? '.';
    return AibMcpConfig(
      root: p.isAbsolute(root) ? root : p.join(base, root),
      writable: [for (final w in json['writable'] as List? ?? defaultWritable) '$w'],
      maxChangedPaths: (asJsonMap(json['derive'])['maxChangedPaths'] as num?)?.toInt() ?? 1,
      runners: {for (final entry in asJsonMap(json['runners']).entries) entry.key: RunnerRecipe.fromJson(entry.key, asJsonMap(entry.value))},
      hosts: {for (final entry in asJsonMap(json['hosts']).entries) entry.key: HostLimit.fromJson(entry.key, asJsonMap(entry.value))},
      budget: BudgetConfig.fromJson(asJsonMap(json['budget'])),
      judges: {for (final entry in asJsonMap(json['judges']).entries) entry.key: '${entry.value}'},
      http: HttpConfig.fromJson(asJsonMap(json['http'])),
      splits: json['splits'] as String? ?? 'suites/splits',
    );
  }
}

/// How a runner starts a run. `inProcess` runs `aib run` in an isolate of
/// the server (the mock environment); `process` launches a command — the
/// app-hosted runs, whose environment lives inside `flutter test`.
final class RunnerRecipe {
  const RunnerRecipe({
    required this.name,
    this.kind = .process,
    this.suite,
    this.environment = 'mock',
    this.cwd,
    this.command = const [],
    this.prepare,
    this.cleanup,
    this.env = const {},
    this.output,
    this.stageSuites = false,
    this.maxMinutes = 240,
  });

  final String name;
  final RunnerKind kind;

  /// The suite this runner always runs (an app runner is built for one);
  /// null for an in-process runner, which takes the suite per call.
  final String? suite;

  /// `aib run --env` of an in-process runner.
  final String environment;

  /// Working directory, relative to the checkout or absolute.
  final String? cwd;
  final List<String> command;

  /// Run before [command]; a failure fails the job without running it.
  final List<String>? prepare;

  /// Run after [command] whatever happened — cancelled, failed or done — so
  /// an app never keeps the benchmark inputs it was given for the run.
  final List<String>? cleanup;
  final Map<String, String> env;

  /// Where the runner writes the run directory, when that is not
  /// `results/{out}` (a sandboxed app writes into `~/Downloads`). The server
  /// copies it into `results/{out}` as the run goes and when it ends.
  final String? output;

  /// Give the runner a staged copy of `suites/` (`{suitesDir}`) in which
  /// the arm sits at the top of `agents/` as `{agentConfigFile}`. For a
  /// runner that bundles `suites/agents/*` without subdirectories — an app
  /// that ships its inputs as assets — so a derived arm under
  /// `experiments/` reaches it too.
  final bool stageSuites;

  /// Wall-clock cap; the job is cancelled past it.
  final int maxMinutes;

  factory RunnerRecipe.fromJson(String name, JsonMap json) => RunnerRecipe(
    name: name,
    kind: json['kind'] == 'inProcess' ? RunnerKind.inProcess : RunnerKind.process,
    suite: json['suite'] as String?,
    environment: json['environment'] as String? ?? 'mock',
    cwd: json['cwd'] as String?,
    command: [for (final part in json['command'] as List? ?? const []) '$part'],
    prepare: json['prepare'] == null ? null : [for (final part in json['prepare'] as List) '$part'],
    cleanup: json['cleanup'] == null ? null : [for (final part in json['cleanup'] as List) '$part'],
    env: {for (final entry in asJsonMap(json['env']).entries) entry.key: '${entry.value}'},
    output: json['output'] as String?,
    stageSuites: json['stageSuites'] as bool? ?? false,
    maxMinutes: (json['maxMinutes'] as num?)?.toInt() ?? 240,
  );
}

enum RunnerKind { inProcess, process }

/// A model host: live runs against it queue, so latency metrics are
/// measured on a GPU nobody else is using.
final class HostLimit {
  const HostLimit({required this.name, required this.url, this.concurrency = 1});

  final String name;
  final String url;
  final int concurrency;

  factory HostLimit.fromJson(String name, JsonMap json) =>
      HostLimit(name: name, url: '${json['url']}', concurrency: (json['concurrency'] as num?)?.toInt() ?? 1);
}

final class BudgetConfig {
  const BudgetConfig({this.maxUsdPerJob = 5, this.maxUsdPerDay = 20, this.autoApproveUsd = 0, this.priceTable = 'suites/pricing_2026_09.yaml'});

  final double maxUsdPerJob;
  final double maxUsdPerDay;

  /// Estimates up to this start without asking a person.
  final double autoApproveUsd;

  /// The price table spend is accounted with, relative to the checkout.
  final String priceTable;

  factory BudgetConfig.fromJson(JsonMap json) => BudgetConfig(
    maxUsdPerJob: (json['maxUsdPerJob'] as num?)?.toDouble() ?? 5,
    maxUsdPerDay: (json['maxUsdPerDay'] as num?)?.toDouble() ?? 20,
    autoApproveUsd: (json['autoApproveUsd'] as num?)?.toDouble() ?? 0,
    priceTable: json['priceTable'] as String? ?? 'suites/pricing_2026_09.yaml',
  );
}

final class HttpConfig {
  const HttpConfig({this.host = '127.0.0.1', this.port = 8765, this.path = '/mcp', this.allowedOrigins = const {}, this.tokenEnv = 'AIB_MCP_TOKEN'});

  /// Loopback by default; a benchmark machine that serves others binds
  /// `0.0.0.0` on purpose.
  final String host;
  final int port;
  final String path;

  /// Browser origins besides localhost that may call the server.
  final Set<String> allowedOrigins;

  /// The environment variable holding the bearer token.
  final String tokenEnv;

  factory HttpConfig.fromJson(JsonMap json) => HttpConfig(
    host: json['host'] as String? ?? '127.0.0.1',
    port: (json['port'] as num?)?.toInt() ?? 8765,
    path: json['path'] as String? ?? '/mcp',
    allowedOrigins: {for (final o in json['allowedOrigins'] as List? ?? const []) '$o'},
    tokenEnv: json['tokenEnv'] as String? ?? 'AIB_MCP_TOKEN',
  );
}

/// A parsed YAML node as plain JSON values.
Object? yamlToJson(Object? node) => switch (node) {
  YamlMap() => {for (final entry in node.entries) '${entry.key}': yamlToJson(entry.value)},
  YamlList() => [for (final item in node) yamlToJson(item)],
  _ => node,
};

/// [over] merged into [base]: maps key by key, anything else replaced.
Object? deepMerge(Object? base, Object? over) {
  if (base is Map && over is Map) {
    return {...asJsonMap(base), for (final entry in over.entries) '${entry.key}': deepMerge(base[entry.key], entry.value)};
  }
  return over ?? base;
}
