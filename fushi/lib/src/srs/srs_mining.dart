/// 挖词目标「Fushi SRS」（计划 PR3a）：制卡时把卡写进内置复习，而不是发往 Anki。
///
/// - [SrsMiner]（引擎 `package:fushi_engine/srs/srs_miner.dart`）：一次制卡落进 [SrsDbStore]。字段渲染与 Anki 三个后端是同一套
///   [AnkiNoteComposer]（`renderMediaPayload` → `buildMinedFields`），映射固定用
///   Lapis 的默认映射，按 [srsLapisFieldId] 换成 SRS 的 fieldId；媒体（单词音频、
///   句子音频、截图 / 封面、词典图片）存进 [SrsMediaStore]，字段里的引用换成存储后的
///   内容哈希文件名。查重用 SRS 的词状态（词形 + 读音，同形异读不算重复）。
/// - [SrsMiningAnkiRepository]：`ankiRepositoryProvider` 装饰链最外层。只有复习模块
///   开着且目标是「Fushi 复习」时才包这一层（见 anki_view_model.dart），模块关着时链上
///   根本没有它。
///
/// 「后台制卡」（[SrsMiningAnkiRepository] 的 `backgroundMining`，反馈 Rl00Di264R）：制卡请求
/// 用待发队列同一套冻结 / 还原（[ForwardedMinePayloadBuilder] → [withMaterializedMiningContext]）
/// 搬进进程级串行队列，入队即回 [MineOutcome.queued]，随后在后台依次写进复习；后台结果
/// （失败 / 重复 / 音频缺失）经 [SrsBackgroundMineReporter] 交给装配处提示。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_new_card_positions.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/anki/delegating_anki_repository.dart';
import 'package:fushi/src/anki/forwarded_mine_codec.dart';
import 'package:fushi/src/mining/serial_job_queue.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_miner.dart';

/// 打开 SRS 制卡所需的 store + 媒体目录（模块关着 / 打开失败时为 null）。
typedef SrsMinerResolver = Future<SrsMiner?> Function();

/// 打开一条 SRS 笔记的编辑页（导航器不可用时返回 false）。
typedef SrsNoteOpener = Future<bool> Function(String noteId);

/// 一张后台制卡写完（或没写成）后的结果：[expression] 是提示用的词条（取不到用句子），
/// [outcome] 是那次写入的真实结果（成功 / 重复 / 失败）。
typedef SrsBackgroundMineReporter =
    void Function(String expression, MineOutcome outcome);

/// `ankiRepositoryProvider` 装饰链里的 SRS 层（见文件头）。挖词目标 = Fushi 复习时
/// 制卡链路上**会写卡或依赖 Anki 连接**的操作一律走复习，不再碰 Anki：
///
/// - 制卡 / 查重 / 覆写 / 同词反查 / 读字段 / 打开笔记 / 已删复核：走 SRS。笔记的
///   整数句柄 = [SrsIds.ankiNumericId]（与 AnkiConnect 兼容端点同一个派生）。
/// - 「回到出处改卡」：先在复习里找带这个出处的笔记；复习里没有才交给 Anki——出处
///   链接可能来自切换前制进 Anki 的卡，那张卡本来就在 Anki 里。
/// - 新卡按词频重排：走复习（[listNewCards] / [setNewCardPositions] 读写卡片的
///   新卡位置，见 [SrsDbStore.newCardsInDeck]），只有手动重排。复习不需要制卡后自动重排：
///   牌组「新卡顺序 = 按词频」时出卡直接按卡上的词频名次排；手动重排写的位置用于
///   「新卡顺序 = 按位置」的牌组，以及按词频时没有名次的卡。
/// - Anki 专属能力（建笔记类型 / 牌组、改模板样式、媒体去重、同步片段模板探测）：
///   在此模式下关闭（能力位为 false / 明确报不可用），设置页对应入口已隐藏。
/// - 只读写本机偏好的设置读写（loadSettings / saveSettings / updateSettings /
///   readSettingsJson）照旧委托：标签、允许重复等共用设置就存在那里。
/// - fetchConfiguration：照旧委托（只读 Anki 的牌组 / 笔记类型清单，不写任何东西；
///   刷新入口在此模式下已隐藏）。
class SrsMiningAnkiRepository extends DelegatingAnkiRepository {
  SrsMiningAnkiRepository({
    required super.inner,
    required SrsMinerResolver miner,
    SrsNoteOpener? openNote,
    void Function()? onCardsAdded,
    bool Function()? backgroundMining,
    SrsBackgroundMineReporter? onBackgroundOutcome,
    ForwardedMinePayloadBuilder? payloadBuilder,
  }) : _miner = miner,
       _openNote = openNote,
       _onCardsAdded = onCardsAdded,
       _backgroundMining = backgroundMining,
       _onBackgroundOutcome = onBackgroundOutcome,
       _payloadBuilder = payloadBuilder ?? ForwardedMinePayloadBuilder();

