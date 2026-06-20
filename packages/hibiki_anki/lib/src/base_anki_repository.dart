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

  /// TODO-270 D：覆盖一张**已存在**的 Hibiki 制卡（[noteId]）的字段，用同一字段
  /// 渲染链路从 [rawPayloadJson]+[context] 生成 fields 后按 id 覆盖（不新增卡片、
  /// 不查重）。供「刚制完卡又点 ✓」时真实 update 上一张卡片，而非删旧建新。
  ///
  /// **默认实现 = 优雅降级**：基类返回 [MineResult.error]，说明该后端暂不支持覆盖。
  /// 只有能按 id 覆盖字段的后端（[AnkiConnectRepository]）才覆写它做真实更新；
  /// AnkiDroid 后端（子任务 B/C2 延后）继承默认降级——它的 [MineOutcome.noteId]
  /// 恒为 `null`，弹窗根本进不了「最新可改」第三态、不会调本方法，故这条降级仅作
  /// 防御兜底（万一被调用也不崩、返回明确失败），不破坏现状（Never break userspace）。
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure(
        'This Anki backend does not support overwriting a mined card.',
      );

  /// TODO-614：按「与查重同一条件」反查一张可被覆写的**已存在** note id。
  ///
  /// 仅当用户把 [AnkiSettings.overwriteScope] 设为 [AnkiOverwriteScope.all] 时才真正
  /// 查询；为 [AnkiOverwriteScope.latest]（默认）时一律返回 `null`——弹窗只覆写本会话
  /// 最近一张（旧行为，Never break userspace）。返回非空 id 时，弹窗据此把更早的卡也
  /// 标记为「最新可改」第三态、点 ✓↩ 走 [updateMinedNote] 按 id 覆写。
  ///
  /// **默认实现 = 优雅降级**：基类恒返回 `null`，表示该后端拿不到可覆写的 note id。
  /// 只有能按内容反查真实 note id 的后端（[AnkiConnectRepository]）才覆写它。AnkiDroid
  /// 后端（只回 bool）继承默认降级，scope=all 对它仍不可覆写更早卡，与现状一致。
  Future<int?> findOverwriteTargetNoteId(
          String expression, String reading) async =>
      null;

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

  /// 视频来源的分类标签。旧版本曾写入 `anime`；这里仅决定新制卡默认标签，不迁移
  /// 或重写用户 Anki 中的既有卡片，避免碰旧数据。
  static const String videoTag = 'video';

  /// 把制卡来源类别映射成分类标签；`null`（未指定来源）时返回 `null`（不追加）。
  static String? _categoryTagForSource(AnkiMiningSource? source) {
    switch (source) {
      case AnkiMiningSource.book:
        return bookTag;
      case AnkiMiningSource.video:
        return videoTag;
      case null:
        return null;
    }
  }

  /// 解析用户配置的 [userTags]（空白分隔，即用户自定义 DIY 标签），按开关
  /// **追加** [hibikiTag] 与 [source] 对应的分类标签后去重（保序）。
  ///
  /// - 追加而非覆盖：用户已配置的 tag 全部保留，只是按开关额外多 `hibiki` + 分类标签。
  /// - 顺序：用户 tag → `hibiki` → 分类标签（`book`/`video`）。
  /// - 去重：用户若已手动配置了 `hibiki`/`book`/`video`，不会出现两个。
  /// - [includeHibiki]（TODO-117 开关）为 `false` 时不追加 `hibiki`。
  /// - [includeCategory]（TODO-117 开关）为 `false` 时不追加分类标签；为 `true` 但
  ///   [source] 为 `null`（未指定来源，如独立查词/悬浮窗）时本就没有分类标签可加。
  /// - 两个开关默认 `true`，等价 TODO-115/062 的固定行为（Never break userspace）。
  /// - 两 backend（AnkiConnect / AnkiDroid）共用同一逻辑，避免一端漏加或漂移。
  @protected
  List<String> buildNoteTags(
    String userTags, {
    AnkiMiningSource? source,
    bool includeHibiki = true,
    bool includeCategory = true,
  }) {
    final seen = <String>{};
    final result = <String>[];
    for (final tag in userTags.split(RegExp(r'\s+'))) {
      if (tag.isEmpty || !seen.add(tag)) continue;
      result.add(tag);
    }
    if (includeHibiki && seen.add(hibikiTag)) result.add(hibikiTag);
    if (includeCategory) {
      final categoryTag = _categoryTagForSource(source);
      if (categoryTag != null && seen.add(categoryTag)) result.add(categoryTag);
    }
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
