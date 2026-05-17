import 'dart:async';
import 'anki_models.dart';

abstract class AnkiService {
  Future<bool> isAvailable();
  Future<List<String>> getDeckNames();
  Future<List<String>> getModelNames();
  Future<List<String>> getModelFields(String modelName);
  Future<void> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
  });
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
  });
}
