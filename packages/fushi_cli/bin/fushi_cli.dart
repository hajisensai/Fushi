import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runFushiCli(args);
}
