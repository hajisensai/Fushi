import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anki_media_dedup.dart';
import 'anki_models.dart';
import 'anki_note_type_definition.dart';
import 'anki_synchronized_clip_template.dart';
import 'card_source_link.dart';
import 'lapis_note_type.dart';
import 'anki_note_composer.dart';

export 'anki_note_composer.dart'
    show
        AudioFetchOutcome,
        RenderedMinedFields,
        kAnkiInlineVideoCoverExtensions,
        kAnkiVideoCoverExtensions,
        coverMediaRef,
        inlineVideoCoverHtml,
        inlineVideoSentenceAudioHtml,
        isAnkiInlineVideoCover,
        synchronizedVideoReplayHtml;

abstract class BaseAnkiRepository with AnkiNoteComposer {
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

  /// 载入期一次性迁移：存量配置里 `MiscInfo` 的映射**一字不差**还是旧出厂默认
  /// （纯标题、标题+时间、标题+时间+独立链接）时，改为标题自身作为来源链接，
  /// 同时保留片段时间（见 [LapisNoteType]）。
  ///
  /// 为什么只认「等于旧默认」：这等价于「用户从没碰过这个字段」，补齐是在替他
  /// 跟进出厂默认。凡是被改过的值——清空、换成别的占位符、或自己拼过别的
  /// 组合——一律不动，不覆盖用户意图。不会修改已经导出的旧卡。
  /// 幂等：改写后值不再等于旧默认。清理条件：无（SharedPreferences 无版本阶梯，
  /// 载入期改写即是它的迁移通道，与上面的别名改写同构）。
  static const String _legacyMiscInfoMapping = '{document-title}';
  static const String _miscInfoMappingWithClipTime =
      '{document-title} {clip-timestamp}';
  static const String _miscInfoMappingWithSource =
      '{document-title} {clip-timestamp} {source-link}';
  static const String _miscInfoMappingWithLinkedTitle =
      '{source-link} {clip-timestamp}';

