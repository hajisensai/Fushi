import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anki_models.dart';
import 'lapis_note_type.dart';
import 'lapis_preset.dart';

abstract class BaseAnkiRepository {
  @protected
  static const settingsKey = 'hoshi_anki_settings';

  Future<AnkiSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(settingsKey);
    if (raw == null) return const AnkiSettings();
    try {
      return AnkiSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e, stack) {
      debugPrint('BaseAnkiRepository.loadSettings: $e\n$stack');
      return const AnkiSettings();
    }
  }

  Future<void> saveSettings(AnkiSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(settingsKey, jsonEncode(settings.toJson()));
  }

  Future<AnkiSettings> updateSettings(
      AnkiSettings Function(AnkiSettings) transform) async {
    final current = await loadSettings();
    final updated = transform(current);
    await saveSettings(updated);
    return updated;
  }

  Future<AnkiFetchResult> fetchConfiguration();

  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  });

  Future<bool> isDuplicate(String expression, String reading);

  /// Create [template] as a note type in the backend. Idempotent: returns
  /// `false` if a note type with that name already exists (no-op), `true` if
  /// newly created. Throws on backend failure (not-reachable, permission).
  Future<bool> createNoteType(AnkiNoteTypeTemplate template);

  /// Create a deck by [name]. Idempotent: returns `false` if it already
  /// exists, `true` if newly created. Throws on backend failure.
  Future<bool> createDeck(String name);

  @protected
  AnkiDeck selectDeckAfterFetch(List<AnkiDeck> decks, AnkiSettings current) =>
      decks.firstWhereOrNull((d) => d.id == current.selectedDeckId) ??
      (current.selectedDeckName != null
          ? decks.firstWhereOrNull((d) => d.name == current.selectedDeckName)
          : null) ??
      decks.firstWhereOrNull(
          (d) => !d.name.toLowerCase().startsWith('default')) ??
      decks.first;

  @protected
  AnkiNoteType selectNoteTypeAfterFetch(
          List<AnkiNoteType> noteTypes, AnkiSettings current) =>
      noteTypes.firstWhereOrNull((t) => t.id == current.selectedNoteTypeId) ??
      (current.selectedNoteTypeName != null
          ? noteTypes
              .firstWhereOrNull((t) => t.name == current.selectedNoteTypeName)
          : null) ??
      noteTypes.firstWhereOrNull(LapisPreset.matches) ??
      noteTypes.first;

  @protected
  Map<String, String> fieldMappingsAfterFetch(
      AnkiNoteType selectedNoteType, AnkiSettings current) {
    if (LapisPreset.matches(selectedNoteType) &&
        !_currentSelectionMatchesLapis(current)) {
      return LapisPreset.applyDefaults(selectedNoteType, {});
    }
    return current.fieldMappings;
  }

  bool _currentSelectionMatchesLapis(AnkiSettings current) {
    final matched = current.availableNoteTypes.firstWhereOrNull((t) =>
        t.id == current.selectedNoteTypeId ||
        t.name == current.selectedNoteTypeName);
    if (matched != null) return LapisPreset.matches(matched);
    return current.selectedNoteTypeName?.toLowerCase().contains('lapis') ??
        false;
  }

  // ── note tags：两 backend 共用（杜绝两份漂移） ──────────────────

  /// 标记每张经 Hibiki 制出的卡片的固定 tag。所有 Hibiki 制卡都会带上它，
  /// 便于用户在 Anki 里按来源筛选/统计。
  static const String hibikiTag = 'hibiki';

  /// 书籍来源（EPUB 阅读、独立查词、有声书）的分类标签。
  static const String bookTag = 'book';

  /// 视频/动漫来源的分类标签。用户口径为「动漫」，故用 `anime`（而非 `video`），
  /// 与统计来源标识 `kStatSourceVideo`('video') 有意错开。
  static const String animeTag = 'anime';

  /// 把制卡来源类别映射成分类标签；`null`（未指定来源）时返回 `null`（不追加）。
  static String? _categoryTagForSource(AnkiMiningSource? source) {
    switch (source) {
      case AnkiMiningSource.book:
        return bookTag;
      case AnkiMiningSource.video:
        return animeTag;
      case null:
        return null;
    }
  }

  /// 解析用户配置的 [userTags]（空白分隔），**追加** [hibikiTag] 与 [source] 对应的
  /// 分类标签后去重（保序）。
  ///
  /// - 追加而非覆盖：用户已配置的 tag 全部保留，只是额外多 `hibiki` + 分类标签。
  /// - 顺序：用户 tag → `hibiki` → 分类标签（`book`/`anime`）。
  /// - 去重：用户若已手动配置了 `hibiki`/`book`/`anime`，不会出现两个。
  /// - [source] 为 `null`（未指定）时只追加 `hibiki`，不加分类标签。
  /// - 两 backend（AnkiConnect / AnkiDroid）共用同一逻辑，避免一端漏加或漂移。
  @protected
  List<String> buildNoteTags(String userTags, {AnkiMiningSource? source}) {
    final seen = <String>{};
    final result = <String>[];
    for (final tag in userTags.split(RegExp(r'\s+'))) {
      if (tag.isEmpty || !seen.add(tag)) continue;
      result.add(tag);
    }
    if (seen.add(hibikiTag)) result.add(hibikiTag);
    final categoryTag = _categoryTagForSource(source);
    if (categoryTag != null && seen.add(categoryTag)) result.add(categoryTag);
    return result;
  }

  // ── 词典媒体（gaiji 外字）嵌入：两 backend 共用，杜绝两份实现漂移 ──────────────

  /// 把每条词典媒体（gaiji 外字等）存进 Anki，返回「占位符 → **裸媒体引用**」映射。
  ///
  /// - 键 = popup.js 注入到义项 HTML 里的占位符文件名（`hoshi_dict_N.ext`，即
  ///   [DictionaryMedia.filename]）。
  /// - 值 = [storeBareRef] 返回的**裸文件名**（如 `real.svg`），**不是** `<img src>` 标签。
  ///
  /// 关键不变式：值必须是裸文件名。导出的义项 HTML 已经是
  /// `<img class="gloss-image" src="hoshi_dict_N.ext">`，[buildMinedFields] 用
  /// `replaceAll` 把 `src` 里的占位符替换成真实文件名。若值是完整 `<img src="real.svg">`
  /// 标签，会被塞进 `src="..."` 里变成 `<img src="<img src="real.svg">">` 的嵌套坏图，
  /// Anki 卡片上外字不显示（AnkiConnect 旧实现的 BUG，AnkiDroid 经
  /// [ankiInlineMediaReference] 裸化故正常；本统一令两端同契约）。
  @protected
  Future<Map<String, String>> buildDictionaryMediaTags(
    List<DictionaryMedia> media,
    Future<String?> Function(DictionaryMedia media) storeBareRef,
  ) async {
    final tags = <String, String>{};
    for (final m in media) {
      final ref = await storeBareRef(m);
      if (ref != null && ref.isNotEmpty) {
        tags[m.filename] = ref;
      }
    }
    return tags;
  }

  /// 按 [fieldMappings] 渲染卡片字段：模板渲染 → 替换词典媒体占位符 → HTML 规范化。
  /// 两 backend 共用同一逻辑（原先在两个 repo 各有一份 byte 级重复实现）。
  @protected
  Map<String, String> buildMinedFields({
    required Map<String, String> fieldMappings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    required Map<String, String> dictionaryMediaTags,
  }) {
    final fields = <String, String>{};
    for (final entry in fieldMappings.entries) {
      var value = AnkiHandlebarRenderer.render(entry.value, payload, context);
      for (final mediaEntry in dictionaryMediaTags.entries) {
        value = value.replaceAll(mediaEntry.key, mediaEntry.value);
      }
      value = normalizeAnkiDictionaryHtml(value);
      if (value.trim().isNotEmpty) {
        fields[entry.key] = value;
      }
    }
    return fields;
  }
}
