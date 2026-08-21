import 'package:flutter_test/flutter_test.dart';
import 'package:usb_iso_core/usb_iso_core.dart';
import 'package:usb_iso_mount/main.dart';

void main() {
  testWidgets('shows the app title', (tester) async {
    await tester.pumpWidget(
      UsbIsoApp(listDisks: () async => const <UsbDisk>[]),
    );
    expect(find.text('USB ISO Mount'), findsOneWidget);
    expect(find.text('Make bootable USB'), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
