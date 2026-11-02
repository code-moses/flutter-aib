import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:args/command_runner.dart';

Future<void> main(List<String> arguments) async {
  try {
    exit(await buildRunner().run(arguments) ?? 0);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  }
}
