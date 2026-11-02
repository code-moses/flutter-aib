import 'package:aib_core/ports.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'flutter_environment.dart';

/// Facts about [node] beyond its semantics, or null for none.
typedef SemanticsEnricher = JsonMap? Function(SemanticsNode node);

/// Semantics envelope vocabulary — convention between the reference agents and
/// this adapter (spec §4.4), versioned in the package README:
///
///   observe `semantics.tree`     {} -> {tree, nodeCount, prunedCount}
///   act     `semantics.tap`      {nodeId | label}
///   act     `semantics.setText`  {nodeId | label, text}
///   act     `semantics.scroll`   {nodeId | label, direction: up|down|left|right}
///   act     `semantics.showOnScreen` {nodeId | label}
///
/// Node addressing: by stable semantics node id or by exact label. Ambiguous
/// labels are rejected with a structured error.
///
/// Three opt-in checks, after `fluttersdk_dusk`'s element refs and
/// actionability gate; the descriptor metadata names the ones that are on.
///
/// - [staleRefCheck]: an action by `nodeId` on a node whose label, tooltip, hint or role
///   changed since the last `semantics.tree` fails `stale_ref`.
/// - [actionabilityGate]: before a tap, long press or setText, the node must be enabled and
///   have a size; an off-screen one is scrolled into view first and refused `off_screen` if
///   it still is not.
/// - [candidateActions]: `semantics.tree` also returns `candidates`, one line per on-screen
///   action (`{id, action, label}`).
///
/// [enrichers] add what the semantics tree cannot say (a form field's name, a
/// row's record id) under the enricher's name on each node it answers for.
final class SemanticsBridge {
  SemanticsBridge({
    SemanticsOwner? Function()? ownerResolver,
    this.staleRefCheck = false,
    this.actionabilityGate = false,
    this.candidateActions = false,
    this.enrichers = const {},
  }) : _resolveOwner = ownerResolver ?? _defaultOwner;

  final SemanticsOwner? Function() _resolveOwner;
  final bool staleRefCheck;
  final bool actionabilityGate;
  final bool candidateActions;

  /// Name → [SemanticsEnricher]; each answer lands under its name.
  final Map<String, SemanticsEnricher> enrichers;

  /// What each node id looked like when the agent last observed the tree.
  final Map<int, String> _seen = {};

  /// The options that are on, for the environment's descriptor metadata.
  JsonMap get options => {
    if (staleRefCheck) 'staleRefCheck': true,
    if (actionabilityGate) 'actionabilityGate': true,
    if (candidateActions) 'candidateActions': true,
    if (enrichers.isNotEmpty) 'enrichers': enrichers.keys.toList(),
  };
  SemanticsHandle? _handle;
  Future<void> Function()? _settle;

  static SemanticsOwner? _defaultOwner() {
    for (final view in RendererBinding.instance.renderViews) {
      final owner = view.owner?.semanticsOwner;
      if (owner != null) return owner;
    }
    return null;
  }