  /// 读原始设置 JSON 的**唯一通道**：三个载入期迁移（W2-7 键搬移 + W2-2 别名改写
  /// + MiscInfo 补片段时间窗）都收敛在这里。子类若覆写 [loadSettings]（AnkiDroid 的
  /// legacy deck 迁移）也必须经由本方法取原始串，否则迁移被绕过。返回 null = 从未存过。
  ///
  /// 顺序有意：别名改写只把 `{sasayaki-audio}` 换成 `{sentence-audio}`，不可能凭空
  /// 造出或抹掉 `{document-title}`，故两条迁移互不干扰；但必须先改写再补 MiscInfo，
  /// 否则 `replaceAll` 会作用在已重编码的串上、把后一步的结果覆盖掉。
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
    if (raw != null) {
      final String? upgraded = upgradeMiscInfoMapping(raw);
      if (upgraded != null) {
        await prefs.setString(settingsKey, upgraded);
        raw = upgraded;
      }
    }
    return raw;
  }

  /// 精确旧默认 → [_miscInfoMappingWithSource] 的纯改写。
  /// 返回改写后的 JSON 串；**不需要改写时返回 `null`**（调用方据此决定要不要回写
  /// 持久层，避免每次启动都白写一遍）。
  ///
  /// 串不可解析 / 结构不对时同样返回 `null`：迁移不是校验器，损坏串该由既有的
  /// [loadSettings] try-catch 报告并退回默认设置，这里静默跳过不改变那条诊断路径。
  @visibleForTesting
  static String? upgradeMiscInfoMapping(String raw) {
    // 廉价前置门，与上面别名迁移的 `raw.contains(...)` 同一模式：loadSettings 在制卡 /
    // 查重 / 反查的热路径上被反复调用，settings 串含 availableDecks|availableNoteTypes
    // 可以很大。没有这一行，迁移完成后每次调用都要白解析一整份 JSON（叠加 loadSettings
    // 自己那次 = 解析两遍）。
    //
    // 门必须是**整个键值对**而不是裸 `{document-title}`：新值里也含那个子串，只判子串
    // 的话已迁移的用户仍会每次解析，门等于没加。形态依据是 `saveSettings` 恒用
    // `jsonEncode`（无空格）；万一哪天形态变了，最坏结果是这条迁移不触发（用户手动改
    // 一次映射），不会误改也不会崩——真正的判据仍是下面的结构化比较。
    if (!raw.contains('"MiscInfo":"$_legacyMiscInfoMapping"') &&
        !raw.contains('"MiscInfo":"$_miscInfoMappingWithClipTime"') &&
        !raw.contains('"MiscInfo":"$_miscInfoMappingWithSource"')) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final Object? mappings = decoded['fieldMappings'];
    if (mappings is! Map) return null;
    if (mappings['MiscInfo'] != _legacyMiscInfoMapping &&
        mappings['MiscInfo'] != _miscInfoMappingWithClipTime &&
        mappings['MiscInfo'] != _miscInfoMappingWithSource) return null;
    mappings['MiscInfo'] = _miscInfoMappingWithLinkedTitle;
    return jsonEncode(decoded);
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

  /// 这个后端能不能回读 Anki、核对「某张卡现在到底还在不在」。
  ///
  /// `true`（AnkiConnect / AnkiDroid）：[isDuplicate] 每次都真问 Anki，用户在 Anki 里
  /// 删掉的卡下一次查词就自动变回「可制卡 +」；[findMatchingNotes] 查不到就等于真的没有。
  ///
  /// `false`（AnkiMobile）：`anki://x-callback-url` 一个回读 collection 的入口都没有，
  /// 「已制卡 ✓」只能建立在本机账本上（`AnkiMobileMinedLedger`），于是
  /// [findMatchingNotes] 恒空**不代表这张卡不在 Anki 里**。在这种后端上把「查不到」
  /// 推断成「已被删、直接重制」是错的（可能默默制出第二张重复卡），也不能把账本里的
  /// ✓ 继续当成真值——编排层必须改成让用户裁决（`runAnkiMinedCardAction`），并用
  /// [forgetMinedCard] 接住用户的答案。
  bool get canVerifyExistingCards => true;

  /// 这个后端每加一张卡是不是都要**切到另一个 app**（AnkiMobile 的
  /// `anki://x-callback-url/addnote`：拉起 AnkiMobile，加完再 `x-success` 跳回）。
  ///
  /// 待发制卡队列据此决定补发方式：`false` 的后端可以在后台自动、连续补发；
  /// `true` 的后端绝不能自动补发（用户只是切回 Fushi，就会被莫名其妙拉去
  /// AnkiMobile），只能由用户显式点「全部发送」，并且一次只发一张、等跳回再发下一张。
  bool get switchesAppPerNote => false;

  /// 用户声明「这张卡我已经在 Anki 里删了」→ 划掉本地的「已制卡」记录，让 ✓ 变回 +。
  ///
  /// 只有 [canVerifyExistingCards] 为 `false` 的后端需要它（也只有它们覆写）：能回读
  /// Anki 的后端不存在「本地记录与 Anki 不一致」这件事，下一次查词就自我纠正了。
  ///
  /// 返回是否真的划掉了（本来就没有记录 / 后端不需要 → `false`）。
  Future<bool> forgetMinedCard(String expression) async => false;

  /// TODO-1007/1008：读取一张已存在 note（[noteId]）的现有字段（字段名 → 值），供
  /// note viewer 只读展示。两后端各自覆写（AnkiConnect `notesInfo` / AnkiDroid
  /// ContentProvider getNote）。note 不存在 / 后端不支持时返回 `null`。
  Future<Map<String, String>?> noteFields(int noteId) async => null;

  /// Updating an ordinary freshly mined card can capture another locator UUID.
  /// Retain the original note's identity, because field updates never add tags.
  /// Legacy notes have no source marker/link and are not silently migrated.
  ///
  /// [existingFields] 已由调用方读过时直接传入（覆盖链路本来就要读一遍现有字段，
  /// 见 [fieldsForOverwrite]），省一次 `notesInfo` 往返；为 null 时自己读。
  @protected
  Future<AnkiMiningContext> contextForExistingSourceNote(
    int noteId,
    AnkiMiningContext context, {
    Map<String, String>? existingFields,
  }) async {
    final Map<String, String>? fields =
        existingFields ?? await noteFields(noteId);
    if (fields == null) throw StateError('Existing note could not be read');
    final Map<String, CardSourceLink> sources = <String, CardSourceLink>{
      for (final String field in fields.values)
        for (final CardSourceLink link in CardSourceLink.fromHtml(field))
          link.sourceId: link,
    };
    if (sources.length > 1) {
      throw StateError('Existing source identity is ambiguous');
    }
    if (sources.isEmpty) return context.withSourceLink(null);
    final CardSourceLink previous = sources.values.single;
    return context.withSourceLink(
      context.sourceLink?.withSourceId(previous.sourceId) ?? previous,
    );
  }

  /// Prepare mapped fields/media for an explicit field-diff editor. Never adds
  /// a note or changes an existing note. Uploaded unused media may be cleaned
  /// by Anki's normal unused-media cleanup if the user cancels the editor.
  Future<Map<String, String>> prepareSourceNoteFields({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      throw UnsupportedError('Source note editing is unavailable');

  /// Candidate notes whose fields contain the source ID substring (see
  /// [CardSourceLink.searchQueryForSourceId]). Must propagate backend failure
  /// instead of reporting "not found". Candidates are not identities:
  /// [readSourceNote] confirms each one by parsing its field hrefs.
  @protected
  Future<List<int>> findSourceNoteCandidates(String sourceId) async =>
      throw UnsupportedError('Source note lookup is unavailable');

  /// Fields of one candidate note for source identity checks. Returns `null`
  /// only when the note no longer exists; a backend/transport failure must
  /// throw. This is deliberately not [noteFields], whose fail-soft `null`
  /// (viewer convenience) would let a timeout masquerade as "note deleted".
  @protected
  Future<Map<String, String>?> sourceNoteFields(int noteId) async =>
      throw UnsupportedError('Source note lookup is unavailable');

  @protected
  Future<void> writeSourceNoteFields(
    int noteId,
    Map<String, String> fields,
  ) async =>
      throw UnsupportedError('Source note editing is unavailable');

  /// Resolve the single note carrying [sourceId] in a `fushi://source` href.
  /// A substring candidate that parses to a different (or no) source link is
  /// not a match; a candidate deleted between search and read is skipped.
  /// Backend failures propagate: "could not ask" is never reported as "gone".
  Future<AnkiSourceNote?> readSourceNote(String sourceId) async {
    CardSourceLink.validateSourceId(sourceId);
    final Set<int> candidates =
        (await findSourceNoteCandidates(sourceId)).toSet();
    final Map<int, Map<String, String>> matches = <int, Map<String, String>>{};
    for (final int noteId in candidates) {
      if (noteId <= 0) throw StateError('Invalid source note candidate');
      final Map<String, String>? fields = await sourceNoteFields(noteId);
      if (fields == null) continue;
      final bool carriesSource = fields.values.any(
        (String field) => CardSourceLink.fromHtml(field)
            .any((CardSourceLink link) => link.sourceId == sourceId),
      );
      if (carriesSource) matches[noteId] = fields;
    }
    if (matches.isEmpty) return null;
    if (matches.length != 1) {
      throw StateError('Card source identity is not unique');
    }
    final MapEntry<int, Map<String, String>> match = matches.entries.single;
    return AnkiSourceNote(
      sourceId: sourceId,
      noteId: match.key,
      fields: match.value,
    );
  }

  /// Optimistic conflict check immediately before a partial field update.
  /// AnkiConnect exposes no atomic compare-and-swap operation; edits made in
  /// another Anki window between this check and write cannot be locked out.
  /// Untouched fields, tags and card scheduling are never submitted.
  Future<void> patchSourceNote({
    required AnkiSourceNote original,
    required Map<String, String> fields,
  }) async {
    if (fields.isEmpty) return;
    final Map<String, String> patch = Map<String, String>.of(fields);
    final AnkiSourceNote? current = await readSourceNote(original.sourceId);
    if (current == null || current.noteId != original.noteId) {
      throw StateError('Source note identity changed');
    }
    for (final String field in patch.keys) {
      if (!original.fields.containsKey(field) ||
          !current.fields.containsKey(field) ||
          current.fields[field] != original.fields[field]) {
        throw StateError('Source note field changed: $field');
      }
    }
    await writeSourceNoteFields(current.noteId, patch);
    // Never retry or restore the old snapshot after a mismatch: another editor
    // may already have saved a newer value. The caller retains its draft and
    // asks the user to resolve the conflict explicitly.
    final AnkiSourceNote? verified = await readSourceNote(original.sourceId);
    if (verified == null || verified.noteId != current.noteId) {
      throw StateError('Source note identity changed after writing');
    }
    for (final MapEntry<String, String> entry in patch.entries) {
      if (verified.fields[entry.key] != entry.value) {
        throw StateError(
          'Source note field changed after writing: ${entry.key}',
        );
      }
    }
  }

  /// TODO-1007/1008：在 Anki 中打开 / 浏览 [noteId] 对应的卡片（AnkiConnect 用
  /// `guiBrowse(nid:<id>)`；AnkiDroid 用 ACTION_VIEW intent 跳 ContentProvider note）。
  /// 成功返回 `true`，后端不支持 / 失败返回 `false`（不抛，供宿主据此提示）。
  ///
  /// **默认实现 = 优雅降级**：基类返回 `false`。
  Future<bool> openNoteInAnki(int noteId) async => false;

  /// BUG-2051：点 ↗「在 Anki 中打开**这个词**已有的卡」。
  ///
  /// 语义是「按词去 Anki 里看」，不是「按我们记下的某个 note id 去看」——后者要求
  /// 先反查一遍 id，而那条反查（按第一字段**名**查）与画 ✓ 的判据（Anki 内建第一
  /// 字段 checksum，跨笔记类型）根本不是一件事，于是出现「✓ 说已制卡、↗ 说没有卡」。
  /// 两条判据只能留一条。
  ///
  /// **默认实现**：没有原生「按词打开」能力的后端（AnkiDroid 只有按 note id 的
  /// deep link）走 [findMatchingNotes] + [openNoteInAnki]。这些后端的查重与反查
  /// 本来就限定同一笔记类型（AnkiDroid 的 `checkForDuplicates` / `findNotesByContent`
  /// 都传 `models:[当前笔记类型]`），两者同源，不存在本 bug；多张命中时打开**最近
  /// 一张**（note id 最大 = 创建时间最新），不再弹选择面板——↗ 的职责是「带我去看」，
  /// 挑哪张是 Anki 浏览器自己的事。
  Future<AnkiOpenWordOutcome> openWordInAnki(
    String expression,
    String reading,
  ) async {
    if (expression.isEmpty) return AnkiOpenWordOutcome.failed;
    final List<MinedNoteRef> matches =
        await findMatchingNotes(expression, reading);
    if (matches.isEmpty) return AnkiOpenWordOutcome.noMatch;
    final int newest = matches
        .map((MinedNoteRef m) => m.noteId)
        .reduce((int a, int b) => a > b ? a : b);
    return await openNoteInAnki(newest)
        ? AnkiOpenWordOutcome.opened
        : AnkiOpenWordOutcome.failed;
  }

  /// BUG-1799：复核 [noteIds] 里哪些 note **已经不在 Anki 中了**（用户在 Anki 里删了卡）。
  ///
  /// 返回值口径是本方法的全部要害：**只返回「后端明确应答、且应答里没有这张 note」的 id**。
  /// 查询失败、后端不可达、后端不支持一律返回**空集**，而不是「全都当成已删除」——
  /// 调用方拿它去清「已制卡」标记，一旦把「问不到」误判成「已删除」，Anki 没开着就会
  /// 把满屏徽章全部清空，那比不复核更糟。这也是本方法返回**已删除集合**而不是
  /// `bool` / `Map<int,bool>` 的原因：`bool` 表达不了「不知道」这个第三态，
  /// 空集天然等于「没有任何一张被确认删除」。
  ///
  /// **默认实现 = 优雅降级**：基类恒返回空集（拿不到 note 存在性的后端 —— AnkiDroid
  /// 只回 bool 查重、AnkiMobile 只有 URL scheme —— 保持既有 latch 行为不变）。
  Future<Set<int>> findDeletedNotes(Set<int> noteIds) async => const <int>{};

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

  /// 本次制卡的目标笔记类型能否承载音画同步片段（判据见
  /// [noteTypeRendersSynchronizedClip]）。`null` = 无法判定（后端读不到模板、没选
  /// 笔记类型、模板列表为空），调用方据此保持用户偏好。
  ///
  /// 设置与模板必须出自**同一个后端**：转发到互联主机的仓库在主机上按主机的设置
  /// 建卡，必须自己覆写，不能拿本机设置去配主机的模板。后端可达性错误照抛。
  Future<bool?> rendersSynchronizedClip() async {
    if (!supportsNoteTypeEditing) return null;
    final AnkiSettings settings = await loadSettings();
    final AnkiNoteType? noteType = settings.selectedNoteType;
    if (noteType == null) return null;
    final AnkiNoteTypeDefinition? definition =
        await readNoteTypeDefinition(noteType.name);
    // AnkiDroid 游标为空时回空模板列表：那是「没读到」，不是「模板不渲染」。
    if (definition == null || definition.templates.isEmpty) return null;
    return noteTypeRendersSynchronizedClip(
      definition: definition,
      fieldMappings: settings.fieldMappings,
    );
  }

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

  /// 本后端**此刻真能不能**做媒体去重。
  ///
  /// [supportsMediaMaintenance] 只说「这个后端类型实现了去重」，说不了「媒体
  /// 目录这台机器读得到」——AnkiConnect 是同一个类，桌面上跑是本机直读，手机
  /// 连局域网里的桌面 Anki 也是同一个类，但 `getMediaDirPath` 返回的是**那台
  /// 机器**的路径，本机根本不存在。用静态能力当门控的后果是手机上显示一个
  /// 点了只会说「不可用」的区块。
  ///
  /// 默认实现 = 静态能力（不做任何 I/O）；需要探测的后端覆写。后端不可达时
  /// **照抛**——调用方据此保持「未知」，不要把「Anki 没开」误判成「不支持」。
  Future<bool> probeMediaMaintenance() async => supportsMediaMaintenance;

  /// [runMediaDedup] 的 `onProgress` / `shouldCancel` 是不是真的会被调用。
  ///
  /// 本进程内跑的后端恒 true。互联「制卡到已配对设备」把整轮去重推给主机跑，
  /// 一次 HTTP 往返里没有回传进度的通道、也没有中途叫停的通道——那种后端返回
  /// false，UI 据此画不确定进度条并**隐藏取消按钮**。摆一个点了没反应的取消
  /// 按钮比没有取消按钮更糟：用户会以为已经停了。
  bool get supportsMediaMaintenanceProgress => true;

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

  // ── 卡组新卡按词频重排 ───────────────────────────────────────────────────

  /// 本后端能不能读某卡组的新卡并改写它们的队列位置。
  ///
  /// **后端不对称（有意）**：只有 AnkiConnect 有卡片级读写（`findCards` /
  /// `cardsInfo` / `setSpecificValueOfCard`）。AnkiDroid ContentProvider 与
  /// AnkiMobile 的 URL scheme 都没有改 `due` 的接口；互联「制卡到已配对设备」
  /// 也没有对应端点。这些后端默认 false，UI 据此把入口置灰并说明原因。
  bool get supportsDeckReposition => false;

  /// 列出 [deckName]（含子卡组、排除筛选牌组）里的全部**新卡**。
  /// 默认实现 = 不支持，抛 [UnsupportedError]；调用前先看
  /// [supportsDeckReposition]。
  Future<List<AnkiCardInfo>> listNewCards(String deckName) async =>
      throw UnsupportedError('This Anki backend cannot list deck cards.');

  /// 批量写回新卡位置。默认实现 = 不支持。
  Future<AnkiCardDueWriteResult> setNewCardPositions(
    List<AnkiCardDueUpdate> updates,
  ) async =>
      throw UnsupportedError('This Anki backend cannot reposition cards.');

  // 这些 static 搬进了 [AnkiNoteComposer]（Dart 的 static 不随 mixin 继承）；这里
  // 转发一份，既有的 `BaseAnkiRepository.xxx` 调用点不必改。
  static const String fushiTag = AnkiNoteComposer.fushiTag;
  static const String bookTag = AnkiNoteComposer.bookTag;
  static const String videoTag = AnkiNoteComposer.videoTag;
  static const String gameTag = AnkiNoteComposer.gameTag;
  static const String charPositionTagPrefix =
      AnkiNoteComposer.charPositionTagPrefix;
  static String? formatCharPositionTag(int? absoluteChars) =>
      AnkiNoteComposer.formatCharPositionTag(absoluteChars);
  static String previewFromFieldValue(String value, {int maxLen = 60}) =>
      AnkiNoteComposer.previewFromFieldValue(value, maxLen: maxLen);
  static String? sanitizeTitleTag(String? title) =>
      AnkiNoteComposer.sanitizeTitleTag(title);
  @protected
  static bool shouldYieldSelectionText({
    required AnkiMiningPayload payload,
    required String? noteTypeName,
    required Map<String, String> fieldMappings,
  }) =>
      AnkiNoteComposer.shouldYieldSelectionText(
        payload: payload,
        noteTypeName: noteTypeName,
        fieldMappings: fieldMappings,
      );
  @protected
  static Map<String, String> fieldsForOverwrite({
    required Iterable<String> existingFieldNames,
    required Map<String, String> rendered,
  }) =>
      AnkiNoteComposer.fieldsForOverwrite(
        existingFieldNames: existingFieldNames,
        rendered: rendered,
      );
}
