import 'package:aib_jev/aib_jev.dart';
import 'package:aib_jev/testing.dart';
import 'package:test/test.dart';

enum Tier { local, cloud, human }

void main() {
  group('detectLanguage', () {
    test('short app instructions in the suites\' two languages', () {
      expect(detectLanguage('Lösche alle erledigten Aufgaben.'), 'de');
      expect(detectLanguage('Zeig mir die Artikel.'), 'de');
      expect(detectLanguage('Benenne das Projekt "Urlaub 2026" in "Sommerurlaub" um.'), 'de');
      expect(detectLanguage('How many Artikel are there?'), 'en');
      expect(detectLanguage('Mark the todo "Existing" as completed.'), 'en');
    });

    test('quoted names do not decide the language', () {
      expect(detectLanguage('Create a new activity with the subject "Wartung Heizung für die Halle".'), 'en');
      expect(detectLanguage('Lege die Aufgabe "Buy the milk and the bread" an.'), 'de');
    });

    test('says nothing rather than guessing', () {
      expect(detectLanguage('Ada Lovelace, ada@example.com'), isNull);
      expect(detectLanguage(''), isNull);
      expect(detectLanguage('Créer une nouvelle tâche pour le client'), 'fr');
      expect(detectLanguage('Lösche den Kunden', among: ['en']), isNull);
    });

    test('policies: fixed, or the state\'s language with a fallback', () {
      expect(const JevLanguagePolicy.fixed('de').resolve('Delete the todo.'), 'de');
      expect(const JevLanguagePolicy.matchState().resolve('Lösche die Aufgabe.'), 'de');
      expect(const JevLanguagePolicy.matchState(fallback: 'de').resolve('x@y.z'), 'de');
      expect(JevLanguagePolicy.parse('auto').name, 'auto');
    });

    test('localized texts fall back explicitly', () {
      const texts = JevLocalized({'en': 'hello', 'de': 'hallo'});
      expect(texts.of('de'), 'hallo');
      expect(texts.of('fr'), 'hello');
      expect(texts.has('fr'), isFalse);
      expect(() => const JevLocalized({'de': 'x'}, fallback: 'en').of('fr'), throwsArgumentError);
    });
  });

  group('enum choices', () {
    test('an enum-typed choice decodes to its value and stays a JevChoice', () async {
      final question = JevChoice.ofEnum(Tier.values, instructions: 'Who?', describe: (t) => t == .human ? 'escalate' : null);
      expect(question.criteria, {'local': null, 'cloud': null, 'human': 'escalate'});
      final JevQuestion<JevAnswer> asQuestion = question;
      expect(switch (asQuestion) {
        JevChoice() => 'choice',
        JevScore() => 'score',
        JevNoul() => 'noul',
      }, 'choice');

      final client = FakeJevClient(probabilities: {'local': 0.2, 'cloud': 0.7, 'human': 0.1});
      final picked = await client.chooseEnum(state: const JevState.text('x'), question: question);
      expect(picked.value, Tier.cloud);

      final set = JevQuestionSet();
      final ref = set.addEnum('tier', question);
      final response = await client.decide(JevRequest.of(state: const JevState.text('x'), questions: set));
      expect(ref.valueIn(response), Tier.cloud);
      expect(ref.probabilitiesIn(response)[Tier.local], 0.2);
    });

    test('an answer naming no value is a mismatch, not a default', () {
      final question = JevChoice.ofEnum(Tier.values, instructions: 'Who?');
      expect(() => question.decode(const JevChoiceAnswer(choice: 'robot', confidence: 1, probabilities: {})), throwsA(isA<JevAnswerMismatch>()));
    });
  });

  group('JevRouter', () {
    JevRouter<Tier> router(FakeJevClient client, {Tier? preferred, double threshold = 0.5}) => JevRouter(
      client: client,
      values: Tier.values,
      instructions: const JevLocalized({'en': 'Who should handle it?', 'de': 'Wer soll es erledigen?'}),
      criteria: const JevLocalized({
        'en': {Tier.local: 'small model', Tier.cloud: 'big model', Tier.human: 'a person'},
        'de': {Tier.local: 'kleines Modell', Tier.cloud: 'großes Modell', Tier.human: 'ein Mensch'},
      }),
      language: const JevLanguagePolicy.matchState(),
      preferred: preferred,
      threshold: threshold,
    );

    test('asks in the state\'s language and returns the enum value', () async {
      final client = FakeJevClient(probabilities: {'local': 0.1, 'cloud': 0.6, 'human': 0.3});
      final routing = await router(client).route(const JevState.text('Lösche alle erledigten Aufgaben.'));
      expect(routing.route, Tier.cloud);
      expect(routing.language, 'de');
      final asked = client.requests.single.questions['route']! as JevChoice;
      expect(asked.instructions, 'Wer soll es erledigen?');
      expect(asked.criteria['human'], 'ein Mensch');
    });

    test('stays on the preferred side at the threshold, else takes the likeliest other', () async {
      final client = FakeJevClient(probabilities: {'local': 0.45, 'cloud': 0.2, 'human': 0.35});
      expect((await router(client, preferred: .local, threshold: 0.4).route(const JevState.text('x'))).route, Tier.local);
      expect((await router(client, preferred: .local, threshold: 0.5).route(const JevState.text('x'))).route, Tier.human);
    });
  });

  group('JevCompletionCheck', () {
    test('a German goal gets the German statement, and the threshold decides', () async {
      final client = FakeJevClient(noul: 0.62);
      final check = JevCompletionCheck(client: client, threshold: 0.6);
      final result = await check.check(goal: 'Lösche die Aufgabe "Arzt anrufen".', state: const JevState.json({'todos': <Object?>[]}));
      expect(result.done, isTrue);
      expect(result.language, 'de');
      final asked = client.requests.single.questions['done']! as JevNoul;
      expect(asked.instructions, startsWith('Das folgende Ziel ist im Zustand vollständig erreicht'));
      expect(asked.instructions, endsWith('Ziel: Lösche die Aufgabe "Arzt anrufen".'));
      expect((await JevCompletionCheck(client: client, threshold: 0.7).check(goal: 'x', state: const JevState.text('y'))).done, isFalse);
    });
  });

  group('JevSelector', () {
    test('judges every candidate, ranks by noul and keeps what reaches the threshold', () async {
      final logits = FakeJevLogits((prompt) {
        // The rating the model "gives" rises with the candidate's number.
        final last = prompt.turns.last.content;
        final n = int.parse(RegExp(r'Candidate: t(\d)').firstMatch(last)![1]!);
        return [for (var i = 0; i < 9; i++) i == n ? 5.0 : 0.0];
      });
      final selector = JevSelector(
        client: LogitJevClient(logits: logits),
        language: const JevLanguagePolicy.fixed('en'),
      );
      final selection = await selector.select(
        state: const JevState.text('Delete the done todos.'),
        candidates: {'t1': 'create a todo', 't7': 'delete todos', 't4': 'list todos'},
        threshold: 0.4,
      );
      expect(selection.scores.keys, ['t7', 't4', 't1']);
      expect(selection.selected, ['t7', 't4']);
      // One request, three noul branches over the shared prefix.
      expect(logits.prompts, hasLength(3));
    });
  });

  group('JevSelectionPrompt', () {
    test('asks its statement and rubric about the task in its framing, and keeps a floor', () async {
      final jev = FakeJevClient(noulFor: (text) => text.contains('t7') ? 0.45 : 0.1);
      final selection = await JevSelector(
        client: jev,
        prompt: JevSelectionPrompt.fromJson({
          'id': 'probe',
          'statement': {'en': 'Would call {id}: {description}', 'de': 'Würde {id} aufrufen: {description}'},
          'ifTrue': 'yes',
          'state': {'en': 'Request: {task}', 'de': 'Anfrage: {task}'},
        }),
        language: const JevLanguagePolicy.fixed('de'),
      ).selectFor(task: 'Lösche die Todos.', candidates: {'t1': 'create', 't7': 'delete'}, threshold: 0.5, minKeep: 1);
      expect(selection.selected, ['t7']);
      final request = jev.requests.single;
      expect((request.state as JevText).text, 'Anfrage: Lösche die Todos.');
      final question = request.questions.values.first as JevNoul;
      expect(question.instructions, 'Würde t1 aufrufen: create');
      expect(question.ifTrue, 'yes');
      expect(question.ifFalse, isNull);
    });

    test('an id alone names a built-in prompt, and an unknown one is refused', () {
      expect(JevSelectionPrompt.fromJson({'id': 'call_rubric_state_v1'}), same(JevSelectionPrompt.callRubricStateV1));
      expect(() => JevSelectionPrompt.fromJson({'id': 'nope'}), throwsArgumentError);
    });
  });

  group('JevGuard', () {
    test('three outcomes from two thresholds', () async {
      Future<JevGuardVerdict> verdict(double noul) async => (await JevGuard(
        client: FakeJevClient(noul: noul),
      ).review(action: 'delete_todo(id: 4)', state: const JevState.text('Delete todo 4.'))).verdict;
      expect(await verdict(0.9), JevGuardVerdict.allow);
      expect(await verdict(0.5), JevGuardVerdict.confirm);
      expect(await verdict(0.1), JevGuardVerdict.deny);
    });
  });
}