  void install(FlutterEnvironment environment) {
    // Keep semantics alive for the whole benchmark session. If the host
    // already enabled semantics (e.g. tester.ensureSemantics() in widget
    // tests), that handle stays authoritative and nothing leaks here.
    if (_handle == null && !SemanticsBinding.instance.semanticsEnabled) {
      _handle = SemanticsBinding.instance.ensureSemantics();
    }
    _settle = environment.settle;

    environment.registerHandler(
      EnvelopeSpec(
        key: 'semantics.tree',
        kind: .observe,
        // The checks that are on are part of what the environment is, so they
        // travel in its descriptor — and the agent learns the error codes.
        description:
            'Pruned serialization of the semantics tree '
            '(interactive and labelled nodes, stable node ids).'
            '${candidateActions ? ' Also lists the on-screen actions as candidates.' : ''}'
            '${staleRefCheck ? ' A nodeId refers to the node as last observed: if it changed, an action fails stale_ref.' : ''}'
            '${actionabilityGate ? ' Gestures are refused disabled, zero_size or off_screen (after scrolling to the node).' : ''}',
      ),
      (envelope) async {
        final root = _rootNode();
        if (root == null) {
          return EnvelopeResult.failed('no_semantics', 'No semantics tree available');
        }
        var nodeCount = 0;
        var prunedCount = 0;
        if (staleRefCheck) _seen.clear();
        final candidates = <JsonMap>[];
        List<JsonMap> serialize(SemanticsNode node) {
          nodeCount++;
          // The node before its children, so the candidates come out in
          // reading order.
          final serialized = serializeNode(node, viewport: root.rect);
          if (serialized != null) {
            for (final MapEntry(key: name, value: enrich) in enrichers.entries) {
              if (enrich(node) case final extra? when extra.isNotEmpty) serialized[name] = extra;
            }
            if (staleRefCheck) _seen[node.id] = _signature(node);
            if (candidateActions && serialized['onScreen'] != false) {
              final name = serialized['label'] ?? serialized['tooltip'] ?? serialized['hint'] ?? serialized['value'];
              for (final action in serialized['actions'] as List? ?? const []) {
                if (_candidateActions.contains(action)) candidates.add({'id': node.id, 'action': action, 'label': ?name});
              }
            }
          }
          final children = <JsonMap>[];
          node.visitChildren((child) {
            children.addAll(serialize(child));
            return true;
          });
          if (serialized == null) {
            prunedCount++;
            return children; // hoist children of pruned nodes
          }
          if (children.isNotEmpty) serialized['children'] = children;
          return [serialized];
        }

        final tree = serialize(root);
        return EnvelopeResult.ok({'tree': tree, 'nodeCount': nodeCount, 'prunedCount': prunedCount, if (candidateActions) 'candidates': candidates});
      },
    );

    environment.registerHandler(
      const EnvelopeSpec(
        key: 'semantics.tap',
        kind: .act,
        description: 'Tap a node addressed by nodeId or label.',
        payloadSchema: {
          'type': 'object',
          'properties': {
            'nodeId': {'type': 'integer'},
            'label': {'type': 'string'},
          },
        },
      ),
      (envelope) async => _perform(envelope, SemanticsAction.tap),
    );

    environment.registerHandler(
      const EnvelopeSpec(
        key: 'semantics.setText',
        kind: .act,
        description: 'Set the text of a text field (nodeId or label).',
        payloadSchema: {
          'type': 'object',
          'properties': {
            'nodeId': {'type': 'integer'},
            'label': {'type': 'string'},
            'text': {'type': 'string'},
          },
          'required': ['text'],
        },
      ),
      (envelope) async {
        final text = envelope.payload['text'];
        if (text is! String) {
          return EnvelopeResult.failed('bad_payload', '"text" is required');
        }
        return _setText(envelope, text);
      },
    );

    environment.registerHandler(
      const EnvelopeSpec(key: 'semantics.scroll', kind: .act, description: 'Scroll a node (direction: up|down|left|right).'),
      (envelope) async {
        final action = switch (envelope.payload['direction']) {
          'up' => SemanticsAction.scrollUp,
          'down' => SemanticsAction.scrollDown,
          'left' => SemanticsAction.scrollLeft,
          'right' => SemanticsAction.scrollRight,
          _ => null,
        };
        if (action == null) {
          return EnvelopeResult.failed('bad_payload', 'direction must be up|down|left|right');
        }
        return _perform(envelope, action);
      },
    );

    // Scrolling by direction is a guess about distance; showOnScreen is what
    // the framework itself uses to bring a focused widget into view.
    environment.registerHandler(
      const EnvelopeSpec(
        key: 'semantics.showOnScreen',
        kind: .act,
        description:
            'Scroll a node into the visible viewport (nodeId or label). Use '
            'it when a node reports "onScreen": false.',
        payloadSchema: {
          'type': 'object',
          'properties': {
            'nodeId': {'type': 'integer'},
            'label': {'type': 'string'},
          },
        },
      ),
      (envelope) async => _perform(envelope, SemanticsAction.showOnScreen),
    );
  }

  void dispose() {
    _handle?.dispose();
    _handle = null;
  }

  static const _candidateActions = {'tap', 'longPress', 'setText', 'increase', 'decrease'};

  /// What identifies a node to the agent that saw it: its texts and its role,
  /// not its state — a checkbox that was ticked is still the same checkbox.
  static String _signature(SemanticsNode node) {
    final data = node.getSemanticsData();
    final flags = data.flagsCollection;
    return [data.label, data.tooltip, data.hint, flags.isButton, flags.isTextField, flags.isLink].join('\u0000');
  }

