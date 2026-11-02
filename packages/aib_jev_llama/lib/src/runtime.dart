// The llama.cpp side, run inside the worker isolate. Everything here blocks:
// that is why it never runs on the caller's isolate.
//
// llamadart's generated bindings, imported from its `src/`: llamadart
// exposes generation, not logits, and these ~12 functions are the whole of
// what a decision model needs. The package version is pinned exactly.
// ignore_for_file: implementation_imports
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';

/// A loaded model and one context, with the tokens currently in its KV
/// cache — so the next prompt only evaluates what differs from the last.
final class LlamaRuntime {
  LlamaRuntime._(this._model, this._context, this._vocab, this.contextTokens, this.batchTokens);

  static bool _backendReady = false;

  /// Swallows llama.cpp's log lines (hundreds per load). A listener, because
  /// llama.cpp logs from its own threads, where a synchronous Dart callback
  /// would crash the VM.
  static NativeCallable<ggml_log_callbackFunction>? _silence;

  /// Loads [modelPath] (GGUF). [gpuLayers] 0 keeps everything on the CPU.
  factory LlamaRuntime.load(
    String modelPath, {
    int contextTokens = 8192,
    int gpuLayers = 99,
    int? threads,
    int batchTokens = 512,
    bool logs = false,
  }) {
    if (!logs && _silence == null) {
      _silence = NativeCallable<ggml_log_callbackFunction>.listener(_ignoreLog);
      llama_log_set(_silence!.nativeFunction, nullptr);
    }
    if (!_backendReady) {
      llama_backend_init();
      // Split native bundles (Linux, Android) ship the GPU backends as
      // separate modules; macOS/iOS bundles are monolithic and do not export
      // the loader. Best effort, as llamadart does: CPU always works.
      try {
        ggml_backend_load_all();
      } on ArgumentError {
        // Symbol not in this bundle.
      }
      _backendReady = true;
    }
    final modelParams = llama_model_default_params()..n_gpu_layers = gpuLayers;
    final path = modelPath.toNativeUtf8();
    final Pointer<llama_model> model;
    try {
      model = llama_model_load_from_file(path.cast(), modelParams);
    } finally {
      malloc.free(path);
    }
    if (model == nullptr) throw StateError('llama.cpp could not load "$modelPath"');

    final contextParams = llama_context_default_params()
      ..n_ctx = contextTokens
      ..n_batch = batchTokens
      ..n_ubatch = batchTokens;
    if (threads != null) {
      contextParams
        ..n_threads = threads
        ..n_threads_batch = threads;
    }
    final context = llama_init_from_model(model, contextParams);
    if (context == nullptr) {
      llama_model_free(model);
      throw StateError('llama.cpp could not create a context of $contextTokens tokens');
    }
    return LlamaRuntime._(model, context, llama_model_get_vocab(model), llama_n_ctx(context), batchTokens);
  }

  final Pointer<llama_model> _model;
  final Pointer<llama_context> _context;
  final Pointer<llama_vocab> _vocab;
  final int contextTokens;
  final int batchTokens;

  /// What the KV cache of sequence 0 holds.
  List<int> _cached = const [];

  /// Special tokens (`<|im_start|>`) are parsed, and BOS is added where the
  /// model's tokenizer config asks for it — the renderer writes none.
  List<int> tokenize(String text) {
    final utf8 = text.toNativeUtf8();
    final length = utf8.length;
    try {
      var capacity = length + 16;
      while (true) {
        final tokens = malloc<Int32>(capacity);
        try {
          final n = llama_tokenize(_vocab, utf8.cast(), length, tokens, capacity, true, true);
          if (n >= 0) return tokens.asTypedList(n).toList();
          capacity = -n;
        } finally {
          malloc.free(tokens);
        }
      }
    } finally {
      malloc.free(utf8);
    }
  }

  /// The token id of each label at the end of [text], checked the way the
  /// reference checks it: `text + label` must tokenize to `text`'s tokens
  /// plus exactly one more, and the labels must be distinct tokens. A label
  /// that merges with the prompt's last token, or splits in two, would score
  /// something other than the label.
  List<int> labelTokens(String text, List<int> prompt, List<String> labels) {
    final ids = <int>[];
    for (final label in labels) {
      final extended = tokenize(text + label);
      var stable = extended.length == prompt.length + 1;
      for (var i = 0; stable && i < prompt.length; i++) {
        stable = extended[i] == prompt[i];
      }
      if (!stable) throw StateError('answer label "$label" is not a single, stable token for this model');
      ids.add(extended.last);
    }
    if (ids.toSet().length != ids.length) throw StateError('answer labels ${labels.join(' ')} do not map to distinct tokens');
    return ids;
  }

  /// Next-token logits of [labels] after [text], and how many prompt tokens
  /// had to be evaluated (the rest came from the KV cache).
  ({List<double> logits, int evaluated, int promptTokens}) score(String text, List<String> labels) {
    final prompt = tokenize(text);
    if (prompt.length >= contextTokens) {
      throw RangeError('prompt of ${prompt.length} tokens does not fit the context of $contextTokens (context length)');
    }
    final labelIds = labelTokens(text, prompt, labels);

    var common = 0;
    while (common < _cached.length && common < prompt.length && _cached[common] == prompt[common]) {
      common++;
    }
    // The logits of the last position are only there if it was decoded in
    // this call: an identical prompt re-evaluates its final token.
    if (common == prompt.length) common--;
    llama_memory_seq_rm(llama_get_memory(_context), 0, common, -1);
    _cached = prompt.sublist(0, common);

    final tokens = malloc<Int32>(batchTokens);
    try {
      for (var start = common; start < prompt.length; start += batchTokens) {
        final end = start + batchTokens < prompt.length ? start + batchTokens : prompt.length;
        for (var i = start; i < end; i++) {
          tokens[i - start] = prompt[i];
        }
        final status = llama_decode(_context, llama_batch_get_one(tokens, end - start));
        if (status != 0) {
          // Whatever was decoded is in an unknown state now; start clean.
          llama_memory_clear(llama_get_memory(_context), true);
          _cached = const [];
          throw StateError('llama_decode failed with status $status');
        }
        _cached = prompt.sublist(0, end);
      }
    } finally {
      malloc.free(tokens);
    }

    final row = llama_get_logits_ith(_context, -1);
    if (row == nullptr) throw StateError('llama.cpp produced no logits for the last position');
    return (logits: [for (final id in labelIds) row[id]], evaluated: prompt.length - common, promptTokens: prompt.length);
  }

  void dispose() {
    llama_free(_context);
    llama_model_free(_model);
    _silence?.close();
    _silence = null;
  }
}

void _ignoreLog(int level, Pointer<Char> text, Pointer<Void> userData) {}
