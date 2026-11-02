import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// An app with a catalogue, two listings, a search, a destructive intent and
/// a user to ask — enough for every decision the loop can ask a decision
/// model about.
final class _FakeApp implements BenchmarkEnvironment {
  _FakeApp({this.userSays = 'yes'});

  final Object? userSays;
  final List<Envelope> handled = [];

  static const catalogue = [
    {'name': 'form.open', 'summary': 'Open a form for filling, by assemblyId and maskId', 'kind': 'act'},
    {'name': 'form.submit', 'summary': 'Submit the open form', 'kind': 'act'},
    {'name': 'form.set', 'summary': 'Set values on the open form', 'kind': 'act'},
    {'name': 'time.status', 'summary': 'Is time tracking running', 'kind': 'observe'},
    {'name': 'app.forms', 'summary': 'Lists the forms of this instance', 'kind': 'observe'},
    {'name': 'app.endpoints', 'summary': 'Lists the data lists (endpoints) of this instance', 'kind': 'observe'},
    {
      'name': 'data.search',
      'summary': 'Search entries of one endpoint (its endpointId from app.endpoints)',
      'kind': 'observe',
      'aliases': ['Suche'],
    },
  ];

  @override
  Future<EnvironmentDescriptor> describe() async => const EnvironmentDescriptor(
    environmentId: 'fake-app',
    envelopes: [
      EnvelopeSpec(key: 'intents.catalog', kind: .observe),
      EnvelopeSpec(key: 'intents.describe', kind: .observe),
      EnvelopeSpec(key: 'intents.invoke', kind: .act),
      EnvelopeSpec(key: 'user.ask', kind: .act, blocksOnUser: true),
    ],
  );

  @override
  Future<void> reset(FixtureRef fixture) async => handled.clear();

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    handled.add(envelope);
    switch (envelope.key) {
      case 'intents.catalog':
        return EnvelopeResult.ok({'intents': catalogue});
      case 'intents.describe':
        final wanted = {for (final raw in envelope.payload['names'] as List? ?? const []) '$raw'};
        return EnvelopeResult.ok({
          'intents': [
            for (final intent in catalogue)
              if (wanted.contains(intent['name']))
                <String, Object?>{...intent, 'description': intent['summary'], 'paramsSchema': const <String, Object?>{}},
          ],
        });
      case 'user.ask':
        return EnvelopeResult.ok({'question': envelope.payload, 'answer': userSays});
      case 'intents.invoke':
        return switch (envelope.payload['intent']) {
          'app.forms' => EnvelopeResult.ok({
            'forms': [
              {'maskId': 64, 'name': 'Anforderung'},
              {'maskId': 12, 'name': 'Serviceauftrag'},
            ],
          }),
          'app.endpoints' => EnvelopeResult.ok({
            'endpoints': [
              {'id': 4, 'name': 'Kontakte'},
              {'id': 7, 'name': 'Artikel'},
              {'id': 9, 'name': 'Projekte'},
            ],
          }),
          'data.search' => EnvelopeResult.ok({
            'endpointId': asJsonMap(envelope.payload['params'])['endpointId'],
            'hits': [
              {'id': 'A4711', 'text': 'Geberit Rohr 65'},
            ],
          }),
          _ => EnvelopeResult.ok({'ok': true}),
        };
      default:
        return EnvelopeResult.unsupported(envelope.key);
    }
  }

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async => const FinalStateSnapshot(results: []);
}

TaskSpec _task([String instruction = 'Submit the Anforderung form.']) => TaskSpec(
  id: 'task',
  title: 'task',
  instruction: instruction,
  budget: const Budget(maxSteps: 10, maxWallClockSeconds: 30),
  fixture: const FixtureRef(id: 'fx', data: {}),
);

final _meta = EpisodeMeta(
  runId: 'r',
  episodeId: 'e',
  taskId: 'task',
  agentId: 'hybrid',
  environmentId: 'fake-app',
  repetition: 1,
  startedAt: DateTime.utc(2026, 9, 23),
);

