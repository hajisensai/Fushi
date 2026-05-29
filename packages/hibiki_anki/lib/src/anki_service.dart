import 'dart:async';

abstract class AnkiService {
  Future<bool> isAvailable();
  Future<List<String>> getDeckNames();
  Future<List<String>> getModelNames();
  Future<List<String>> getModelFields(String modelName);
  /// Adds a note and returns the new note id (null only if the backend
  /// reports neither an error nor an id). [allowDuplicate] must be threaded
  /// to the backend; AnkiConnect rejects duplicates by default otherwise.
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
  });
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
  });
}
