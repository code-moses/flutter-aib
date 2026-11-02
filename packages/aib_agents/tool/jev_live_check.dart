import 'package:aib_agents/agents.dart';

Future<void> main(List<String> args) async {
  final client = HttpJevClient(model: args.isEmpty ? 'Qwen/Qwen3.5-4B' : args[0]);
  final decider = JevRouteDecider(client: client);
  for (final task in [
    'Wie viele Artikel gibt es?',
    'Open the article "LohnMonteur".',
    'Lege einen neuen Lieferanten an, aber nur falls es noch keinen mit '
        'derselben USt-ID gibt; danach verknüpfe ihn mit allen offenen '
        'Bestellungen des letzten Quartals und melde Abweichungen.',
  ]) {
    final d = await decider.decide(task);
    print(
      '${d.route.name.padRight(5)} ${d.reason} '
      '${d.latencyMs}ms ${d.deciderModel}  <- $task',
    );
  }
}
