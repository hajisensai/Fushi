import 'package:fushi_anki/fushi_anki_core.dart';

/// Strict wire decoding for source edits; malformed snapshots never become an
/// empty original that could bypass the host's field-conflict checks.
AnkiSourceNote decodeRemoteSourceNote(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid source note');
  }
  final Object? sourceId = value['sourceId'];
  final Object? noteId = value['noteId'];
  if (sourceId is! String || noteId is! int || noteId <= 0) {
    throw const FormatException('Invalid source note identity');
  }
  CardSourceLink.markerForSourceId(sourceId);
  return AnkiSourceNote(
    sourceId: sourceId,
    noteId: noteId,
    fields: decodeRemoteSourceFields(value['fields']),
  );
}

Map<String, String> decodeRemoteSourceFields(Object? value) {
  if (value is! Map ||
      value.keys.any((Object? key) => key is! String) ||
      value.values.any((Object? field) => field is! String)) {
    throw const FormatException('Invalid source note fields');
  }
  return Map<String, String>.from(value);
}

Map<String, dynamic> encodeRemoteSourceNote(AnkiSourceNote note) =>
    <String, dynamic>{
      'sourceId': note.sourceId,
      'noteId': note.noteId,
      'fields': note.fields,
    };
