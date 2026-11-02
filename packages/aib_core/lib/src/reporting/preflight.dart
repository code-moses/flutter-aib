/// What a preflight check found, and what to do about it. Ordered by
/// [DoctorStatus] so the first thing printed is the first thing to fix.
enum DoctorStatus { fail, warn, ok }

final class DoctorCheck {
  const DoctorCheck(this.status, this.what, {this.detail, this.nextStep});

  final DoctorStatus status;

  /// What was checked, in the words of the thing that breaks.
  final String what;
  final String? detail;

  /// The command or edit that fixes it. Required reading for a `fail`.
  final String? nextStep;

  bool get isFail => status == .fail;
}

/// Where a config's credentials and endpoint come from, without building a
/// client — a doctor must not need a working key to report a missing one.
final class LlmTarget {
  const LlmTarget({required this.label, required this.provider, required this.model, this.baseUrl, this.apiKeyEnv});

  /// Which config this is: `judge`, or an agent name.
  final String label;
  final String provider;
  final String model;
  final String? baseUrl;
  final String? apiKeyEnv;

  bool get isLocal => provider == 'ollama';
}

/// Two model names close enough that a judge would be grading its own homework.
/// Compared by family: `qwen3:8b` judged by `qwen3:4b` is the same threat as
/// judging itself (SPA-Bench).
bool sharesModelFamily(String a, String b) {
  String family(String model) => model.split(RegExp('[:/@]')).first.replaceAll(RegExp(r'[-_.]?\d.*$'), '').toLowerCase();
  final left = family(a);
  final right = family(b);
  return left.isNotEmpty && left == right;
}

/// The preflight rules that need no network: everything that can be decided
/// from the configs alone.
List<DoctorCheck> preflightConfigChecks({
  required LlmTarget? judge,
  required List<LlmTarget> agents,
  required Set<String> environmentKeys,
  LlmTarget? simulator,
}) {
  final checks = <DoctorCheck>[];

  for (final target in [?judge, ?simulator, ...agents]) {
    final keyEnv = target.apiKeyEnv;
    if (!target.isLocal && keyEnv != null && !environmentKeys.contains(keyEnv)) {
      checks.add(
        DoctorCheck(
          DoctorStatus.fail,
          '${target.label}: $keyEnv is not set',
          detail: '${target.provider} needs it for ${target.model}.',
          nextStep: 'set -a; . ./.env; set +a   # or pass it as --dart-define',
        ),
      );
    }
  }

  if (judge != null) {
    for (final agent in agents) {
      if (sharesModelFamily(judge.model, agent.model)) {
        checks.add(
          DoctorCheck(
            DoctorStatus.warn,
            'judge and ${agent.label} are the same model family',
            detail:
                '${judge.model} judging ${agent.model}: a judge that shares '
                'the agent\'s weights prefers its own output.',
            nextStep: 'Pin a judge from another family.',
          ),
        );
      }
    }
  }

  if (simulator != null) {
    for (final other in [?judge, ...agents]) {
      if (sharesModelFamily(simulator.model, other.model)) {
        checks.add(
          DoctorCheck(
            DoctorStatus.warn,
            'simulated user and ${other.label} are the same model family',
            detail:
                '${simulator.model} playing the user for ${other.model} speaks '
                'the way that model expects to be spoken to.',
            nextStep: 'Pin a simulated user from a third family.',
          ),
        );
      }
    }
  }

  return checks;
}

String doctorMarkdown(List<DoctorCheck> checks) {
  final ordered = [...checks]..sort((a, b) => a.status.index.compareTo(b.status.index));
  final buffer = StringBuffer();
  for (final check in ordered) {
    final mark = switch (check.status) {
      .fail => '✗',
      .warn => '!',
      .ok => '✓',
    };
    buffer.writeln('$mark ${check.what}');
    if (check.detail != null) buffer.writeln('    ${check.detail}');
  }
  final steps = ordered.where((c) => c.nextStep != null && c.status != .ok).toList();
  if (steps.isNotEmpty) {
    buffer.writeln('\nnext steps, in order:');
    for (var i = 0; i < steps.length; i++) {
      buffer.writeln('  ${i + 1}. ${steps[i].nextStep}');
    }
  }
  return buffer.toString();
}
