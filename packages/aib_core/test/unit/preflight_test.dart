import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

const _judge = LlmTarget(label: 'judge', provider: 'ollama', model: 'gpt-oss:20b', baseUrl: 'http://localhost:11434');

const _sonnet = LlmTarget(label: 'hybrid', provider: 'anthropic', model: 'claude-sonnet-5', apiKeyEnv: 'ANTHROPIC_API_KEY');

void main() {
  group('sharesModelFamily', () {
    test('a model judged by itself', () {
      expect(sharesModelFamily('qwen3:8b', 'qwen3:8b'), isTrue);
    });

    test('a smaller sibling is the same threat', () {
      // The suites pin a different family on purpose; qwen3:4b judging
      // qwen3:8b is still grading its own homework.
      expect(sharesModelFamily('qwen3:8b', 'qwen3:4b'), isTrue);
    });

    test('different families are fine', () {
      expect(sharesModelFamily('gpt-oss:20b', 'qwen3:8b'), isFalse);
      expect(sharesModelFamily('claude-sonnet-5', 'qwen3:8b'), isFalse);
    });
  });

  group('preflightConfigChecks', () {
    test('a keyed provider with no key in the environment fails', () {
      final checks = preflightConfigChecks(judge: _judge, agents: const [_sonnet], environmentKeys: const {});
      expect(checks.single.isFail, isTrue);
      expect(checks.single.what, contains('ANTHROPIC_API_KEY'));
      expect(checks.single.nextStep, isNotNull);
    });

    test('a local provider needs no key', () {
      expect(
        preflightConfigChecks(
          judge: _judge,
          agents: const [LlmTarget(label: 'hybrid', provider: 'ollama', model: 'qwen3:8b')],
          environmentKeys: const {},
        ),
        isEmpty,
      );
    });

    test('a judge of the agent’s own family is a warning, not a failure', () {
      final checks = preflightConfigChecks(
        judge: const LlmTarget(label: 'judge', provider: 'ollama', model: 'qwen3:4b'),
        agents: const [LlmTarget(label: 'hybrid', provider: 'ollama', model: 'qwen3:8b')],
        environmentKeys: const {},
      );
      expect(checks.single.status, DoctorStatus.warn);
    });

    test('a key that is set satisfies the check', () {
      expect(preflightConfigChecks(judge: null, agents: const [_sonnet], environmentKeys: const {'ANTHROPIC_API_KEY'}), isEmpty);
    });
  });

  test('doctorMarkdown puts failures first and numbers the fixes', () {
    final markdown = doctorMarkdown(const [
      DoctorCheck(DoctorStatus.ok, 'suite loads'),
      DoctorCheck(DoctorStatus.warn, 'same family', nextStep: 'pin another judge'),
      DoctorCheck(DoctorStatus.fail, 'ollama is down', nextStep: 'ollama serve'),
    ]);
    expect(markdown.indexOf('ollama is down'), lessThan(markdown.indexOf('same family')));
    expect(markdown.indexOf('same family'), lessThan(markdown.indexOf('suite loads')));
    expect(markdown, contains('1. ollama serve'));
    expect(markdown, contains('2. pin another judge'));
  });
}
