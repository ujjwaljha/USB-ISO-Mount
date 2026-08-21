import 'dart:convert';

List<dynamic> decodeJsonList(String stdout) {
  final trimmed = stdout.trim();
  if (trimmed.isEmpty) {
    return const [];
  }
  final decoded = jsonDecode(trimmed);
  if (decoded is List) {
    return decoded;
  }
  if (decoded is Map) {
    return [decoded];
  }
  return const [];
}

Map<String, dynamic> decodeJsonObject(String stdout) {
  final trimmed = stdout.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Expected a JSON object, got empty output.');
  }
  final decoded = jsonDecode(trimmed);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  throw FormatException('Expected a JSON object, got ${decoded.runtimeType}.');
}
