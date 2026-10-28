import 'dart:io';

import 'package:greatnote/src/postzen/postzen_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runPostZenCli(arguments);
}
