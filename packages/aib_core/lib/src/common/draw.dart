import 'dart:convert';

/// A number in [0, 1) derived from [key] alone: FNV-1a with a murmur
/// finaliser. Stable across processes and platforms, unlike `hashCode`, so a
/// seeded perturbation meets the same draw in every run.
double stableUnitDraw(String key) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(key)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  hash ^= hash >> 16;
  hash = (hash * 0x85ebca6b) & 0xffffffff;
  hash ^= hash >> 13;
  hash = (hash * 0xc2b2ae35) & 0xffffffff;
  hash ^= hash >> 16;
  return hash / 0x100000000;
}
