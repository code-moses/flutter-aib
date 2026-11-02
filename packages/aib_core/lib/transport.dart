/// Cancellation, error classification and the retry policy every model client
/// shares — and nothing else from the core.
///
/// The narrow entry for a package that only needs to *talk* to a model
/// (`aib_jev`), so it does not pull in tasks, envelopes or the engine.
/// dart:io-free, Flutter-free.
library;

export 'src/common/json.dart';
export 'src/common/transport.dart';
