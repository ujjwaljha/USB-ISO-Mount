import 'package:flutter/material.dart';
import 'package:usb_iso_core/usb_iso_core.dart';

import 'home_page.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UsbIsoApp());
}

class UsbIsoApp extends StatelessWidget {
  const UsbIsoApp({super.key, this.listDisks});

  final Future<List<UsbDisk>> Function()? listDisks;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'USB ISO Mount',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: HomePage(listDisks: listDisks),
    );
  }
}
