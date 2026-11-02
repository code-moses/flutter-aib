import 'json.dart';

/// Result of capping an oversized payload.
typedef TruncatedPayload = ({JsonMap payload, bool truncated});

/// Caps a result payload at [maxBytes], marking what it had to drop.
///
/// The largest top-level list is shortened and annotated with how many entries
/// exist, so the model can ask a narrower question instead of receiving a
/// broken JSON fragment. A payload with no list to shorten is replaced by its
/// own description.
TruncatedPayload capPayload(JsonMap payload, {required int maxBytes}) {
  if (jsonSizeBytes(payload) <= maxBytes) {
    return (payload: payload, truncated: false);
  }

  final listKey = _largestListKey(payload);
  if (listKey == null) {
    return (
      payload: {
        'truncated': true,
        'reason':
            'payload of ${jsonSizeBytes(payload)} bytes exceeds the '
            '$maxBytes byte cap and has no list to shorten',
        'keys': payload.keys.toList(),
      },
      truncated: true,
    );
  }

  final full = payload[listKey] as List;
  JsonMap attempt(int n) => {...payload, listKey: full.take(n).toList(), 'truncated': true, 'totalCount': full.length, 'returnedCount': n};
  // The longest prefix that fits, by binary search: halving could drop up to
  // half the list below the cap, and every entry dropped is one the agent
  // has to ask for again.
  var low = 0;
  var high = full.length;
  while (low < high) {
    final middle = (low + high + 1) ~/ 2;
    if (jsonSizeBytes(attempt(middle)) <= maxBytes) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return (payload: attempt(low), truncated: true);
}

String? _largestListKey(JsonMap payload) {
  String? best;
  var bestSize = 0;
  for (final entry in payload.entries) {
    if (entry.value is! List) continue;
    final size = jsonSizeBytes({entry.key: entry.value});
    if (size > bestSize) {
      bestSize = size;
      best = entry.key;
    }
  }
  return best;
}
