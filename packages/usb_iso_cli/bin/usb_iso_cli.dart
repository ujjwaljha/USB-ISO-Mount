import 'dart:io';

import 'package:usb_iso_cli/usb_iso_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await run(arguments);
}
