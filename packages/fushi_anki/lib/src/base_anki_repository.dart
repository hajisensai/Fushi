import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anki_media_dedup.dart';
import 'anki_models.dart';
import 'anki_note_type_definition.dart';
import 'lapis_note_type.dart';
import 'lapis_preset.dart';

/// TODO-779：单词远程音频获取的结果载体。两 backend 的远程音频路径
/// （`_storeRemoteAudio` / `_addRemoteAudio`）共用，把过去只能返回的裸 ref
/// （`String?`，失败时静默 `null`）升级成「ref + 可见失败原因」二元组。
///
/// - [ref] 非空 = 成功：裸媒体引用（AnkiConnect 的裸文件名 / AnkiDroid `addFileToMedia`
///   返回的文件名），调用方包成 `[sound:ref]` 写进卡片。
/// - [failureReason] 非空 = **可见失败**：卡片仍会建好但音频落空，原因（含 HTTP 码/URL）
///   冒泡到 [MineOutcome.audioWarning]，让用户看到「音频获取失败」而非盲猜。
/// - 两者皆 `null` = 本就没有音频要取（[AnkiAudioRefKind.empty]）或本地文件缺失，
///   不是错误、无需提示（与旧版静默 `null` 行为一致，Never break userspace）。
///
/// **关键不变式**：[failureReason] 非空时 [ref] 必须为 `null`——绝不把非 200 的错误
/// 响应体当 .mp3 字节写入媒体（HBK-AUDIT-019：会嵌坏文件）。
@immutable
class AudioFetchOutcome {
  const AudioFetchOutcome._({this.ref, this.failureReason})
      : assert(
          ref == null || failureReason == null,
          'A successful audio fetch (ref) cannot also carry a failure reason.',
        );

  /// 成功：拿到裸媒体引用 [ref]。
  const AudioFetchOutcome.stored(String ref) : this._(ref: ref);

  /// 没有音频要取 / 本地文件缺失：既非成功也非可见失败（不提示）。
  const AudioFetchOutcome.none() : this._();

  /// 可见失败：[reason] 含 HTTP 码/URL 或异常摘要，冒泡到 [MineOutcome.audioWarning]。
  const AudioFetchOutcome.failed(String reason) : this._(failureReason: reason);

  /// 非空 = 成功取得的裸媒体引用（包成 `[sound:ref]`）。
  final String? ref;

  /// 非空 = 可见失败原因（卡片仍建好，音频落空）。
  final String? failureReason;
}

/// TODO-779：字段渲染的结果载体。把渲染出的卡片字段 [fields] 与**部分成功**信号
/// [audioWarning]（单词远程音频下载失败原因）一起回传，让 `_mineEntryInner` /
/// `updateMinedNote` 的成功分支能把警告带进 [MineOutcome.success]。
@immutable
class RenderedMinedFields {
  const RenderedMinedFields(this.fields, {this.audioWarning});

  /// 渲染出的卡片字段（字段名 → 值，仅含非空值）。
  final Map<String, String> fields;

  /// 非空 = 单词远程音频下载失败的简短原因（含 HTTP 码/URL），来自
  /// [AudioFetchOutcome.failureReason]。
  final String? audioWarning;
}

abstract class BaseAnkiRepository {
  @protected
  static const settingsKey = 'fushi_anki_settings';

  /// 存量 SharedPreferences 键（W2-7 迁移输入）：[readSettingsJson] 载入期把
  /// 值搬到 [settingsKey] 后删除旧键。旧字面量只允许活在这一处迁移代码里。
  static const String _legacySettingsKey = 'hoshi_anki_settings';

  /// 载入期一次性迁移（W2-2）：把存量用户卡模板里的音频旧别名
  /// `{sasayaki-audio}` 就地改写为 `{sentence-audio}`（两者从来渲染同一个值，
  /// 改写零语义变化），命中即回写持久层。幂等：改写后源串不再含旧 token。
  /// 旧字面量只允许活在这一处迁移代码里——渲染器/枚举/诊断均已不再受理别名。
  /// 清理条件：无（SharedPreferences 无版本阶梯，载入期改写即是它的迁移通道）。
  static const String _legacySentenceAudioAlias = '{sasayaki-audio}';