  final SrsMinerResolver _miner;
  final SrsNoteOpener? _openNote;

  /// 「后台制卡」开关，每次制卡现读（改完立即生效，不必重建装饰链）。null = 恒同步
  /// （互联主机替对端制卡、浏览器扩展：对端要的是确定的结果，不能回「已入队」）。
  final bool Function()? _backgroundMining;

  /// 后台写入的结果出口（装配处弹提示）。成功同样回调：音频缺失要提示。
  final SrsBackgroundMineReporter? _onBackgroundOutcome;

  /// 冻结请求：与待发队列 / 互联转发同一个打包器（媒体全读成字节）。
  final ForwardedMinePayloadBuilder _payloadBuilder;

  /// 后台写入队列：进程级（provider 重建会换掉仓库实例，已入队的卡不能跟着丢、
  /// 也不能两条队列并发写同一个库），串行、永不毒化（[SerialJobQueue]）。
  static SerialJobQueue _backgroundQueue = SerialJobQueue();

  /// 测试用：直接拿到后台队列（在它前面插一个挂起的任务，验证「入队即返回」）。
  @visibleForTesting
  static SerialJobQueue get debugBackgroundQueue => _backgroundQueue;

  /// 测试用：等已入队的后台写入全部结束。
  @visibleForTesting
  static Future<void> debugBackgroundIdle() => _backgroundQueue.enqueue<void>(
    () async {},
    buildFailure: (Object error, StackTrace stack) {},
  );

  /// 测试用：换一条新的后台队列（上一个用例挂住的任务不串到下一个）。
  @visibleForTesting
  static void debugResetBackgroundQueue() {
    _backgroundQueue = SerialJobQueue();
  }

  /// 制卡成功写进复习后调用（装配处递增 `srsRevisionProvider`，牌组列表与首页
  /// 复习条的计数随之重读）。
  final void Function()? _onCardsAdded;

  /// 本仓库读到过的「出处 → 复习笔记」（[readSourceNote] 命中复习时记下），
  /// [prepareSourceNoteFields] 据此决定按哪条笔记的类型渲染。
  final Map<String, String> _srsSourceNotes = <String, String>{};

  static const String _unavailable = 'Fushi review is not available.';

  Future<SrsMiner> _requireMiner() async {
    final SrsMiner? miner = await _miner();
    if (miner == null) throw StateError(_unavailable);
    return miner;
  }

  /// 整数句柄 → 现存 SRS 笔记 id（不存在 / 已删 / 复习不可用为 null）。
  Future<String?> _noteIdOf(SrsMiner miner, int handle) async {
    final String? id = await miner.store.noteIdForAnkiNumericId(handle);
    if (id == null) return null;
    final SrsNoteView? note = await miner.store.note(id);
    return note == null || note.deletedAt != null ? null : id;
  }

