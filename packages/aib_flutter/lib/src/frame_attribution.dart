import 'package:aib_core/ports.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// What the app's own frames cost while the agent worked, per exchange:
/// how many frames were drawn, their build and raster time, and — in a debug
/// build — which widget types rebuilt.
///
/// The environment's own contribution to an episode's latency, which the
/// engine's `handleMs` lumps together with the handler: a `form.set` that
/// rebuilds the whole form page shows up here as hundreds of rebuilds, a
/// cheap one as a handful.
///
/// Read as a resource sample ([FlutterEnvironment.sampleResources]), so it
/// is recorded out of the wall clock and never reaches the agent. Frame
/// timings arrive in batches from the engine, so a sample holds what had
/// been reported by then, not necessarily every frame of that exchange.
final class FrameAttribution {
  FrameAttribution({this.topRebuilt = 10});

  /// How many widget types the sample names; the rest are counted only.
  final int topRebuilt;

  final List<FrameTiming> _timings = [];
  final Map<String, int> _rebuilt = {};
  var _started = false;
  void Function(Element, bool)? _previousRebuildHook;

  /// Starts listening. Rebuild counts need a debug build
  /// (`debugOnRebuildDirtyWidget`); timings are reported in any mode.
  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    if (kDebugMode) {
      _previousRebuildHook = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        _previousRebuildHook?.call(element, builtOnce);
        final type = element.widget.runtimeType.toString();
        _rebuilt[type] = (_rebuilt[type] ?? 0) + 1;
      };
    }
  }

  void stop() {
    if (!_started) return;
    _started = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    if (kDebugMode) debugOnRebuildDirtyWidget = _previousRebuildHook;
  }

  void _onTimings(List<FrameTiming> timings) => _timings.addAll(timings);

  /// What happened since the last call; empty when nothing did.
  JsonMap take() {
    if (_timings.isEmpty && _rebuilt.isEmpty) return const {};
    double ms(Duration d) => d.inMicroseconds / 1000;
    final build = [for (final t in _timings) ms(t.buildDuration)];
    final raster = [for (final t in _timings) ms(t.rasterDuration)];
    final ranked = _rebuilt.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final sample = <String, Object?>{
      'frames': _timings.length,
      if (build.isNotEmpty) ...{
        'frameBuildMsTotal': _round(build.reduce((a, b) => a + b)),
        'frameBuildMsMax': _round(build.reduce((a, b) => a > b ? a : b)),
        'frameRasterMsTotal': _round(raster.reduce((a, b) => a + b)),
        'frameRasterMsMax': _round(raster.reduce((a, b) => a > b ? a : b)),
      },
      if (_rebuilt.isNotEmpty) ...{
        'rebuilt': _rebuilt.values.reduce((a, b) => a + b),
        'rebuiltTypes': {for (final e in ranked.take(topRebuilt)) e.key: e.value},
      },
    };
    _timings.clear();
    _rebuilt.clear();
    return sample;
  }

  static double _round(double ms) => (ms * 10).round() / 10;
}
