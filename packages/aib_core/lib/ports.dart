/// Everything an agent implementation needs, and nothing else. dart:io-free,
/// Flutter-free: safe to ship inside an application.
///
/// `condition.dart` is for the environment side: an app answering ground-truth
/// queries evaluates the `where(...)` half of the query convention with it.
library;

export 'src/common/condition.dart';
export 'src/common/descriptions.dart';
export 'src/common/draw.dart';
export 'src/common/json.dart';
export 'src/common/transport.dart';
export 'src/common/truncation.dart';
export 'src/ports/agent.dart';
export 'src/ports/envelope.dart';
export 'src/ports/environment.dart';
export 'src/ports/user_simulator.dart';
export 'src/task/task.dart';