  /// 读原始设置 JSON 的**唯一通道**：两个载入期迁移（W2-7 键搬移 + W2-2 别名
  /// 改写）都收敛在这里。子类若覆写 [loadSettings]（AnkiDroid 的 legacy deck
  /// 迁移）也必须经由本方法取原始串，否则迁移被绕过。返回 null = 从未存过。
  @protected
  Future<String?> readSettingsJson(SharedPreferences prefs) async {
    String? raw = prefs.getString(settingsKey);
    if (raw == null) {
      final String? legacy = prefs.getString(_legacySettingsKey);
      if (legacy != null) {
        await prefs.setString(settingsKey, legacy);
        await prefs.remove(_legacySettingsKey);
        raw = legacy;
      }
    }
    if (raw != null && raw.contains(_legacySentenceAudioAlias)) {
      raw = raw.replaceAll(_legacySentenceAudioAlias, '{sentence-audio}');
      await prefs.setString(settingsKey, raw);
    }
    return raw;
  }

  Future<AnkiSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final String? raw = await readSettingsJson(prefs);
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
    final bool saved = await prefs.setString(
      settingsKey,
      jsonEncode(settings.toJson()),
    );
    if (!saved) {
      throw StateError('Failed to persist Anki settings.');
    }
  }

  Future<AnkiSettings> updateSettings(
    AnkiSettings Function(AnkiSettings) transform,
  ) async {
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
    String expression,
    String reading,
  ) async =>
      null;

  /// TODO-1007/1008：按「与查重同一条件」（第一字段=expression）反查 Anki 中**所有**
  /// 已存在的同词卡，返回它们的 [MinedNoteRef]（noteId + 一行预览），**不受
  /// [AnkiSettings.overwriteScope] 影响**——这是「别处/上次会话建的卡也要能被发现并操作」
  /// 的根因修复入口。与 [findOverwriteTargetNoteId]（只在 scope=all 时回最近一张）不同，
  /// 本方法恒尝试反查全部命中，交给宿主弹操作选择（命中多张让用户选哪张、点 ✓ 弹三选）。
  ///
  /// 返回顺序：note id 降序（最近的在前），便于宿主默认高亮最近一张。查询失败 / 拿不到
  /// id 时返回空列表（fail-soft，绝不让探测把制卡链路搞崩）。
  ///
  /// **默认实现 = 优雅降级**：基类返回空列表。两后端各自覆写（AnkiConnect 经 findNotes +
  /// notesInfo，AnkiDroid 经 ContentProvider findDuplicateNotes → NoteInfo.getId）。
  Future<List<MinedNoteRef>> findMatchingNotes(
    String expression,
    String reading,
  ) async =>
      const <MinedNoteRef>[];

  /// TODO-1007/1008：读取一张已存在 note（[noteId]）的现有字段（字段名 → 值），供
  /// note viewer 只读展示。两后端各自覆写（AnkiConnect `notesInfo` / AnkiDroid
  /// ContentProvider getNote）。note 不存在 / 后端不支持时返回 `null`。
  Future<Map<String, String>?> noteFields(int noteId) async => null;

  /// TODO-1007/1008：在 Anki 中打开 / 浏览 [noteId] 对应的卡片（AnkiConnect 用
  /// `guiBrowse(nid:<id>)`；AnkiDroid 用 ACTION_VIEW intent 跳 ContentProvider note）。
  /// 成功返回 `true`，后端不支持 / 失败返回 `false`（不抛，供宿主据此提示）。
  ///
  /// **默认实现 = 优雅降级**：基类返回 `false`。
  Future<bool> openNoteInAnki(int noteId) async => false;

  Future<bool> isDuplicate(String expression, String reading);

  /// Create [template] as a note type in the backend. Idempotent: returns
  /// `false` if a note type with that name already exists (no-op), `true` if
  /// newly created. Throws on backend failure (not-reachable, permission).
  Future<bool> createNoteType(AnkiNoteTypeTemplate template);

  /// Create a deck by [name]. Idempotent: returns `false` if it already
  /// exists, `true` if newly created. Throws on backend failure.
  Future<bool> createDeck(String name);

  // ── note type 模板读写（Lapis 客制化/备份/自动迁移）───────────────────────

  /// 本后端能否读取/覆写**已存在** note type 的卡模板与 styling。
  ///
  /// **默认 = false（优雅降级）**：AnkiDroid Content Provider 与 AnkiMobile
  /// 均无改已存在模板的 API（平台边界，非本仓可修），设置页据此隐藏 Lapis
  /// 样式客制化区。只有 [supportsNoteTypeEditing] 为 true 的后端
  /// （AnkiConnect）才覆写下面三个方法做真实读写。
  bool get supportsNoteTypeEditing => false;

  /// 读取名为 [modelName] 的 note type 完整定义（字段/卡模板/CSS），供备份
  /// 与漂移判定。模型不存在或后端不支持返回 `null`；后端可达性错误照抛
  /// （调用方决定提示还是静默跳过）。**默认实现 = 优雅降级**：返回 `null`。
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
    String modelName,
  ) async =>
      null;

  /// 覆写 [modelName] 的 styling（CSS）。返回 `false` = 后端不支持（默认
  /// 降级）；成功返回 `true`；后端失败照抛。
  Future<bool> updateNoteTypeStyling(String modelName, String css) async =>
      false;

  /// 覆写 [modelName] 的全部卡模板正/反面。返回 `false` = 后端不支持（默认
  /// 降级）；成功返回 `true`；后端失败照抛。只在「从备份恢复」时使用——样式
  /// 客制化本身只动 styling。
  Future<bool> updateNoteTypeTemplates(
    String modelName,
    List<AnkiCardTemplate> templates,
  ) async =>
      false;

  // ── 媒体存储优化（字节级去重，见 anki_media_dedup.dart）────────────────

  /// 本后端能否做媒体字节级去重。需要**本机可直读** collection.media +
  /// 全库检索 + 字段/模板改写；默认 false，仅 AnkiConnect（Anki 与 Hibiki
  /// 同机）支持。
  ///
  /// **后端不对称（有意）**：AnkiDroid（`AnkiRepository`）与 AnkiMobile 都不覆写
  /// 这一对成员——它们**根本不跑媒体去重**，所以 AnkiConnect 那边的批量化
  /// （见 `kAnkiMediaDedupBatchSize`）在这里没有对应实现，也不存在「逐条删除」
  /// 的对称缺口需要补。AnkiDroid 的 ContentProvider 确实有 `bulkInsert`，但那是
  /// 写卡路径的能力，与本功能无关。
  bool get supportsMediaMaintenance => false;

  /// 跑一轮媒体字节级去重：找出字节完全相同的文件组 → 把笔记字段与卡模板/
  /// styling 里的引用统一改指保留份 → 复核引用清干净后删除多余副本。
  /// **绝不重编码任何文件**。[dryRun] = 只扫描规划，不改动。[onJournal] 在
  /// 每次真实改写/删除**之前**收到一条可回溯记录（调用方负责落盘）。
  /// [onProgress] 每个文件/副本边界报一次进度（长任务，UI 靠它画进度条）；
  /// [shouldCancel] 在每个副本边界检查，返回 true 则干净停下并返回
  /// `cancelled: true` 的部分结果（已做的改写/删除保留，不回滚——引用永远先
  /// 改指保留份，任何时刻停下都自洽）。
  /// **默认实现 = 优雅降级**：返回 null。
  Future<AnkiMediaDedupReport?> runMediaDedup({
    bool dryRun = false,
    Future<void> Function(Map<String, dynamic> entry)? onJournal,
    AnkiMediaDedupOnProgress? onProgress,
    bool Function()? shouldCancel,
  }) async =>
      null;

  @protected
  AnkiDeck selectDeckAfterFetch(List<AnkiDeck> decks, AnkiSettings current) =>
      decks.firstWhereOrNull((d) => d.id == current.selectedDeckId) ??
      (current.selectedDeckName != null
          ? decks.firstWhereOrNull((d) => d.name == current.selectedDeckName)
          : null) ??
      decks.firstWhereOrNull(
        (d) => !d.name.toLowerCase().startsWith('default'),
      ) ??
      decks.first;

  @protected
  AnkiNoteType selectNoteTypeAfterFetch(
    List<AnkiNoteType> noteTypes,
    AnkiSettings current,
  ) =>
      noteTypes.firstWhereOrNull((t) => t.id == current.selectedNoteTypeId) ??
      (current.selectedNoteTypeName != null
          ? noteTypes.firstWhereOrNull(
              (t) => t.name == current.selectedNoteTypeName,
            )
          : null) ??
      noteTypes.firstWhereOrNull(LapisPreset.matches) ??
      noteTypes.first;

  @protected
  Map<String, String> fieldMappingsAfterFetch(
    AnkiNoteType selectedNoteType,
    AnkiSettings current,
  ) {
    if (LapisPreset.matches(selectedNoteType) &&
        !_currentSelectionMatchesLapis(current)) {
      return LapisPreset.applyDefaults(selectedNoteType, {});
    }
    return current.fieldMappings;
  }

  bool _currentSelectionMatchesLapis(AnkiSettings current) {
    final matched = current.availableNoteTypes.firstWhereOrNull(
      (t) =>
          t.id == current.selectedNoteTypeId ||
          t.name == current.selectedNoteTypeName,
    );
    if (matched != null) return LapisPreset.matches(matched);
    return current.selectedNoteTypeName?.toLowerCase().contains('lapis') ??
        false;
  }

  // ── note tags：两 backend 共用（杜绝两份漂移） ──────────────────

  /// 标记每张经 Fushi 制出的卡片的固定 tag。所有 Fushi 制卡都会带上它，
  /// 便于用户在 Anki 里按来源筛选/统计。改名前的旧卡带的是字面 tag `hibiki`
  /// ——那是用户 Anki 库里的外部数据，只决定新卡默认值、不迁移不重写（W7）。
  static const String fushiTag = 'fushi';

  /// 书籍来源（EPUB 阅读、独立查词、有声书）的分类标签。
  static const String bookTag = 'book';

  /// 视频来源的分类标签。旧版本曾写入 `anime`；这里仅决定新制卡默认标签，不迁移
  /// 或重写用户 Anki 中的既有卡片，避免碰旧数据。
  static const String videoTag = 'video';

  /// galgame Hook 来源的分类标签（BUG-1137）。仅决定新制卡默认标签，既有误标
  /// `video` 的旧卡不迁移不重写。
  static const String gameTag = 'game';

  /// 把制卡来源类别映射成分类标签；`null`（未指定来源）时返回 `null`（不追加）。
  static String? _categoryTagForSource(AnkiMiningSource? source) {
    switch (source) {
      case AnkiMiningSource.book:
        return bookTag;
      case AnkiMiningSource.video:
        return videoTag;
      case AnkiMiningSource.game:
        return gameTag;
      case null:
        return null;
    }
  }

  /// 解析用户配置的 [userTags]（空白分隔，即用户自定义 DIY 标签），按开关
  /// **追加** [fushiTag] 与 [source] 对应的分类标签后去重（保序）。
  ///
  /// - 追加而非覆盖：用户已配置的 tag 全部保留，只是按开关额外多 `fushi` + 分类标签。
  /// - 顺序：用户 tag → `fushi` → 分类标签（`book`/`video`/`game`）。
  /// - 去重：用户若已手动配置了 `fushi`/`book`/`video`/`game`，不会出现两个。
  /// - [includeHibiki]（TODO-117 开关）为 `false` 时不追加 `fushi`。
  /// - [includeCategory]（TODO-117 开关）为 `false` 时不追加分类标签；为 `true` 但
  ///   [source] 为 `null`（未指定来源，如独立查词/悬浮窗）时本就没有分类标签可加。
  /// - 两个开关默认 `true`，等价 TODO-115/062 的固定行为（Never break userspace）。
  /// - [titleTag]（TODO-681 开关，「自动添加书名到标签」）非空时追加**已清洗的书名/番名
  ///   标签**（去重后），书籍/视频同语义。
  /// - [collectionTag]（同「自动添加书名到标签」开关）非空时追加**已清洗的合集/系列名
  ///   标签**（去重后）：视频=播放列表系列名，书籍=所属合集名。与 [titleTag] 并列，二者
  ///   字面量不同则各成一个 tag，相同时由 [seen] 去重合并。
  /// - 两 backend（AnkiConnect / AnkiDroid）共用同一逻辑，避免一端漏加或漂移。
  @protected
  List<String> buildNoteTags(
    String userTags, {
    AnkiMiningSource? source,
    bool includeHibiki = true,
    bool includeCategory = true,
    String? titleTag,
    String? collectionTag,
  }) {
    final seen = <String>{};
    final result = <String>[];
    for (final tag in userTags.split(RegExp(r'\s+'))) {
      if (tag.isEmpty || !seen.add(tag)) continue;
      result.add(tag);
    }
    if (includeHibiki && seen.add(fushiTag)) result.add(fushiTag);
    if (includeCategory) {
      final categoryTag = _categoryTagForSource(source);
      if (categoryTag != null && seen.add(categoryTag)) result.add(categoryTag);
    }
    // TODO-681 / BUG-393：「自动添加书名到标签」开启时调用方注入已清洗书名/番名标签
    // （书籍/视频同语义）。去重 [seen] 保证：经卡片创建器 `TagsField` 走 [userTags] 已带过
    // 同一标题标签时不会重复追加（两处清洗规则同源故字面量相同）。
    final clean = sanitizeTitleTag(titleTag);
    if (clean != null && seen.add(clean)) result.add(clean);
    // 合集/系列名标签（与 titleTag 同「自动添加书名到标签」开关）：视频=播放列表系列名、
    // 书籍=所属合集名。调用方读开关 + 取合集名 + 清洗后注入；与书名标签并列，字面量相同时
    // 由 [seen] 去重合并（如单视频合集名==剧集名时不重复追加）。
    final cleanCollection = sanitizeTitleTag(collectionTag);
    if (cleanCollection != null && seen.add(cleanCollection)) {
      result.add(cleanCollection);
    }
    return result;
  }

  /// 把任意标题字符串清洗成**单个合法 Anki tag**：Anki tag 以空白分隔，故空格 / Tab
  /// 全替换成下划线（与卡片创建器 `TagsField` 的清洗规则一致，保证两条路径产出同一字面量，
  /// 从而被 [buildNoteTags] 的去重正确合并、不重复追加）。空/全空白返回 `null`。
  /// TODO-1007/1008：把一个卡片字段值（可能含 HTML）压成给用户看的**一行纯文本预览**：
  /// 去标签、折叠空白、截断到 [maxLen]。供 note viewer / 多张命中选择列表区分卡片用。
  /// 纯函数、可单测。
  static String previewFromFieldValue(String value, {int maxLen = 60}) {
    // 标签替换成**空格**（随后统一折叠），与 hibiki_audio 字幕解析的
    // `stripHtmlTags`（替换成空串）**故意不同**：Anki 字段 HTML 里 `<br>` /
    // 块级标签承担换行分词，直接删空会把相邻词粘连成一个词；字幕行内标签则
    // 紧贴正文、删空才不会在日文句中引入假空格。两份实现不强并（G11）。
    final String noTags = value.replaceAll(RegExp(r'<[^>]*>'), ' ');
    final String collapsed =
        noTags.replaceAll('&nbsp;', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= maxLen) return collapsed;
    return '${collapsed.substring(0, maxLen)}…';
  }

  static String? sanitizeTitleTag(String? title) {
    if (title == null) return null;
    // 先 trim 再替换内部空白：纯空白标题 → 空 → null（不产出 `___` 之类垃圾标签）；
    // 标题内部空格/Tab → 下划线，整体当一个 Anki tag。
    final trimmed = title.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.replaceAll(' ', '_').replaceAll('	', '_');
  }

  // ── 词典媒体（gaiji 外字）嵌入：两 backend 共用，杜绝两份实现漂移 ──────────────

  /// 把每条词典媒体（gaiji 外字等）存进 Anki，返回「占位符 → **裸媒体引用**」映射。
  ///
  /// - 键 = popup.js 注入到义项 HTML 里的占位符文件名（`fushi_dict_N.ext`，即
  ///   [DictionaryMedia.filename]）。
  /// - 值 = [storeBareRef] 返回的**裸文件名**（如 `real.svg`），**不是** `<img src>` 标签。
  ///
  /// 关键不变式：值必须是裸文件名。导出的义项 HTML 已经是
  /// `<img class="gloss-image" src="fushi_dict_N.ext">`，[buildMinedFields] 用
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
  ///
  /// BUG-858：[keepEmpty] 区分「新建」与「覆盖」语义。
  /// - 新建（默认 false）：渲染为空的字段直接跳过——新卡该字段本就空白，无意义。
  /// - 覆盖（true）：**保留所有映射字段**（含渲染为空的），使 `updateNoteFields`
  ///   按 id 真正整体替换。否则句子（`{sentence}` 取瞬时选区状态，覆盖那刻可能已空）
  ///   会被这里过滤掉、字段名不进 map，两后端 native 都「未给出的字段保留旧值」，
  ///   表现为「只覆盖图片和语音、原文句子不更新」。用户选定语义：覆盖=整体替换，
  ///   句子为空则随之清空（`updateMinedNote` 另有「全部字段皆空 → 拒绝清整卡」总守卫）。
  @protected
  Map<String, String> buildMinedFields({
    required Map<String, String> fieldMappings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    required Map<String, String> dictionaryMediaTags,
    bool keepEmpty = false,
  }) {
    final fields = <String, String>{};
    for (final entry in fieldMappings.entries) {
      var value = AnkiHandlebarRenderer.render(entry.value, payload, context);
      for (final mediaEntry in dictionaryMediaTags.entries) {
        value = value.replaceAll(mediaEntry.key, mediaEntry.value);
      }
      value = normalizeAnkiDictionaryHtml(value);
      if (keepEmpty || value.trim().isNotEmpty) {
        fields[entry.key] = value;
      }
    }
    return fields;
  }

  /// 用已备好的媒体引用把 [payload] + [context] 组装成最终渲染结果。
  ///
  /// 两 backend 的差异只在「媒体引用怎么准备」（AnkiConnect 远程上传后内联
  /// `<img>` / `[sound:]`；AnkiDroid 平台通道写入返回已格式化引用）；引用备好
  /// 之后的 payload 字段透传 + [buildMinedFields] 渲染 + 打包完全一致，收敛在
  /// 这里，杜绝两份 16 字段透传漂移。
  ///
  /// [coverRef] / [sasayakiRef] / [processedAudio] 均须是**已格式化**的最终
  /// 引用（`<img src>` / `[sound:]`；无则 null / 空串）。
  @protected
  RenderedMinedFields renderMediaPayload({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    required String? coverRef,
    required String? sentenceAudioRef,
    required String processedAudio,
    required Map<String, String> dictionaryMediaTags,
    String? audioWarning,
    bool keepEmpty = false,
  }) {
    final mediaContext = AnkiMiningContext(
      sentence: context.sentence,
      cueSentence: context.cueSentence,
      documentTitle: context.documentTitle,
      coverPath: coverRef,
      sentenceAudioPath: sentenceAudioRef,
      sentenceOffset: context.sentenceOffset,
    );

    final mediaPayload = AnkiMiningPayload(
      expression: payload.expression,
      reading: payload.reading,
      matched: payload.matched,
      furiganaPlain: payload.furiganaPlain,
      frequenciesHtml: payload.frequenciesHtml,
      freqHarmonicRank: payload.freqHarmonicRank,
      glossary: payload.glossary,
      glossaryFirst: payload.glossaryFirst,
      singleGlossaries: payload.singleGlossaries,
      pitchPositions: payload.pitchPositions,
      pitchCategories: payload.pitchCategories,
      phoneticTranscriptions: payload.phoneticTranscriptions,
      popupSelectionText: payload.popupSelectionText,
      audio: processedAudio,
      selectedDictionary: payload.selectedDictionary,
      dictionaryMedia: payload.dictionaryMedia,
    );

    return RenderedMinedFields(
      buildMinedFields(
        fieldMappings: settings.fieldMappings,
        payload: mediaPayload,
        context: mediaContext,
        dictionaryMediaTags: dictionaryMediaTags,
        keepEmpty: keepEmpty,
      ),
      audioWarning: audioWarning,
    );
  }

  // ── 远程单词音频失败原因（TODO-779）：两 backend 共用，杜绝两份文案漂移 ──────────

  /// 把单词远程音频的**非 200 HTTP 响应**格式化成给用户看的简短失败原因
  /// （含状态码与 URL）。两 backend 的远程音频路径在拒绝把错误响应体当 .mp3
  /// 写入（HBK-AUDIT-019）的同时调用本方法，把原因经 [AudioFetchOutcome.failed]
  /// 冒泡到 [MineOutcome.audioWarning]，让用户看到「为什么没音频」。纯函数、可单测。
  @protected
  String audioFetchHttpFailureReason(int statusCode, String url) =>
      'HTTP $statusCode for $url';

  /// 把单词远程音频抓取期间抛出的**异常**（DNS/连接失败/超时等）格式化成给用户看的
  /// 简短失败原因（含异常摘要与 URL）。与 [audioFetchHttpFailureReason] 同语义，覆盖
  /// 非 HTTP-码类的可见失败。纯函数、可单测。
  @protected
  String audioFetchErrorReason(Object error, String url) => '$error for $url';
}