  // ------------------------------------------------------------ 制卡 / 查重

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) return MineOutcome.failure(_unavailable);
    if (_backgroundMining?.call() ?? false) {
      return _enqueueBackground(miner, rawPayloadJson, context);
    }
    return _mineNow(miner, rawPayloadJson, context);
  }

  Future<MineOutcome> _mineNow(
    SrsMiner miner,
    String rawPayloadJson,
    AnkiMiningContext context,
  ) async {
    final MineOutcome outcome = await miner.mine(
      settings: await inner.loadSettings(),
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
    if (outcome.result == MineResult.success) _onCardsAdded?.call();
    return outcome;
  }

  /// 后台制卡：冻结 → 入队 → 立即回 [MineOutcome.queued]。
  ///
  /// 冻结必须在返回前完成（与待发队列同一条约束）：调用方在 [mineEntry] 返回后就清理
  /// 临时封面 / 句子音频。冻结失败不假装入队，原样报失败。制卡器在入队这一刻取定：
  /// 卡落进点「制卡」时那份配置的复习，排队期间切 Profile 不改道。
  ///
  /// 后台那一步与同步制卡是同一个 [SrsMiner.mine]（查重、落点解析、首字段为空拒建都在
  /// 那里），只是结果改由 [_onBackgroundOutcome] 交出去——连续挖同一个词时第二张在
  /// 后台被判重复，同样会被提示，而不是静默丢掉。
  Future<MineOutcome> _enqueueBackground(
    SrsMiner miner,
    String rawPayloadJson,
    AnkiMiningContext context,
  ) async {
    final ForwardedMinePayload payload;
    final String deckName;
    try {
      payload = await _payloadBuilder.build(
        rawPayloadJson: rawPayloadJson,
        context: context,
      );
      deckName = await miner.destinationDeckName(rawPayloadJson);
    } catch (e, stack) {
      return MineOutcome.failure(
        'Fushi review: could not queue the card: $e',
        error: e,
        stackTrace: stack,
      );
    }
    final String expression = _displayExpression(rawPayloadJson, context);
    unawaited(
      _backgroundQueue
          .enqueue<MineOutcome>(
            () => withMaterializedMiningContext<MineOutcome>(
              payload,
              (String raw, AnkiMiningContext ctx) => _mineNow(miner, raw, ctx),
            ),
            buildFailure: (Object e, StackTrace stack) => MineOutcome.failure(
              'Fushi review: $e',
              error: e,
              stackTrace: stack,
            ),
          )
          // 结果出口（提示）自身抛的异常不在这里吞：照常进 zone 的未处理错误（错误日志）。
          .then(
            (MineOutcome outcome) =>
                _onBackgroundOutcome?.call(expression, outcome),
          ),
    );
    return MineOutcome.queued(deckName: deckName);
  }

  /// 提示用的词条：取 fields 的 expression，取不到用句子（与待发队列列表同口径）。
  static String _displayExpression(
    String rawPayloadJson,
    AnkiMiningContext context,
  ) {
    try {
      final Object? json = jsonDecode(rawPayloadJson);
      if (json is Map) {
        final String expression = (json['expression'] as String?)?.trim() ?? '';
        if (expression.isNotEmpty) return expression;
      }
    } on FormatException {
      // 载荷坏了：后台那一步会按「载荷解析失败」报出来，这里只取句子。
    }
    return context.sentence.trim();
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final SrsMiner? miner = await _miner();
    return miner != null && await miner.isDuplicate(expression, reading);
  }

  // ------------------------------------------------------------ 覆写 / 反查

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) return MineOutcome.failure(_unavailable);
    final String? id = await _noteIdOf(miner, noteId);
    if (id == null) {
      return MineOutcome.failure(
        'Fushi review: the card to overwrite no longer exists.',
      );
    }
    try {
      // 出处身份跟着原卡走（与 Anki 覆写同口径）：覆写换了句子位置，sourceId 不变。
      context = await contextForExistingSourceNote(
        noteId,
        context,
        existingFields: await miner.fieldsByName(id),
      );
    } catch (e, stack) {
      return MineOutcome.failure(
        'Fushi review: $e',
        error: e,
        stackTrace: stack,
      );
    }
    return miner.overwrite(
      noteId: id,
      settings: await inner.loadSettings(),
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
  }

  /// 「覆写范围 = 全部」时返回这个词最新的一条复习笔记；「仅最近一张」恒 null。
  @override
  Future<int?> findOverwriteTargetNoteId(
    String expression,
    String reading,
  ) async {
    final AnkiSettings settings = await inner.loadSettings();
    if (settings.overwriteScope != AnkiOverwriteScope.all) return null;
    final SrsMiner? miner = await _miner();
    if (miner == null) return null;
    final List<SrsNoteCacheRow> notes = await miner.matchingNotes(
      expression,
      reading,
    );
    return notes.isEmpty ? null : SrsIds.ankiNumericId(notes.first.id);
  }

  /// 新建的在前（句柄是哈希、大小不代表新旧，顺序以创建时间为准）。
  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
    String expression,
    String reading,
  ) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) return const <MinedNoteRef>[];
    return <MinedNoteRef>[
      for (final SrsNoteCacheRow n in await miner.matchingNotes(
        expression,
        reading,
      ))
        MinedNoteRef(
          noteId: SrsIds.ankiNumericId(n.id),
          preview: BaseAnkiRepository.previewFromFieldValue(n.sortField),
        ),
    ];
  }

  @override
  Future<Map<String, String>?> noteFields(int noteId) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) return null;
    final String? id = await _noteIdOf(miner, noteId);
    return id == null ? null : miner.fieldsByName(id);
  }

  /// 复习是本机库，能回读：用户在复习里删掉的卡下次查词就变回「可制卡」。
  @override
  bool get canVerifyExistingCards => true;

  @override
  bool get switchesAppPerNote => false;

  @override
  Future<bool> forgetMinedCard(String expression) async => false;

  /// 反馈 JNyykxvuY9：删复习笔记走 `SrsDbStore.deleteNote`（Rust 核心记一条删除
  /// 操作，经复习同步 v2 成为墓碑传到各设备），不是物理删行。
  @override
  bool get canDeleteMinedNotes => true;

  @override
  Future<bool> deleteMinedNote(int noteId) async {
    final SrsMiner miner = await _requireMiner();
    final String? id = await _noteIdOf(miner, noteId);
    if (id == null) return false;
    await miner.store.deleteNote(id);
    _onCardsAdded?.call();
    return true;
  }

  /// 只返回明确已不在复习里的句柄（复习不可用时返回空集：不知道 ≠ 已删）。
  @override
  Future<Set<int>> findDeletedNotes(Set<int> noteIds) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) return const <int>{};
    return <int>{
      for (final int handle in noteIds)
        if (await _noteIdOf(miner, handle) == null) handle,
    };
  }

  // ------------------------------------------------------------ 打开笔记

  /// BUG-3790：笔记住在 Fushi 复习里，界面不能再说「Anki」。
  @override
  MinedNoteHome get minedNoteHome => MinedNoteHome.fushiReview;

  /// 打开走装配处注入的复习笔记打开器；没注入就打不开。
  @override
  bool get canOpenMinedNote => _openNote != null;

  @override
  Future<bool> openNoteInAnki(int noteId) async {
    final SrsNoteOpener? open = _openNote;
    final SrsMiner? miner = await _miner();
    if (open == null || miner == null) return false;
    final String? id = await _noteIdOf(miner, noteId);
    return id != null && await open(id);
  }

  /// 打开这个词**最新**的一条复习笔记（基类按句柄取最大，对哈希句柄不成立）。
  @override
  Future<AnkiOpenWordOutcome> openWordInAnki(
    String expression,
    String reading,
  ) async {
    if (expression.isEmpty) return AnkiOpenWordOutcome.failed;
    final SrsNoteOpener? open = _openNote;
    final SrsMiner? miner = await _miner();
    if (open == null || miner == null) return AnkiOpenWordOutcome.failed;
    final List<SrsNoteCacheRow> notes = await miner.matchingNotes(
      expression,
      reading,
    );
    if (notes.isEmpty) return AnkiOpenWordOutcome.noMatch;
    return await open(notes.first.id)
        ? AnkiOpenWordOutcome.opened
        : AnkiOpenWordOutcome.failed;
  }

  // ------------------------------------------------------------ 回到出处改卡

  /// 复习里带这个出处的笔记优先；复习里没有才问 Anki（切换前制进 Anki 的卡）。
  @override
  Future<AnkiSourceNote?> readSourceNote(String sourceId) async {
    CardSourceLink.validateSourceId(sourceId);
    final SrsMiner miner = await _requireMiner();
    final Map<String, Map<String, String>> matches =
        <String, Map<String, String>>{};
    for (final String id in await miner.sourceNoteCandidates(sourceId)) {
      final Map<String, String>? fields = await miner.fieldsByName(id);
      if (fields == null) continue;
      final bool carries = fields.values.any(
        (String f) => CardSourceLink.fromHtml(
          f,
        ).any((CardSourceLink l) => l.sourceId == sourceId),
      );
      if (carries) matches[id] = fields;
    }
    if (matches.isEmpty) {
      _srsSourceNotes.remove(sourceId);
      return inner.readSourceNote(sourceId);
    }
    if (matches.length != 1) {
      throw StateError('Card source identity is not unique');
    }
    final MapEntry<String, Map<String, String>> match = matches.entries.single;
    _srsSourceNotes[sourceId] = match.key;
    return AnkiSourceNote(
      sourceId: sourceId,
      noteId: SrsIds.ankiNumericId(match.key),
      fields: match.value,
    );
  }

  /// 乐观并发检查同 Anki（写前重读比对、写后复核）；原卡在 Anki 时交给 Anki。
  @override
  Future<void> patchSourceNote({
    required AnkiSourceNote original,
    required Map<String, String> fields,
  }) async {
    if (fields.isEmpty) return;
    final AnkiSourceNote? current = await readSourceNote(original.sourceId);
    final String? srsId = _srsSourceNotes[original.sourceId];
    if (srsId == null) {
      return inner.patchSourceNote(original: original, fields: fields);
    }
    if (current == null || current.noteId != original.noteId) {
      throw StateError('Source note identity changed');
    }
    for (final String field in fields.keys) {
      if (!original.fields.containsKey(field) ||
          !current.fields.containsKey(field) ||
          current.fields[field] != original.fields[field]) {
        throw StateError('Source note field changed: $field');
      }
    }
    await (await _requireMiner()).writeFieldsByName(srsId, fields);
    final AnkiSourceNote? verified = await readSourceNote(original.sourceId);
    if (verified == null || verified.noteId != current.noteId) {
      throw StateError('Source note identity changed after writing');
    }
    for (final MapEntry<String, String> entry in fields.entries) {
      if (verified.fields[entry.key] != entry.value) {
        throw StateError(
          'Source note field changed after writing: ${entry.key}',
        );
      }
    }
  }

  /// 出处在复习里时按那条笔记自己的类型渲染（媒体进复习的媒体库）；否则交给 Anki。
  @override
  Future<Map<String, String>> prepareSourceNoteFields({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final String? sourceId = context.sourceLink?.sourceId;
    final String? srsId = sourceId == null ? null : _srsSourceNotes[sourceId];
    if (srsId == null) {
      return inner.prepareSourceNoteFields(
        rawPayloadJson: rawPayloadJson,
        context: context,
      );
    }
    return (await _requireMiner()).prepareFieldsFor(
      noteId: srsId,
      settings: await inner.loadSettings(),
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
  }

  // ------------------------------------------------------------ Anki 专属：关闭

  @override
  bool get supportsNoteTypeEditing => false;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
    String modelName,
  ) async => null;

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) async =>
      false;

  @override
  Future<bool> updateNoteTypeTemplates(
    String modelName,
    List<AnkiCardTemplate> templates,
  ) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async =>
      throw UnsupportedError(
        'Creating Anki note types is off while mining into Fushi review.',
      );

  @override
  Future<bool> createDeck(String name) async => throw UnsupportedError(
    'Creating Anki decks is off while mining into Fushi review.',
  );

  /// 复习卡面不是 Anki 模板，这条判据无从判定：null = 保持用户偏好。
  @override
  Future<bool?> rendersSynchronizedClip() async => null;

  @override
  bool get supportsMediaMaintenance => false;

  @override
  Future<bool> probeMediaMaintenance() async => false;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({
    bool dryRun = false,
    Future<void> Function(Map<String, dynamic> entry)? onJournal,
    AnkiMediaDedupOnProgress? onProgress,
    bool Function()? shouldCancel,
  }) async => null;

  // ------------------------------------------------------------ 新卡按词频重排

  @override
  bool get supportsDeckReposition => true;

  /// 重排写的是本机复习库（[SrsDbStore]），没有「连着的那一端此刻能不能写」这回事：
  /// 恒为 true。**必须与 [supportsDeckReposition] 成对覆盖**——基类
  /// [DelegatingAnkiRepository] 把探测委派给 inner（Anki 后端），不覆盖就会拿
  /// AnkiConnect / AnkiDroid 的能力来判复习，复习下重排被误判为不支持（BUG-4122）。
  @override
  Future<bool> probeDeckReposition() async => true;

  /// 复习出卡按牌组「新卡顺序」直接读卡上的词频名次，刚挖的卡立刻就在对的位置：不需要
  /// 制卡后改写新卡位置（那样每挖一个词都要同步一批位置修改记录）。
  @override
  bool get supportsAutoReposition => false;

  /// [deckName]（复习牌组全名，含子牌组）里的新卡，形状对齐 AnkiConnect `cardsInfo`：
  /// 整数 id = [SrsIds.ankiNumericId]，`due` = 此刻的出卡位置（从没排过的卡是临时编号，
  /// `hasStoredPosition` 为 false），`fields` 只给重排取 rank 用的三种角色（见
  /// [srsRepositionRoleFields]）。
  @override
  Future<List<AnkiCardInfo>> listNewCards(String deckName) async {
    final SrsMiner miner = await _requireMiner();
    final List<SrsNewCardEntry> entries = await miner.store.newCardsInDeck(
      deckName,
    );
    final Map<String, Map<String, String>> mappingByType =
        <String, Map<String, String>>{};
    return <AnkiCardInfo>[
      for (final SrsNewCardEntry e in entries)
        AnkiCardInfo(
          cardId: SrsIds.ankiNumericId(e.card.id),
          noteId: SrsIds.ankiNumericId(e.note.id),
          ord: e.ord,
          due: e.position,
          hasStoredPosition: e.card.newPosition != null,
          type: 0,
          queue: e.card.suspended ? -1 : 0,
          modelName: e.noteType.name,
          deckName: deckName,
          fields: srsRepositionRoleFields(
            e.note,
            e.noteType,
            mappingByType.putIfAbsent(
              e.noteType.id,
              () => miner.miningFieldMappingsFor(e.noteType),
            ),
          ),
        ),
    ];
  }

  /// 写回前重校验只要 id：只读卡片缓存的 ID 列，不读笔记、不物化。
  @override
  Future<Set<int>> newCardIdsIn(String deckName) async {
    final SrsMiner miner = await _requireMiner();
    return <int>{
      for (final String id in await miner.store.newCardIdsInDeck(deckName))
        SrsIds.ankiNumericId(id),
    };
  }

  /// 复习的新卡位置只是排序键、每改一张就是一条要同步的修改记录：只移动必须移动的卡
  /// （[srsMinimalMovePositions]），不像 Anki 那样每次连续重编 1..N。
  @override
  List<int> assignNewCardPositions(List<AnkiCardInfo> ordered) =>
      srsMinimalMovePositions(<int?>[
        for (final AnkiCardInfo c in ordered)
          c.hasStoredPosition ? c.due : null,
      ]);

  /// 写回新卡位置。此刻已不是新卡（学过了 / 删了）或找不到的卡记进 failures、不写。
  @override
  Future<AnkiCardDueWriteResult> setNewCardPositions(
    List<AnkiCardDueUpdate> updates,
  ) async {
    if (updates.isEmpty) {
      return const AnkiCardDueWriteResult(
        written: 0,
        failures: <int, String>{},
      );
    }
    final SrsMiner miner = await _requireMiner();
    final Map<String, int> positions = <String, int>{};
    final Map<String, int> handleOf = <String, int>{};
    final Map<int, String> failures = <int, String>{};
    final List<String?> ids = await miner.store.cardIdsForAnkiNumericIds(<int>[
      for (final AnkiCardDueUpdate u in updates) u.cardId,
    ]);
    for (int i = 0; i < updates.length; i++) {
      final AnkiCardDueUpdate u = updates[i];
      final String? id = ids[i];
      if (id == null) {
        failures[u.cardId] = 'card not found in Fushi review';
        continue;
      }
      positions[id] = u.due;
      handleOf[id] = u.cardId;
    }
    final Set<String> accepted = await miner.store.setNewCardPositions(
      positions,
    );
    for (final String id in positions.keys) {
      if (!accepted.contains(id)) {
        failures[handleOf[id]!] = 'card is no longer new';
      }
    }
    return AnkiCardDueWriteResult(written: accepted.length, failures: failures);
  }
}

