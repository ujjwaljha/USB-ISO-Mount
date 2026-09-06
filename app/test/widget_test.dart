import 'package:flutter_test/flutter_test.dart';
import 'package:usb_iso_core/usb_iso_core.dart';
import 'package:usb_iso_mount/main.dart';

void main() {
  testWidgets('shows the app title', (tester) async {
    await tester.pumpWidget(
      UsbIsoApp(listDisks: () async => const <UsbDisk>[]),
    );
    await tester.pumpAndSettle();
    expect(find.text('USB ISO Mount'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Make bootable USB'), 200);
    expect(find.text('Make bootable USB'), findsOneWidget);
    expect(find.text('Format USB'), findsOneWidget);
  });

  testWidgets('format dialog opens for a listed USB', (tester) async {
    const disk = UsbDisk(
      id: 'disk70',
      devicePath: '/dev/disk70',
      name: 'SanDisk',
      sizeBytes: 61530439680,
      busProtocol: 'USB',
      isRemovable: true,
      isInternal: false,
      isBoot: false,
      isVirtual: false,
    );
    await tester.pumpWidget(UsbIsoApp(listDisks: () async => const [disk]));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Format USB'), 200);
    await tester.tap(find.text('Format USB'));
    await tester.pumpAndSettle();
    expect(find.text('Format this USB drive?'), findsOneWidget);
    expect(find.text('Erase and format'), findsOneWidget);
    expect(
      find.textContaining('FAT32 works on the most devices'),
      findsOneWidget,
    );
  });
}
