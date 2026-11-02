import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

RunManifest _manifest({String model = 'claude-sonnet-5', String catalog = '5c578c73000c', String? framework, String runId = 'a'}) => RunManifest(
  runId: runId,
  createdAt: DateTime(2026, 9, runId == 'a' ? 10 : 11),
  suiteName: 'sysco_v1',
  suiteHash: 'h',
  agents: {
    'hybrid': {
      'agentId': 'hybrid',
      'version': 'hybrid_v4',
      'description': 'free text',
      'metadata': {'model': model, 'promptHash': 'p'},
    },
  },
  environmentId: 'sysco_mobile',
  environmentMetadata: {'catalogFingerprint': catalog},
  repetitions: 2,
  seed: 42,
  taskOrder: runId == 'a' ? const ['x', 'y'] : const ['y', 'x'],
  platform: {'operatingSystemVersion': runId},
  extra: {
    if (framework != null) RunManifest.revisionsKey: {'framework': SourceRevision(revision: framework).toJson()},
  },
);

void main() {
  test('run identity is not a difference', () {
    expect(manifestDifferences(_manifest(), _manifest(runId: 'b')), isEmpty);
  });

  test('what changes a result is', () {
    final differences = manifestDifferences(
      _manifest(framework: '1d3909c7b8'),
      _manifest(model: 'qwen3:8b', catalog: 'ffff', framework: 'c46be9f9c5'),
    );
    expect(differences.map((d) => d.path), ['agents.hybrid.metadata.model', 'environment.metadata.catalogFingerprint', 'framework']);
  });

  test('the judge is compared without its timestamp', () {
    JudgeProvenance judge(DateTime at) => JudgeProvenance(judgeId: 'gpt-oss:20b', k: 3, evaluatedAt: at);
    expect(manifestDifferences(_manifest(), _manifest(), judgeA: judge(DateTime(2026)), judgeB: judge(DateTime(2027))), isEmpty);
  });

  group('pathMatches', () {
    test('a bare word matches the last segment anywhere', () {
      expect(pathMatches('agents.hybrid.metadata.model', 'model'), isTrue);
      expect(pathMatches('models.hybrid.digest', 'model'), isFalse);
    });

    test('* is one segment, ** any number', () {
      expect(pathMatches('agents.hybrid.metadata.model', 'agents.*.metadata.model'), isTrue);
      expect(pathMatches('agents.hybrid.metadata.model', 'agents.*.model'), isFalse);
      expect(pathMatches('models.hybrid.digest', 'models.**'), isTrue);
    });
  });
}
