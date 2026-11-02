import 'dart:async';
import 'dart:isolate';

import 'package:aib_jev/aib_jev.dart';

import 'runtime.dart';

/// Label logits from llama.cpp running *in this process*: no server, no Python,
/// full vocabulary logits (so no 20-label cap and nothing floored).
///
/// The model lives in a worker isolate for the lifetime of this object: loading
/// is paid once ([warmUp]), a decode never blocks the caller's isolate, and the
/// worker keeps its KV cache between calls.
///
/// Cancellation is cooperative at call granularity: a cancelled call returns
/// immediately, and the worker finishes the decode it is in before taking the
/// next one.
///
/// Uses llamadart's prebuilt native library and its generated bindings; see
/// this package's pubspec for why the version is pinned.
final class LlamaJevLogits implements JevLogits, JevWarmUp {
  LlamaJevLogits({
    required this.modelPath,
    required this.renderer,
    String? model,
    this.contextTokens = 8192,
    this.gpuLayers = 99,
    this.threads,
    this.logs = false,
  }) : model = model ?? modelPath.split(RegExp(r'[/\\]')).last;

  /// A GGUF file. An Ollama model is one too: its weights are the blob the
  /// manifest's `application/vnd.ollama.image.model` layer names.
  final String modelPath;

  /// The chat template of the model, rendered in Dart ([JevChatFormat]).
  final JevPromptRenderer renderer;

  @override
  final String model;

  final int contextTokens;
  final int gpuLayers;
  final int? threads;

  /// llama.cpp's own log output, off by default (it prints every tensor).
  final bool logs;

  @override
  String get backend => 'llama.cpp';

  /// Full logits: any number of labels.
  @override
  int? get maxLabels => null;

  Future<_Worker>? _worker;

  Future<_Worker> _start() =>
      _worker ??= _Worker.spawn(_Load(modelPath: modelPath, contextTokens: contextTokens, gpuLayers: gpuLayers, threads: threads, logs: logs));

  /// Loads the model into the worker. Called implicitly by the first
  /// decision otherwise — which then carries the load in its latency.
  @override
  Future<void> warmUp() async {
    await _start();
  }

  @override
  Future<JevLabelLogits> labelLogits(JevScoringPrompt prompt, {CancellationToken? cancellation}) async {
    cancellation?.throwIfCancelled();
    final worker = await _start();
    final reply = worker.score(prompt.render(renderer), prompt.labels);
    final result = cancellation == null
        ? await reply
        : await Future.any([reply, cancellation.whenCancelled.then<_Scored>((reason) => throw TransportException(reason, kind: .cancelled))]);
    return JevLabelLogits(
      logits: result.logits,
      promptTokens: result.evaluated,
      model: model,
      raw: {'prompt_tokens': result.promptTokens, 'evaluated_tokens': result.evaluated},
    );
  }

  /// Frees the model and ends the worker.
  Future<void> close() async {
    final worker = _worker;
    _worker = null;
    if (worker != null) await (await worker).close();
  }
}

// Worker protocol

final class _Load {
  const _Load({required this.modelPath, required this.contextTokens, required this.gpuLayers, required this.threads, required this.logs});

  final String modelPath;
  final int contextTokens;
  final int gpuLayers;
  final int? threads;
  final bool logs;
}

final class _Score {
  const _Score(this.id, this.text, this.labels);

  final int id;
  final String text;
  final List<String> labels;
}

final class _Scored {
  const _Scored(this.id, {this.logits = const [], this.evaluated = 0, this.promptTokens = 0, this.error, this.contextOverflow = false});

  final int id;
  final List<double> logits;
  final int evaluated;
  final int promptTokens;
  final String? error;
  final bool contextOverflow;
}

final class _Close {
  const _Close();
}

final class _Worker {
  _Worker._(this._isolate, this._commands, this._replies);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;
  final Map<int, Completer<_Scored>> _pending = {};
  final _closed = Completer<void>();
  var _nextId = 0;

  static Future<_Worker> spawn(_Load load) async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(_main, (replies.sendPort, load), debugName: 'aib_jev_llama');
    final events = StreamIterator(replies);
    if (!await events.moveNext()) throw StateError('llama worker ended before it was ready');
    final first = events.current;
    if (first is String) {
      isolate.kill();
      replies.close();
      throw StateError(first);
    }
    final worker = _Worker._(isolate, first as SendPort, replies);
    unawaited(() async {
      while (await events.moveNext()) {
        switch (events.current) {
          case final _Scored scored:
            worker._pending.remove(scored.id)?.complete(scored);
          case _Close():
            if (!worker._closed.isCompleted) worker._closed.complete();
        }
      }
    }());
    return worker;
  }

  Future<_Scored> score(String text, List<String> labels) async {
    final id = _nextId++;
    final completer = _pending[id] = Completer<_Scored>();
    _commands.send(_Score(id, text, labels));
    final scored = await completer.future;
    if (scored.error case final error?) {
      throw TransportException(error, kind: scored.contextOverflow ? TransportErrorKind.contextLength : TransportErrorKind.unknown);
    }
    return scored;
  }

  /// Lets the worker free the model before the isolate goes.
  Future<void> close() async {
    _commands.send(const _Close());
    await _closed.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    _replies.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    for (final pending in _pending.values) {
      pending.completeError(StateError('llama worker closed'));
    }
    _pending.clear();
  }
}

Future<void> _main((SendPort, _Load) args) async {
  final (replies, load) = args;
  final LlamaRuntime runtime;
  try {
    runtime = LlamaRuntime.load(load.modelPath, contextTokens: load.contextTokens, gpuLayers: load.gpuLayers, threads: load.threads, logs: load.logs);
  } catch (e) {
    replies.send('$e');
    return;
  }
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  await for (final command in commands) {
    switch (command) {
      case _Score(:final id, :final text, :final labels):
        try {
          final result = runtime.score(text, labels);
          replies.send(_Scored(id, logits: result.logits, evaluated: result.evaluated, promptTokens: result.promptTokens));
        } on RangeError catch (e) {
          replies.send(_Scored(id, error: '${e.message}', contextOverflow: true));
        } catch (e) {
          replies.send(_Scored(id, error: '$e'));
        }
      case _Close():
        runtime.dispose();
        commands.close();
        replies.send(const _Close());
    }
  }
}