  /// Why [node] cannot take a gesture now, or null when it can. Scrolls an
  /// off-screen node into view first.
  Future<EnvelopeError?> _actionable(SemanticsOwner owner, SemanticsNode node) async {
    final data = node.getSemanticsData();
    if (data.flagsCollection.isEnabled == .isFalse) {
      return EnvelopeError(code: 'disabled', message: 'Node ${node.id} is disabled; something else has to happen first');
    }
    if (globalRect(node).isEmpty) {
      return EnvelopeError(code: 'zero_size', message: 'Node ${node.id} has no size on screen; it cannot be acted on');
    }
    final root = _rootNode();
    if (root != null && !_isOnScreen(node, root.rect)) {
      await _scrollIntoView(owner, node);
      final now = _rootNode();
      if (now != null && !_isOnScreen(node, now.rect)) {
        return EnvelopeError(code: 'off_screen', message: 'Node ${node.id} is off screen and could not be scrolled into view; scroll to it first');
      }
    }
    return null;
  }

  /// The node's own `showOnScreen` where it has one; otherwise its nearest
  /// scrolling ancestor, a page at a time towards it. Most nodes in a
  /// scrollable carry no `showOnScreen` of their own — the action sits on the
  /// scrollable.
  Future<void> _scrollIntoView(SemanticsOwner owner, SemanticsNode node) async {
    if (node.getSemanticsData().hasAction(SemanticsAction.showOnScreen)) {
      owner.performAction(node.id, SemanticsAction.showOnScreen);
      await _settle?.call();
      return;
    }
    final scrollable = _scrollableAncestor(node.parent ?? node);
    if (scrollable == null) return;
    for (var page = 0; page < _maxScrollPages; page++) {
      final root = _rootNode();
      if (root == null || _isOnScreen(node, root.rect)) return;
      final rect = globalRect(node);
      final viewport = root.rect;
      final action = rect.top >= viewport.bottom
          ? SemanticsAction.scrollUp
          : rect.bottom <= viewport.top
          ? SemanticsAction.scrollDown
          : rect.left >= viewport.right
          ? SemanticsAction.scrollLeft
          : SemanticsAction.scrollRight;
      if (!scrollable.getSemanticsData().hasAction(action)) return;
      owner.performAction(scrollable.id, action);
      await _settle?.call();
    }
  }

  static const _maxScrollPages = 20;

  static const _gestures = {SemanticsAction.tap, SemanticsAction.longPress, SemanticsAction.setText};

  SemanticsNode? _rootNode() => _resolveOwner()?.rootSemanticsNode;

  /// Global bounds of [node] — [SemanticsNode.rect] is in the node's own
  /// coordinate space and [SemanticsNode.transform] only maps into the
  /// *parent's*, so the ancestors have to be walked to learn where a node
  /// actually sits on screen.
  static Rect globalRect(SemanticsNode node) {
    var rect = node.rect;
    for (var current = node; ;) {
      if (current.transform case final transform?) {
        rect = MatrixUtils.transformRect(transform, rect);
      }
      final parent = current.parent;
      if (parent == null) return rect;
      current = parent;
    }
  }

  /// Physical pixels per logical pixel. [globalRect] comes out scaled by
  /// exactly this — measured, not assumed: 3.0 under `flutter_test`, 2.0 on
  /// the retina Mac the benchmark runs on.
  static double _devicePixelRatio() {
    for (final view in RendererBinding.instance.renderViews) {
      return view.flutterView.devicePixelRatio;
    }
    return 1.0;
  }

