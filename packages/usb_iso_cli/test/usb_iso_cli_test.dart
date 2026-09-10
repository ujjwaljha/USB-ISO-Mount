import 'package:test/test.dart';
import 'package:usb_iso_cli/usb_iso_cli.dart';
import 'package:usb_iso_core/usb_iso_core.dart';

void main() {
  test('help exits successfully', () async {
    expect(await run(['--help']), 0);
  });

  test('format without a disk is a usage error', () async {
    expect(await run(['format']), 64);
  });

  test('format help lists filesystem flags', () async {
    expect(await run(['format', '--help']), 0);
  });

  test('make help mentions repeating --iso for multiboot', () async {
    expect(await run(['make', '--help']), 0);
    final make = MakeCommand();
    expect(make.description, contains('multiboot'));
    expect(make.argParser.options['iso']!.help, contains('Repeat'));
  });

  test('add and refresh help describe the non-destructive path', () async {
    expect(await run(['add', '--help']), 0);
    expect(await run(['refresh', '--help']), 0);
    final add = AddCommand();
    expect(add.description, contains('without erasing'));
    expect(add.argParser.options['yes']!.help, contains('ADD'));
    final refresh = RefreshCommand();
    expect(refresh.description, contains('GRUB'));
  });

  test('rewrites a TTY write line and prints other steps once', () {
    final buffer = StringBuffer();
    final printer = CliProgressWriter(sink: buffer, tty: true);
    printer.add(
      const WriteProgress(
        step: WriteStep.writing,
        message: 'Writing ISO image… 10%',
        percent: 0.3,
      ),
    );
    printer.add(
      const WriteProgress(
        step: WriteStep.writing,
        message: 'Writing ISO image… 11%',
        percent: 0.31,
      ),
    );
    printer.add(
      const WriteProgress(
        step: WriteStep.verifying,
        message: 'Verifying the raw write…',
        percent: 0.9,
      ),
    );
    printer.finish();
    expect(buffer.toString(), contains('\rWriting ISO image… 10%  (30%)'));
    expect(buffer.toString(), contains('\rWriting ISO image… 11%  (31%)'));
    expect(buffer.toString(), contains('Verifying the raw write…  (90%)\n'));
  });
}
