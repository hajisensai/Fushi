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

  /// TODO-270 C1：更新已存在 note 的字段（按 [noteId] 覆盖 [fields] 中给出的
  /// 字段；未给出的字段保持不变）。用于「制卡后再次查词同一单词时更新已有卡片」。
  /// 带固定 [noteId]，重发幂等（同 id + 同 fields 结果一致）。
  Future<void> updateNoteFields(int noteId, Map<String, String> fields);

  /// TODO-270 C1：读取 [noteId] 对应 note 的现有字段（字段名 → 值），用于覆盖前
  /// 回显/合并。note 不存在时返回 `null`。
  Future<Map<String, String>?> notesInfo(int noteId);
}