Future<EpisodeRunResult> _run(ToolLoopAgent agent, _FakeApp app, {TaskSpec? task}) =>
    BenchmarkEngine().runEpisode(task: task ?? _task(), agent: agent, environment: app, meta: _meta);

List<AgentDecision> _decisionsOf(EpisodeRunResult result) => [
  for (final x in result.trace.exchanges()) AgentDecision.fromJson(asJsonMap(x.envelope.data['decision'])),
];

List<JsonMap> _records(EpisodeRunResult result) => [
  for (final d in _decisionsOf(result))
    for (final raw in d.extra?[DecisionRecord.key] as List? ?? const []) asJsonMap(raw),
];

/// A hybrid agent with a `decisions:` block, built the way the harness and
/// the app build it.
ToolLoopAgent _agent(FakeLlmClient llm, FakeJevClient jev, JsonMap decisions, {String agent = 'hybrid', JsonMap extra = const {}}) =>
    AgentProfile.build(
      agent,
      {
        'router': {
          'router': 'union',
          'strategies': ['intents', 'user'],
          'bootstrap': 'intents.catalog',
        },
        'decisions': {
          'client': {'backend': 'ollama', 'model': 'qwen3:4b'},
          ...decisions,
        },
        ...extra,
      },
      client: llm,
      decisions: AgentDecisions.fromJson({'client': const <String, Object?>{}, ...decisions}, clientFor: (_) => jev),
    );

