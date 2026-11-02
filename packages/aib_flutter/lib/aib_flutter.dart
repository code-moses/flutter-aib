/// AI Interaction Benchmark — Layer 3 Flutter environment adapter.
///
/// All Flutter-specific functionality (semantics tree access, intent
/// dispatch, fixture reset, final-state queries) lives exclusively here
/// (spec §1.1). Envelope key conventions are documented in README.md.
library;

export 'src/catalog_check.dart';
export 'src/flutter_environment.dart';
export 'src/frame_attribution.dart';
export 'src/genui_bridge.dart';
export 'src/intent_bridge.dart';
export 'src/json_schema.dart';
export 'src/semantics_bridge.dart';
export 'src/user_bridge.dart';
export 'src/vision_bridge.dart';
