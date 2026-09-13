# USB ISO Mount (desktop)

Flutter desktop app for **macOS and Windows** (no Linux GUI target).

```bash
flutter pub get
flutter run -d macos
# or: flutter run -d windows
```

Add more than one ISO in the app to build a multiboot stick (Windows Setup plus Ubuntu or other Linux live images). On an existing multiboot USB, **Add ISO to this USB** copies more images without erasing, and **Refresh GRUB menu** rebuilds the boot list.

See the [repository README](../README.md) for the ready-bar, Windows first-run checklist, and CLI.
