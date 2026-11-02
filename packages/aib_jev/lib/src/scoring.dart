import 'dart:math' as math;
import 'dart:typed_data';

import 'package:aib_core/transport.dart';

import 'answer.dart';
import 'request.dart';
import 'template.dart';

/// Turns one branch's label logits into its answer — a port of simple-jev's
/// `common/response_scoring.py` (v1), checked against it by
/// `test/scoring_test.dart`.
///
/// [logits] follow [JevBranch.outputLabels] by position and may be shifted
/// by any constant (log-probabilities work as well as raw logits: the
/// softmax over the selected labels is the same). The answer carries the
/// reference's diagnostics — margin and ties for a choice, variance for a
/// score, the rating distribution for a noul — and the raw logits only when
/// [rawLogits] asks for them.
///
/// The logits are rounded to float32 first, as the reference does, so exact
/// ties are ties at the precision the reference compares at. The arithmetic
/// after that is float64; results agree with the reference to ~1e-6.
JevAnswer scoreBranch(JevBranch branch, List<double> logits, {bool rawLogits = false, JsonMap extra = const {}}) {
  final labels = branch.answerLabels;
  if (logits.length != labels.length) {
    throw ArgumentError('branch ${branch.branchId} expects ${labels.length} logits, got ${logits.length}');
  }
  final z = Float32List.fromList(logits);
  if (z.any((v) => !v.isFinite)) {
    throw ArgumentError('branch ${branch.branchId}: logits must be finite');
  }
  var max = z.first;
  var winner = 0;
  for (var i = 1; i < z.length; i++) {
    // Strictly greater: the first exact tie wins, in candidate order.
    if (z[i] > max) {
      max = z[i];
      winner = i;
    }
  }
  final exps = [for (final v in z) math.exp(v - max)];
  final total = exps.fold<double>(0, (a, b) => a + b);
  final p = [for (final e in exps) e / total];

  final JsonMap json;
  switch (branch.question) {
    case JevNoul():
      // Nine integer bins, whatever the prompt says about 0.1–0.9.
      final bins = [for (var i = 1; i <= 9; i++) i.toDouble()];
      final mean = _dot(p, bins);
      json = {
        'type': 'noul',
        // Rating 1 → 0.01, 5 → 0.5, 9 → 0.99; clipped against roundoff.
        'noul': (0.01 + (mean / 10 - 0.1) * (0.98 / 0.8)).clamp(0.01, 0.99),
        'calibrated': false,
        'rating': {
          'bins': bins,
          'probabilities': p,
          'expected_score': mean,
          'variance': _dot(p, [for (final b in bins) (b - mean) * (b - mean)]),
          'entropy': -p.where((v) => v > 0).fold<double>(0, (a, v) => a + v * math.log(v)),
          if (rawLogits) 'logits': [...z],
        },
      };
    case JevChoice():
      final sorted = [...p]..sort();
      json = {
        'type': 'choice',
        'confidence': p[winner],
        'probabilities': {for (var i = 0; i < labels.length; i++) labels[i]: p[i]},
        'calibrated': false,
        if (rawLogits) 'logits': {for (var i = 0; i < labels.length; i++) labels[i]: z[i]},
        'choice': labels[winner],
        'margin': sorted.last - sorted[sorted.length - 2],
        'ties': [
          for (var i = 0; i < labels.length; i++)
            if (z[i] == max) labels[i],
        ],
        'scoring': 'direct_label_logits',
      };
    case JevScore(:final levels):
      // The distribution's mean, not the winning level.
      final bins = [for (var i = 0; i < labels.length; i++) i.toDouble()];
      final mean = _dot(p, bins);
      json = {
        'type': 'score',
        'confidence': p[winner],
        'probabilities': {for (var i = 0; i < labels.length; i++) labels[i]: p[i]},
        'calibrated': false,
        if (rawLogits) 'logits': {for (var i = 0; i < labels.length; i++) labels[i]: z[i]},
        'score': mean,
        'legend': {for (var i = 0; i < levels.length; i++) '$i': levels[i]},
        'variance': _dot(p, [for (final b in bins) (b - mean) * (b - mean)]),
        'scoring': 'direct_level_logits',
        'score_mapping': 'label_to_zero_based_level',
      };
  }
  return branch.question.parse({...json, ...extra});
}

double _dot(List<double> a, List<double> b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}
