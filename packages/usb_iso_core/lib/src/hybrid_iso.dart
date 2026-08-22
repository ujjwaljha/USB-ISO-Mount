import 'dart:io';

/// True when the ISO file starts with an MBR signature (`0x55AA`).
///
/// Many Windows ISOs are hybrid too — do not use this alone to classify
/// Windows vs Linux. It only decides raw write vs file-copy for generic UEFI.
bool isoLooksLikeHybridDisk(String isoPath) {
  final file = File(isoPath);
  if (!file.existsSync() || file.lengthSync() < 512) {
    return false;
  }
  final handle = file.openSync();
  try {
    handle.setPositionSync(510);
    final signature = handle.readSync(2);
    return signature.length == 2 &&
        signature[0] == 0x55 &&
        signature[1] == 0xAA;
  } finally {
    handle.closeSync();
  }
}
