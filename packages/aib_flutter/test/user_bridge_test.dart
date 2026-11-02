import 'package:aib_core/ports.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('user.ask', () {
    test('a scripted answer round-trips and reports the wait', () async {
      final scripted = ScriptedUserAnswerer(answers: {'Which article': 'A4711'});
      final environment = FlutterEnvironment(environmentId: 'test');
      UserBridge(answerer: scripted.call).install(environment);

      final result = await environment.handle(
        const Envelope(
          key: 'user.ask',
          kind: .act,
          payload: {
            'type': 'pick',
            'prompt': 'Which article did you mean?',
            'metadata': {'endpointId': 12},
          },
        ),
      );
      expect(result.status, EnvelopeStatus.ok);
      expect(result.payload['answer'], 'A4711');
      expect(result.userWaitMs, isNotNull);
      expect(scripted.asked.single.metadata['endpointId'], 12);
    });

    test('confirmations default to yes', () async {
      final scripted = ScriptedUserAnswerer();
      final environment = FlutterEnvironment(environmentId: 'test');
      UserBridge(answerer: scripted.call).install(environment);

      final result = await environment.handle(
        const Envelope(key: 'user.ask', kind: .act, payload: {'type': 'confirm', 'prompt': 'Submit the order?'}),
      );
      expect(result.payload['answer'], isTrue);
    });

    test('an unanticipated question fails instead of defaulting silently', () async {
      final scripted = ScriptedUserAnswerer();
      final environment = FlutterEnvironment(environmentId: 'test');
      UserBridge(answerer: scripted.call).install(environment);

      final result = await environment.handle(
        const Envelope(key: 'user.ask', kind: .act, payload: {'type': 'text', 'prompt': 'What is the customer number?'}),
      );
      // A silent default would let an agent pass a task by asking something
      // the fixture never anticipated, and the metrics would show nothing.
      expect(result.status, EnvelopeStatus.failed);
      expect(result.error!.code, 'no_scripted_answer');
      expect(scripted.unanswered, hasLength(1));
    });

    test('the spec declares that it blocks on a human', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      UserBridge(answerer: ScriptedUserAnswerer().call).install(environment);
      final descriptor = await environment.describe();
      final spec = descriptor.envelopes.firstWhere((s) => s.key == 'user.ask');
      // This is what tells the engine not to race a person against the
      // agent's wall-clock budget.
      expect(spec.blocksOnUser, isTrue);
    });

    test('a malformed ask is rejected before a dialog is shown', () async {
      var asked = 0;
      final environment = FlutterEnvironment(environmentId: 'test');
      UserBridge(
        answerer: (q) async {
          asked++;
          return const UserAnswer('x');
        },
      ).install(environment);

      final result = await environment.handle(const Envelope(key: 'user.ask', kind: .act, payload: {'type': 'interrogate', 'prompt': 'hi'}));
      expect(result.error!.code, 'bad_params');
      expect(asked, 0, reason: 'the user is not bothered by a malformed ask');
    });
  });
}
