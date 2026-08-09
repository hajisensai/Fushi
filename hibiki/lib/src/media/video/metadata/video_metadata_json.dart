library;

String? metadataString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? metadataInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? metadataDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

bool? metadataBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    return switch (value.trim().toLowerCase()) {
      'true' || '1' || 'yes' => true,
      'false' || '0' || 'no' => false,
      _ => null,
    };
  }
  return null;
}

Map<String, Object?>? metadataObject(Object? value) =>
    value is Map<String, Object?> ? value : null;

List<Object?> metadataList(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];

int? metadataYear(String? date) {
  if (date == null || date.length < 4) return null;
  return int.tryParse(date.substring(0, 4));
}

String? metadataStripHtml(String? value) {
  if (value == null) return null;
  final String result = value
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .trim();
  return result.isEmpty ? null : result;
}

List<String> metadataUniqueStrings(Iterable<String?> values) {
  final Set<String> seen = <String>{};
  final List<String> result = <String>[];
  for (final String? value in values) {
    final String? normalized = metadataString(value);
    if (normalized != null && seen.add(normalized)) result.add(normalized);
  }
  return result;
}