void main() {
  group('completion check', () {
    FakeLlmClient twoDones() => FakeLlmClient(
      responses: [
        FakeLlmClient.calls([
          ('done', {'summary': 'Submitted.'}),
        ]),
        FakeLlmClient.calls([('intent_form_submit', <String, Object?>{})]),
        FakeLlmClient.calls([
          ('done', {'summary': 'Submitted, the form shows it.'}),
        ]),
      ],
    );

    test('sends a done back when the goal does not hold, once', () async {
      final llm = twoDones();
      final jev = FakeJevClient(noul: 0.1, latencyMs: 40);
      final agent = _agent(llm, jev, {
        'completionCheck': {'threshold': 0.5, 'maxRejections': 1},
      });
      final result = await _run(agent, _FakeApp());

      expect(result.outcome.reason, TerminationReason.done);
      // The model heard why, as the done call's tool result.
      final rejected = llm.requests[1].messages.where((m) => m.role == .tool && m.content.contains('completion check'));
      expect(rejected, hasLength(1));
      // One check: the second done is past the limit and goes out unchecked.
      expect(jev.requests, hasLength(1));
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.single, containsPair('purpose', 'completion'));
      expect(records.single, containsPair('verdict', 'reject'));
      // The check's spend is a side call, priced at the decider's model.
      final sideCalls = [for (final d in _decisionsOf(result)) ...d.sideCalls];
      expect(sideCalls.map((c) => (c.purpose, c.model, c.latencyMs)), [('completion', 'fake-jev', 40)]);
    });

    test('lets a done through when the goal holds', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            ('done', {'summary': 'Done.'}),
          ]),
        ],
      );
      final result = await _run(
        _agent(llm, FakeJevClient(noul: 0.9), {
          'completionCheck': {'threshold': 0.5},
        }),
        _FakeApp(),
      );
      expect(result.outcome.reason, TerminationReason.done);
      expect(_records(result).single, containsPair('verdict', 'accept'));
    });

    test('a decision model that fails lets the done through and says so', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            ('done', {'summary': 'Done.'}),
          ]),
        ],
      );
      final result = await _run(
        _agent(llm, FakeJevClient(error: Exception('connection refused')), {'completionCheck': <String, Object?>{}}),
        _FakeApp(),
      );
      expect(result.outcome.reason, TerminationReason.done);
      expect(_records(result).single, containsPair('verdict', 'error'));
    });

    test('the check reads the task, the results and the claim', () async {
      final jev = FakeJevClient(noul: 0.9);
      await _run(
        _agent(
          FakeLlmClient(
            responses: [
              FakeLlmClient.calls([
                ('done', {'summary': 'Formular abgeschickt.'}),
              ]),
            ],
          ),
          jev,
          {'completionCheck': <String, Object?>{}},
        ),
        _FakeApp(),
        task: _task('Schicke das Formular Anforderung ab.'),
      );
      final state = (jev.requests.single.state as JevText).text;
      expect(state, contains('Task: Schicke das Formular Anforderung ab.'));
      expect(state, contains('The assistant reports: Formular abgeschickt.'));
      // Asked in the task's language.
      expect((jev.requests.single.questions['done']! as JevNoul).instructions, contains('Ziel'));
    });
  });

  group('action guard', () {
    FakeLlmClient submitThenDone() => FakeLlmClient(
      responses: [
        FakeLlmClient.calls([
          (
            'describe_intents',
            {
              'names': ['form.submit', 'form.set'],
            },
          ),
        ]),
        FakeLlmClient.calls([('intent_form_submit', <String, Object?>{})]),
        FakeLlmClient.calls([
          ('done', {'summary': 'ok'}),
        ]),
      ],
    );

    bool submitted(_FakeApp app) => app.handled.any((e) => e.key == 'intents.invoke' && e.payload['intent'] == 'form.submit');

    test('stops a covered action it judges unwanted', () async {
      final llm = submitThenDone();
      final app = _FakeApp();
      final result = await _run(
        _agent(llm, FakeJevClient(noul: 0.1), {
          'guard': {
            'intents': ['form.submit'],
          },
        }),
        app,
      );
      expect(submitted(app), isFalse);
      expect(llm.requests[2].messages.last.content, contains('action guard'));
      expect(_records(result).single, allOf(containsPair('verdict', 'deny'), containsPair('subject', 'form.submit')));
    });

    test('reviews only what it covers', () async {
      final jev = FakeJevClient(noul: 0.1);
      await _run(
        _agent(submitThenDone(), jev, {
          'guard': {
            'intents': ['form.set'],
          },
        }),
        _FakeApp(),
      );
      expect(jev.requests, isEmpty);
    });

    test('in shadow mode records and lets everything run', () async {
      final app = _FakeApp();
      final result = await _run(
        _agent(submitThenDone(), FakeJevClient(noul: 0.1), {
          'guard': {'mode': 'shadow'},
        }),
        app,
      );
      expect(submitted(app), isTrue);
      expect(_records(result).single, allOf(containsPair('verdict', 'deny'), containsPair('enforced', false)));
    });

    test('asks the user when unsure, and acts on a yes', () async {
      final app = _FakeApp(userSays: 'ja');
      await _run(
        _agent(submitThenDone(), FakeJevClient(noul: 0.5), {
          'guard': {'onConfirm': 'ask'},
        }),
        app,
      );
      final keys = [for (final e in app.handled) e.key == 'intents.invoke' ? e.payload['intent'] : e.key];
      expect(keys, containsAllInOrder(['user.ask', 'form.submit']));
      expect(app.handled.firstWhere((e) => e.key == 'user.ask').payload['type'], 'confirm');
    });

    test('and does not act on a no', () async {
      final llm = submitThenDone();
      final app = _FakeApp(userSays: false);
      await _run(
        _agent(llm, FakeJevClient(noul: 0.5), {
          'guard': {'onConfirm': 'ask'},
        }),
        app,
      );
      expect(submitted(app), isFalse);
      expect(llm.requests.last.messages.last.content, contains('did not'));
    });
  });

  group('preparation with a decision model', () {
    /// True for the candidates whose id is one of [wanted] or whose
    /// description mentions one. Row ids carry their listing's name
    /// (`app.forms#1`), so the id is compared whole, never searched.
    double Function(String) relevant(List<String> wanted) => (text) {
      // English or German statement, whichever the task's language asked.
      final marker = RegExp('(Candidate|Kandidat): ').firstMatch(text)!;
      final candidate = text.substring(marker.end);
      final split = candidate.indexOf(' — ');
      final id = split < 0 ? candidate : candidate.substring(0, split);
      final description = split < 0 ? '' : candidate.substring(split);
      return wanted.contains(id) || wanted.any(description.contains) ? 0.9 : 0.1;
    };

    JsonMap preparation({List<String> prepare = const ['tools', 'discovery'], JsonMap extra = const {}}) => {
      'preparation': {
        'strategy': 'jev',
        'prepare': prepare,
        'topK': 3,
        'discoveryKeys': ['app.forms', 'app.endpoints'],
        'discoveryQuery': 'none',
        ...extra,
      },
    };

    FakeLlmClient answer() => FakeLlmClient(
      responses: [
        FakeLlmClient.calls([
          ('done', {'summary': 'ok'}),
        ]),
      ],
    );

    test('promotes the intents it judges needed and fetches only the relevant listing', () async {
      final app = _FakeApp();
      final jev = FakeJevClient(noulFor: relevant(['form.open', 'app.forms', 'Anforderung']));
      final result = await _run(_agent(answer(), jev, const {}, agent: 'prepared', extra: preparation()), app);

      final describe = app.handled.firstWhere((e) => e.key == 'intents.describe');
      expect(describe.payload['names'], ['form.open', 'app.forms']);
      final listings = [
        for (final e in app.handled)
          if (e.key == 'intents.invoke') e.payload['intent'],
      ];
      expect(listings, ['app.forms']);
      // discoveryQuery: none — the whole listing, the decision model selects.
      expect(asJsonMap(app.handled.firstWhere((e) => e.key == 'intents.invoke').payload['params']), isEmpty);
      final sideCalls = [for (final d in _decisionsOf(result)) ...d.sideCalls];
      expect(sideCalls.map((c) => c.purpose), containsAll(['select-tools', 'select-rows']));
      // Each candidate's noul is on the record, so a threshold replays.
      final selectTools = [
        for (final d in _decisionsOf(result))
          for (final r in asJsonMap(d.extra)[DecisionRecord.key] as List? ?? const [])
            if (asJsonMap(r)['purpose'] == 'select-tools') asJsonMap(r),
      ];
      expect(asJsonMap(selectTools.single['scores']), allOf(containsPair('form.open', greaterThanOrEqualTo(0.5)), hasLength(greaterThan(1))));
    });

    test('keeps only the rows it judges needed, possibly none', () async {
      final llm = answer();
      await _run(
        _agent(
          llm,
          FakeJevClient(noulFor: relevant(['app.forms', 'Anforderung'])),
          const {},
          agent: 'prepared',
          extra: preparation(),
        ),
        _FakeApp(),
      );
      final briefing = llm.requests.first.messages.lastWhere((m) => m.content.startsWith('Preparation:')).content;
      expect(briefing, contains('Anforderung'));
      expect(briefing, isNot(contains('Serviceauftrag')));
      expect(briefing, contains('and 1 more'));
      expect(briefing, contains('app.endpoints (judged not needed for this task)'));
    });

    test('fetches from the data list it kept', () async {
      final app = _FakeApp();
      final llm = answer();
      await _run(
        _agent(
          llm,
          FakeJevClient(noulFor: relevant(['app.endpoints', 'Artikel', 'data.search', 'Geberit'])),
          const {},
          agent: 'prepared',
          extra: preparation(
            prepare: const ['tools', 'discovery', 'fetch'],
            extra: {
              'budget': {'maxEnvelopes': 6},
              'fetch': [
                {
                  'after': 'app.endpoints',
                  'intent': 'data.search',
                  'params': {'endpointId': '{row.id}', 'query': '{query}', 'limit': 5},
                },
              ],
            },
          ),
        ),
        app,
        task: _task('Füge 5m Geberit Rohr aus den Artikeln hinzu.'),
      );
      final search = app.handled.lastWhere((e) => e.key == 'intents.invoke' && e.payload['intent'] == 'data.search');
      // The row's id, as an integer, and the task's longest word.
      expect(asJsonMap(search.payload['params']), {'endpointId': 7, 'query': 'artikeln', 'limit': 5});
      final briefing = llm.requests.first.messages.lastWhere((m) => m.content.startsWith('Preparation:')).content;
      expect(briefing, contains('A4711'));
    });

    test('never fetches through an act', () async {
      final app = _FakeApp();
      final llm = answer();
      await _run(
        _agent(
          llm,
          FakeJevClient(noulFor: relevant(['app.endpoints', 'Artikel'])),
          const {},
          agent: 'prepared',
          extra: preparation(
            prepare: const ['discovery', 'fetch'],
            extra: {
              'fetch': [
                {'after': 'app.endpoints', 'intent': 'form.submit'},
              ],
            },
          ),
        ),
        app,
        task: _task('Welche Artikel gibt es?'),
      );
      expect(app.handled.where((e) => e.payload['intent'] == 'form.submit'), isEmpty);
      final briefing = llm.requests.first.messages.lastWhere((m) => m.content.startsWith('Preparation:')).content;
      expect(briefing, contains('fetch only reads'));
    });

    test('the relevant hatch keeps the rest reachable by name', () async {
      final llm = answer();
      await _run(
        _agent(
          llm,
          FakeJevClient(noulFor: relevant(['form.open'])),
          const {},
          agent: 'prepared',
          extra: preparation(prepare: const ['tools'], extra: {'escapeHatchScope': 'relevant'}),
        ),
        _FakeApp(),
      );
      final briefing = llm.requests.first.messages.lastWhere((m) => m.content.startsWith('Preparation:')).content;
      expect(briefing, contains('- form.open: Open a form'));
      expect(briefing, isNot(contains('- time.status:')));
      expect(briefing, contains('judged unrelated to this task (names only): form.submit, form.set, time.status'));
    });

    test('a floor keeps the best intents whatever their noul', () async {
      final app = _FakeApp();
      await _run(
        _agent(
          answer(),
          FakeJevClient(noulFor: (text) => text.contains('form.open') ? 0.45 : (text.contains('time.status') ? 0.3 : 0.1)),
          const {
            'selection': {'threshold': 0.5, 'minKeep': 2},
          },
          agent: 'prepared',
          extra: preparation(prepare: const ['tools']),
        ),
        app,
      );
      // Nothing reaches 0.5; the two best are kept anyway, best first.
      expect(app.handled.firstWhere((e) => e.key == 'intents.describe').payload['names'], ['form.open', 'time.status']);
    });

    test('references expansion adds the intents a kept intent names', () async {
      final app = _FakeApp();
      await _run(
        _agent(
          answer(),
          FakeJevClient(noulFor: relevant(['data.search'])),
          const {
            'selection': {'expand': 'references'},
          },
          agent: 'prepared',
          extra: preparation(prepare: const ['tools']),
        ),
        app,
        task: _task('Suche den Artikel Geberit.'),
      );
      expect(app.handled.firstWhere((e) => e.key == 'intents.describe').payload['names'], ['data.search', 'app.endpoints']);
    });

    test('the selection prompt is the configured one', () async {
      final jev = FakeJevClient(noul: 0.9);
      await _run(
        _agent(
          answer(),
          jev,
          const {
            'selection': {'prompt': 'call_rubric_state_v1'},
          },
          agent: 'prepared',
          extra: preparation(prepare: const ['tools']),
        ),
        _FakeApp(),
      );
      final request = jev.requests.first;
      expect((request.state as JevText).text, 'A user asks the assistant of a business app: "Submit the Anforderung form."');
      final question = request.questions.values.first as JevNoul;
      expect(question.instructions, startsWith('To carry out the request, an assistant would call the tool form.open'));
      expect(question.ifFalse, 'The tool is about something the request does not touch.');
    });

    test('the hint names the prepared intents as callable', () async {
      final llm = answer();
      await _run(
        _agent(
          llm,
          FakeJevClient(noulFor: relevant(['form.open'])),
          const {},
          agent: 'prepared',
          extra: preparation(prepare: const ['tools'], extra: {'preparedHint': true}),
        ),
        _FakeApp(),
      );
      final briefing = llm.requests.first.messages.lastWhere((m) => m.content.startsWith('Preparation:')).content;
      expect(briefing, contains('call these tools directly, without describe_intents: intent_form_open (form.open).'));
      // Without the shared layout the schemas stay in the briefing.
      expect(briefing, contains('intents.describe: '));
    });

    test('the shared layout puts the task last, the prepared tools last, and warms the prefix', () async {
      final llm = answer();
      await _run(
        _agent(
          llm,
          FakeJevClient(noulFor: relevant(['form.open'])),
          const {},
          agent: 'prepared',
          extra: preparation(prepare: const ['tools'], extra: {'layout': 'shared'}),
        ),
        _FakeApp(),
      );
      final request = llm.requests.first;
      final names = [for (final tool in request.tools) tool.name];
      expect(names.last, 'intent_form_open');
      expect(names.take(names.length - 1).where((n) => n.startsWith('intent_')), isEmpty);
      final users = [
        for (final m in request.messages)
          if (m.role == .user) m.content,
      ];
      expect(users.first, isNot(contains('Task:')));
      expect(users.last, 'Task: Submit the Anforderung form.');
      final briefing = users.firstWhere((m) => m.startsWith('Preparation:'));
      expect(briefing, isNot(contains('intents.describe: ')));
      expect(briefing, contains('intent_form_open (form.open)'));

      // After the episode: the system prompt and the framework tools, once.
      final warmed = llm.warmedPrefixes.single;
      expect(warmed.messages.single.role, LlmRole.system);
      expect(warmed.messages.single.content, request.messages.first.content);
      expect([for (final tool in warmed.tools) tool.name], names.take(names.length - 1));
    });

    test('a cap keeps no more than the best maxKeep, before references are added', () async {
      final app = _FakeApp();
      await _run(
        _agent(
          answer(),
          FakeJevClient(noul: 0.9),
          const {
            'selection': {'minKeep': 1, 'maxKeep': 2},
          },
          agent: 'prepared',
          extra: preparation(prepare: const ['tools']),
        ),
        app,
      );
      expect(app.handled.firstWhere((e) => e.key == 'intents.describe').payload['names'], hasLength(2));
      expect(() => SelectionConfig.fromJson({'minKeep': 5, 'maxKeep': 3}), throwsFormatException);
      expect(SelectionConfig.fromJson(const {}).toJson(), isNot(contains('maxKeep')), reason: 'earlier arms keep their hash');
    });

    test('sharedListing moves the envelope listing into the shared prefix and the prepared intents out of the hatch', () async {
      final llm = answer();
      await _run(
        _agent(
          llm,
          FakeJevClient(noulFor: relevant(['form.open'])),
          const {},
          agent: 'prepared',
          extra: preparation(prepare: const ['tools'], extra: {'layout': 'sharedListing'}),
        ),
        _FakeApp(),
      );
      final request = llm.requests.first;
      final system = request.messages.first.content;
      expect(system, contains('supports these envelope keys:'));
      final users = [
        for (final m in request.messages)
          if (m.role == .user) m.content,
      ];
      expect(users.any((m) => m.contains('supports these envelope keys:')), isFalse);
      expect(users.last, 'Task: Submit the Anforderung form.');
      final briefing = users.firstWhere((m) => m.startsWith('Preparation:'));
      expect(briefing, contains('intent_form_open (form.open)'));
      expect(briefing, contains('Every other intent in scope.'));
      expect(briefing, isNot(contains('- form.open:')));
      expect(briefing, contains('- form.submit:'));
      // The prime covers the listing too, so the next task restores it.
      expect(llm.warmedPrefixes.single.messages.single.content, system);
    });

    test('a decision model that fails prepares everything it would have ranked', () async {
      final app = _FakeApp();
      final llm = answer();
      await _run(
        _agent(
          llm,
          FakeJevClient(error: Exception('down')),
          const {},
          agent: 'prepared',
          extra: preparation(prepare: const ['tools']),
        ),
        app,
      );
      expect(app.handled.firstWhere((e) => e.key == 'intents.describe').payload['names'], hasLength(3));
    });
  });

  group('config', () {
    test('refuses what it does not implement', () {
      expect(() => DecisionsConfig.fromJson({'completion': <String, Object?>{}}), throwsFormatException);
      expect(
        () => DecisionsConfig.fromJson({
          'guard': {'mode': 'strict'},
        }),
        throwsFormatException,
      );
      expect(
        () => DecisionsConfig.fromJson({
          'guard': {'allowAbove': 0.3, 'denyBelow': 0.7},
        }),
        throwsFormatException,
      );
      expect(
        () => PreparationConfig.fromJson({
          'strategy': 'jev',
          'prepare': ['fetch'],
        }),
        throwsFormatException,
      );
    });

    test('a jev preparer without a decision model is refused', () {
      expect(
        () => AgentProfile.build('prepared', {
          'preparation': {'strategy': 'jev'},
        }, client: FakeLlmClient()),
        throwsArgumentError,
      );
    });

    test('decisions ride in the manifest, so they identify the arm', () {
      final agent = _agent(FakeLlmClient(), FakeJevClient(), {'completionCheck': <String, Object?>{}});
      final metadata = agent.manifest.metadata;
      expect(asJsonMap(metadata['configBlocks']).keys, contains('decisions'));
      expect(metadata['decisionModel'], 'fake-jev');
    });

    test('an existing selection config keeps its hash', () {
      const json = {'threshold': 0.5, 'perRequest': 50, 'maxRowChars': 400};
      expect(SelectionConfig.fromJson(json).toJson(), json);
      final tuned = SelectionConfig.fromJson({
        'threshold': 0.4,
        'minKeep': 5,
        'prompt': 'call_rubric_state_v1',
        'expand': 'references',
        'candidateText': 'summary',
      });
      expect(tuned.toJson(), containsPair('prompt', 'call_rubric_state_v1'));
      expect(SelectionConfig.fromJson(tuned.toJson()).toJson(), tuned.toJson());
      expect(() => SelectionConfig.fromJson({'prompt': 'nope'}), throwsArgumentError);
      expect(() => SelectionConfig.fromJson({'expand': 'all'}), throwsFormatException);
    });

    test('an existing preparation config keeps its hash', () {
      // The new keys are written only when set: every arm run before them
      // must still hash the same.
      const json = {
        'strategy': 'lexical',
        'prepare': ['tools', 'discovery'],
        'topK': 5,
        'minScore': 0.25,
        'discoveryKeys': ['app.forms', 'app.endpoints'],
        'queryParam': 'query',
        'budget': {'maxEnvelopes': 4, 'maxBriefingBytes': 4096},
        'escapeHatch': true,
      };
      expect(PreparationConfig.fromJson(json).toJson(), json);
    });
  });

  group('decision metrics', () {
    test('count what the loop decided, from the trace', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            ('done', {'summary': 'x'}),
          ]),
          FakeLlmClient.calls([
            ('done', {'summary': 'y'}),
          ]),
        ],
      );
      final result = await _run(
        _agent(llm, FakeJevClient(noul: 0.1, latencyMs: 30), {
          'completionCheck': {'maxRejections': 1},
        }),
        _FakeApp(),
      );
      final record = await RunEvaluation(metrics: MetricsRegistry.builtin(providers: [decisionMetrics])).evaluateEpisode(result.trace, _task());
      expect(record.metrics['completion_check_count'], 1);
      expect(record.metrics['completion_rejections'], 1);
      expect(record.metrics['completion_rejected'], 1);
      expect(record.metrics['decision_latency_ms'], 30);
      // No guard configured: not measured, rather than zero.
      expect(record.metrics['guard_review_count'], isNull);
    });
  });
}