/// 重排取 rank 用的字段：按这条笔记的类型**实际制卡用的映射**（[mapping]，fieldId →
/// 制卡占位符）找出表达式 / 读音 / 词频序三种角色落在哪个字段，以 Lapis 字段名
/// （`Expression` / `ExpressionReading` / `FreqSort`）交出去。`resolveNoteFieldRoles`
/// 的 Lapis 兜底按这些名字认，于是内置类型改过字段名、自建类型字段叫「正面 / 单词」
/// 都能认出词形，而不是落到「第一个字段」或整批判无词频。表达式没有映射时退到
/// 类型的词形字段，再退到第一个字段。
Map<String, String> srsRepositionRoleFields(
  SrsNoteView note,
  SrsNoteTypeView noteType,
  Map<String, String> mapping,
) {
  String? byToken(String token) {
    for (final SrsFieldDef f in noteType.fields) {
      if ((mapping[f.id] ?? '').contains(token)) return f.id;
    }
    return null;
  }

  final String? expression =
      byToken('{expression}') ??
      noteType.termFieldId ??
      noteType.fields.firstOrNull?.id;
  final String? reading = byToken('{reading}');
  final String? rank = byToken('{frequency-harmonic-rank}');
  return <String, String>{
    'Expression': expression == null ? '' : note.field(expression),
    if (reading != null) 'ExpressionReading': note.field(reading),
    if (rank != null) 'FreqSort': note.field(rank),
  };
}
