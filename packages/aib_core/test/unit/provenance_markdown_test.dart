import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

RunManifest _manifest({String suiteHash = 'aaa', JsonMap environmentMetadata = const {'catalogFingerprint': 'cafe'}, JsonMap extra = const {}}) =>
    RunManifest(
      runId: 'run-1',
      createdAt: DateTime.utc(2026, 9, 13),
      suiteName: 'sysco_v1',
      suiteHash: suiteHash,
      agents: const {
        'hybrid': {
          'agentId': 'hybrid',
          'metadata': {'model': 'qwen3:8b'},
        },
      },
      environmentId: 'sysco_mobile',
      environmentVersion: 'integration-test',
      environmentMetadata: environmentMetadata,
      repetitions: 2,
      seed: 42,
      taskOrder: const ['t'],
      platform: const {'operatingSystem': 'macos'},
      extra: extra,
    );

void main() {
  test('the table carries what decides comparability', () {
    final markdown = provenanceMarkdown(_manifest());
    expect(markdown, contains('`suite.hash` | `aaa`'));
    expect(markdown, contains('`environment.metadata.catalogFingerprint` | `cafe`'));
    expect(markdown, contains('`agents.hybrid.metadata.model` | `qwen3:8b`'));
    // Identity, not experiment: a run id and a timestamp never belong here.
    expect(markdown, isNot(contains('run-1')));
  });

  test('two identical runs are reported as comparable', () {
    final markdown = provenanceMarkdown(_manifest(), against: _manifest());
    expect(markdown, contains('Every field that decides comparability is equal'));
  });

  test('a changed field is named with both values', () {
    final markdown = provenanceMarkdown(
      _manifest(),
      against: _manifest(environmentMetadata: const {'catalogFingerprint': 'beef'}),
      againstName: 'older',
    );
    expect(markdown, contains('| `cafe` | `beef` |'));
    expect(markdown, contains('What moved against older'));
  });

  test('a field only one run recorded is separated from a real difference', () {
    // `framework` is absent from every run before it was introduced; reading
    // that as a difference buries the ones that matter.
    final markdown = provenanceMarkdown(
      _manifest(
        suiteHash: 'bbb',
        extra: {
          RunManifest.revisionsKey: {
            'framework': {'revision': 'abc1234567', 'dirty': false},
          },
        },
      ),
      against: _manifest(),
    );
    expect(markdown, contains('| `bbb` | `aaa` |'));
    expect(markdown, contains('Recorded by one run only'));
    expect(markdown, contains('`framework`'));
  });

  test('what judging cost is not part of what the run was', () {
    // Two identical runs judged on different days spend different tokens;
    // leaving that in the projection would have compare refuse every pair.
    const judge = JudgeProvenance(judgeId: 'gpt-oss:20b', k: 3, spend: JudgeSpend(calls: 27, tokensPrompt: 89946));
    final markdown = provenanceMarkdown(_manifest(), judge: judge);
    expect(markdown, contains('judge.judgeId'));
    expect(markdown, isNot(contains('89946')));
  });
}
