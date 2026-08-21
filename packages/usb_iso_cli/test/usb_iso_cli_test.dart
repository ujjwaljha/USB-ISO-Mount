import 'package:test/test.dart';
import 'package:usb_iso_cli/usb_iso_cli.dart';

void main() {
  test('help exits successfully', () async {
    expect(await run(['--help']), 0);
  });

  test('make without arguments is a usage error', () async {
    expect(await run(['make']), 64);
  });
}