  /// Serializes one node; returns null if the node carries no information
  /// relevant to an agent (pruning: only interactive + labelled nodes). With
  /// [viewport] every node also reports whether it is actually visible.
  static JsonMap? serializeNode(SemanticsNode node, {Rect? viewport}) {
    if (node.isInvisible || node.isMergedIntoParent) return null;
    final data = node.getSemanticsData();
    final actions = [
      for (final action in SemanticsAction.values)
        if (data.hasAction(action)) action.name,
    ];
    final interactive = const {
      'tap',
      'longPress',
      'setText',
      'increase',
      'decrease',
      'scrollUp',
      'scrollDown',
      'scrollLeft',
      'scrollRight',
    }.any(actions.contains);
    final hasText = data.label.isNotEmpty || data.value.isNotEmpty || data.hint.isNotEmpty || data.tooltip.isNotEmpty;
    if (!interactive && !hasText) return null;

    // Where the node actually sits, in logical pixels: `node.rect` alone is the
    // node's own space, and the composed rect is physical.
    final ratio = _devicePixelRatio();
    final bounds = globalRect(node);
    return {
      'id': node.id,
      if (data.label.isNotEmpty) 'label': data.label,
      if (data.tooltip.isNotEmpty) 'tooltip': data.tooltip,
      if (data.value.isNotEmpty) 'value': data.value,
      if (data.hint.isNotEmpty) 'hint': data.hint,
      if (actions.isNotEmpty) 'actions': actions,
      'flags': data.flagsCollection.toStrings(),
      'rect': {'left': bounds.left / ratio, 'top': bounds.top / ratio, 'width': bounds.width / ratio, 'height': bounds.height / ratio},
      if (viewport != null) 'onScreen': _isOnScreen(node, viewport),
    };
  }

  static bool _isOnScreen(SemanticsNode node, Rect viewport) {
    final rect = globalRect(node);
    if (rect.isEmpty) return false;
    return rect.overlaps(viewport);
  }

  Future<EnvelopeResult> _perform(Envelope envelope, SemanticsAction action, {Object? arguments}) async {
    final owner = _resolveOwner();
    if (owner == null) {
      return EnvelopeResult.failed('no_semantics', 'No semantics owner');
    }
    final resolved = _findNode(envelope.payload, action);
    switch (resolved) {
      case (final SemanticsNode node, null):
        if (actionabilityGate && _gestures.contains(action)) {
          if (await _actionable(owner, node) case final refused?) {
            return EnvelopeResult(status: .failed, error: refused);
          }
        }
        owner.performAction(node.id, action, arguments);
        if (!_movesViewport.contains(action)) {
          return EnvelopeResult.ok({'nodeId': node.id, 'action': action.name});
        }
        // Where the viewport ended up, so the engine's repeat guard can tell a
        // working scroll from a stuck one (ADR 0010).
        await _settle?.call();
        final scrollable = _scrollableAncestor(node);
        final root = _rootNode();
        return EnvelopeResult.ok({
          'nodeId': node.id,
          'action': action.name,
          'scrollPosition': ?scrollable?.getSemanticsData().scrollPosition,
          if (root != null) 'onScreen': _isOnScreen(node, root.rect),
        });
      case (null, final EnvelopeError error):
        return EnvelopeResult(status: .failed, error: error);
      default:
        return EnvelopeResult.failed('internal', 'unreachable');
    }
  }

  /// Text fields expose `setText` only while focused: the bridge focuses the
  /// field so agents address it in one step, and releases the focus so the edit
  /// is *committed*. A form field commonly reports its value only on losing
  /// focus, and `SemanticsAction.tap` is not a pointer event, so no sequence of
  /// semantics actions can produce the blur.
  ///
  /// An overlay tied to the field's focus closes with it; an agent that wants
  /// one taps the field again.
  static const _movesViewport = {
    SemanticsAction.scrollUp,
    SemanticsAction.scrollDown,
    SemanticsAction.scrollLeft,
    SemanticsAction.scrollRight,
    SemanticsAction.showOnScreen,
  };

  /// [node] itself when it scrolls, else its nearest scrolling ancestor.
  static SemanticsNode? _scrollableAncestor(SemanticsNode node) {
    for (SemanticsNode? current = node; current != null;) {
      if (current.getSemanticsData().scrollPosition != null) return current;
      current = current.parent;
    }
    return null;
  }

