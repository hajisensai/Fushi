import 'dart:io';

import 'package:fushi_server/src/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runFushiServerCli(args);
}