  Future<EnvelopeResult> _setText(Envelope envelope, String text) async {
    final owner = _resolveOwner();
    if (owner == null) {
      return EnvelopeResult.failed('no_semantics', 'No semantics owner');
    }
    final resolved = _findNode(envelope.payload, SemanticsAction.setText, textFieldFallback: true);
    final node = resolved.$1;
    if (node == null) {
      return EnvelopeResult(status: .failed, error: resolved.$2);
    }
    if (actionabilityGate) {
      if (await _actionable(owner, node) case final refused?) {
        return EnvelopeResult(status: .failed, error: refused);
      }
    }
    for (final focusAction in [SemanticsAction.focus, SemanticsAction.tap]) {
      if (node.getSemanticsData().hasAction(SemanticsAction.setText)) break;
      if (node.getSemanticsData().hasAction(focusAction)) {
        owner.performAction(node.id, focusAction);
        await _settle?.call();
      }
    }
    if (!node.getSemanticsData().hasAction(SemanticsAction.setText)) {
      return EnvelopeResult.failed('unsupported_action', 'Node ${node.id} does not accept setText even after focusing');
    }
    owner.performAction(node.id, SemanticsAction.setText, text);
    await _settle?.call();
    final committed = FocusManager.instance.primaryFocus;
    if (committed != null) {
      committed.unfocus();
      await _settle?.call();
    }
    return EnvelopeResult.ok({
      'nodeId': node.id,
      'action': 'setText',
      // Named in the result because it is a visible effect the agent did not
      // ask for: the field it just edited is no longer focused.
      'committed': committed != null,
    });
  }

  (SemanticsNode?, EnvelopeError?) _findNode(JsonMap payload, SemanticsAction action, {bool textFieldFallback = false}) {
    final root = _rootNode();
    if (root == null) {
      return (null, const EnvelopeError(code: 'no_semantics', message: 'No semantics tree'));
    }
    final nodeId = (payload['nodeId'] as num?)?.toInt();
    final label = payload['label'] as String?;
    if (nodeId == null && label == null) {
      return (null, const EnvelopeError(code: 'bad_payload', message: 'nodeId or label is required'));
    }

    final matches = <SemanticsNode>[];
    void visit(SemanticsNode node) {
      if (!node.isInvisible && !node.isMergedIntoParent) {
        final data = node.getSemanticsData();
        final capable = data.hasAction(action) || (textFieldFallback && data.flagsCollection.isTextField);
        final byId = nodeId != null && node.id == nodeId;
        // Buttons often carry their accessible name as tooltip (e.g.
        // FloatingActionButton/IconButton) — match either.
        final byLabel = nodeId == null && label != null && (data.label == label || data.tooltip == label) && capable;
        if (byId || byLabel) matches.add(node);
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(root);
    if (matches.isEmpty) {
      return (
        null,
        EnvelopeError(
          code: 'not_found',
          message: nodeId != null ? 'No node with id $nodeId' : 'No node with label "$label" supporting ${action.name}',
        ),
      );
    }
    if (matches.length > 1) {
      return (
        null,
        EnvelopeError(
          code: 'ambiguous_label',
          message:
              '${matches.length} nodes match label "$label" — '
              'address by nodeId (ids: ${matches.map((n) => n.id).join(', ')})',
        ),
      );
    }
    final data = matches.single.getSemanticsData();
    if (staleRefCheck && nodeId != null) {
      final seen = _seen[nodeId];
      final now = _signature(matches.single);
      if (seen != null && seen != now) {
        String text(String signature) => signature.split('\u0000').take(3).where((part) => part.isNotEmpty).join(' / ');
        return (
          null,
          EnvelopeError(
            code: 'stale_ref',
            message:
                'Node $nodeId changed since you observed it (was "${text(seen)}", now "${text(now)}") — '
                'observe the tree again before acting on it',
          ),
        );
      }
    }
    if (nodeId != null && !data.hasAction(action) && !(textFieldFallback && data.flagsCollection.isTextField)) {
      return (null, EnvelopeError(code: 'unsupported_action', message: 'Node $nodeId does not support ${action.name}'));
    }
    return (matches.single, null);
  }
}

/// Strips volatile parts (node ids, rects) from a serialized tree — for
/// structural snapshot comparison in reproducibility tests (ADR 0004).
Object? structuralTree(Object? tree) => switch (tree) {
  List() => tree.map(structuralTree).toList(),
  Map() => {
    for (final entry in tree.entries)
      if (entry.key != 'id' && entry.key != 'rect') entry.key as String: structuralTree(entry.value),
  },
  _ => tree,
};
