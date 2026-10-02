import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/anki/forwarded_mine_codec.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi/src/sync/sync_backend.dart';

/// BUG-1185：把「已配对主机拒绝了互联 token」上报给用户可见的通道（toast）。
/// 注入而非直接调 UI，是为了让 repository 保持无 Flutter 依赖、可纯 Dart 单测。
typedef RemoteMiningAuthReporter = void Function(String message);

/// 「制卡到服务端」的 Anki 仓库包装：把 [mineEntry]/[isDuplicate] 经互联链路转发给已配对
/// 主机（主机用它自己的 Anki 后端 + 字段映射/牌组落卡），其余**配置类**方法
/// （[fetchConfiguration]/[createDeck]/[createNoteType]）委派给包装的本地仓库 [_local]，
/// 以便设置页在开关开启时仍能正常配置本地 Anki（供开关关闭时使用）。
///
/// **Lapis 模板读写例外**（[readNoteTypeDefinition]/[updateNoteTypeStyling]/
/// [updateNoteTypeTemplates]）：跟随制卡落点经互联作用于**主机端**卡型——卡落在
/// 主机上，样式客制化就必须改主机的模板；这同时让手机端（AnkiDroid 无模板 API）
/// 第一次拥有可视化配置 Lapis 的通道。
///
/// 覆盖/查看类方法（[updateMinedNote]/[findOverwriteTargetNoteId]/[findMatchingNotes]/
/// [noteFields]/[openNoteInAnki]）保留基类降级默认（不委派本地——那会在远端制卡时错误地
/// 操作**本机** Anki 的卡片；远端 note id 本就为 null，本会话覆写第三态不激活，与 AnkiDroid
/// 现状一致）。
/// 来源回跳使用 [readSourceNote]/[prepareSourceNoteFields]/[patchSourceNote] 的
/// 独立链路：按来源 ID 唯一读取后绑定主机，失败不得回退到本机或另一台主机。
///
/// 媒体的四个来源在客户端就地读成字节再随请求发出（服务端未必装同款词典/无法访问本机文件）：
/// 封面 ← `context.coverPath`；句子音频 ← `context.sasayakiAudioPath`；单词音频 ←
/// `fields['audio']`（仅本地文件搬字节，`http` URL 留给服务端下载）；词典外字 ←
/// `FushiDicts.getMediaFile`。
class RemoteMiningAnkiRepository extends BaseAnkiRepository {
  RemoteMiningAnkiRepository({
    required BaseAnkiRepository local,
    required RemoteMineSender client,
    DictMediaByteLoader? dictMediaLoader,
    LocalFileByteLoader? fileByteLoader,
    RemoteMiningAuthReporter? onAuthRejected,
  })  : _local = local,
        _client = client,
        _payloadBuilder = ForwardedMinePayloadBuilder(
          dictMediaLoader: dictMediaLoader,
          fileByteLoader: fileByteLoader,
        ),
        _onAuthRejected = onAuthRejected;

  /// 主机拒绝互联 token 时给用户看的话。制卡失败与查重失败共用同一句，
  /// 因为它们是同一个 token 被同一台主机拒绝。
  static const String tokenRejectedMessage =
      'The Fushi Interconnect server rejected the interconnect token. Re-pair the device.';

  /// 没有互联主机可接收制卡请求时，同时说明失败结果和两条恢复路径。
  /// 避免把内部术语 "server-side mining" 暴露给只想完成制卡的用户。
  static const String pairedDeviceUnreachableMessage =
      "Couldn't create the card because the Fushi Interconnect server could not be reached. "
      'Make sure Fushi is running there, or turn off '
      'Mine to Fushi Interconnect server in Anki settings to create cards locally.';

  final BaseAnkiRepository _local;
  final RemoteMineSender _client;
  final ForwardedMinePayloadBuilder _payloadBuilder;
  final RemoteMiningAuthReporter? _onAuthRejected;

  /// 同一个 repository 实例只报一次「token 被拒」——查重是每次查词都跑的高频路径，
  /// 逐次弹 toast 会刷屏。provider 在开关/配对变化时会重建实例，届时自然重新提示。
  bool _authRejectedReported = false;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final ForwardedMinePayload payload = await _payloadBuilder.build(
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
    try {
      final Map<String, dynamic>? json = await _client.mineForward(payload);
      return _withLocalDeckNameFallback(_outcomeFromResponse(json));
    } on SyncAuthError {
      return MineOutcome.failure(
        tokenRejectedMessage,
        errorCode: AnkiErrorCode.connectionUnknown,
      );
    } catch (e, st) {
      return MineOutcome.failure(
        'Failed to forward the card to the Fushi Interconnect server: $e',
        errorCode: AnkiErrorCode.connectionUnknown,
        error: e,
        stackTrace: st,
      );
    }
  }

  /// BUG-1185：远端查重。可重试失败仍 fail-soft（client 层已降级为
  /// [RemoteDuplicateCheck.notDuplicate]），绝不让远端抖动阻断查词。
  ///
  /// token 被主机拒绝时查重**根本没执行**：这不是「不重复」，是「不知道」。基类
  /// [BaseAnkiRepository.isDuplicate] 的 `Future<bool>` 契约（一路铺到 popup.js 的
  /// ✓/➕ 两态按钮）表达不了第三态，所以在这一层把它**报给用户**——用户至少知道
  /// 「配对已失效、查重结果不可信」，而不是静默收到一个错误答案。返回值仍取 false
  /// （保持 ➕ 可点）：用户真按下去时 [mineEntry] 会用同一句话明确失败，不会悄悄多出
  /// 一张重复卡；若反过来谎报 true，用户只会以为卡已做好并就此走开。
  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final RemoteDuplicateCheck check =
        await _client.isDuplicate(expression: expression, reading: reading);
    if (check == RemoteDuplicateCheck.authRejected) {
      _reportAuthRejectedOnce();
      return false;
    }
    return check == RemoteDuplicateCheck.duplicate;
  }

  void _reportAuthRejectedOnce() {
    if (_authRejectedReported) return;
    _authRejectedReported = true;
    _onAuthRejected?.call(tokenRejectedMessage);
  }

  MineOutcome _outcomeFromResponse(Map<String, dynamic>? json) {
    if (json == null) {
      return MineOutcome.failure(
        pairedDeviceUnreachableMessage,
        errorCode: AnkiErrorCode.pairedDeviceUnreachable,
      );
    }
    final String result = json['result']?.toString() ?? MineResult.error.name;
    final String? message = json['message'] as String?;
    final String? detail = json['detail'] as String?;
    if (result == MineResult.success.name) {
      // BUG-1549：主机回传它实际落卡的牌组名（主机侧配置的 deck）；旧版本主机
      // 无此字段 → null，由 [_withLocalDeckNameFallback] 降级到本地设置名。
      return MineOutcome.success(
        deckName: json['deckName'] as String?,
        audioWarning: message,
      );
    }
    if (result == MineResult.duplicate.name) {
      return const MineOutcome.duplicate();
    }
    if (result == MineResult.notConfigured.name) {
      return const MineOutcome.notConfigured();
    }
    return MineOutcome.failure(
      message ??
          detail ??
          'The Fushi Interconnect server failed to create the card.',
    );
  }

  /// BUG-1549：旧版本主机的转发响应不带 `deckName`——降级用**本地**设置解析的
  /// 牌组名补上（与旧行为一致：此前成功 toast 本来就显示本地
  /// `loadSettings().selectedDeckName`）。新主机回传后此降级不再触发。
  Future<MineOutcome> _withLocalDeckNameFallback(MineOutcome outcome) async {
    if (outcome.result != MineResult.success) return outcome;
    if (outcome.deckName != null && outcome.deckName!.isNotEmpty) {
      return outcome;
    }
    // 补名只是给 toast 用的装饰——本地设置读不到（存储异常等）时绝不能把一次
    // 已成功的远端制卡变成失败，原样返回（toast 无牌组名，与旧降级一致）。
    try {
      final AnkiSettings settings = await _local.loadSettings();
      final String? localDeckName =
          resolveSelectedDeck(settings)?.name ?? settings.selectedDeckName;
      return MineOutcome.success(
        noteId: outcome.noteId,
        deckName: localDeckName,
        audioWarning: outcome.audioWarning,
      );
    } catch (_) {
      return outcome;
    }
  }

  RemoteSourceNoteSender get _sourceClient {
    final RemoteMineSender client = _client;
    if (client is! RemoteSourceNoteSender) {
      throw UnsupportedError(
        'The Fushi Interconnect server does not support source editing.',
      );
    }
    return client as RemoteSourceNoteSender;
  }

  /// Safe display identity for the peer bound when the original note was read.
  String? sourcePeerUrl(String sourceId) {
    final RemoteMineSender client = _client;
    return client is RemoteSourceNoteSender
        ? (client as RemoteSourceNoteSender).sourcePeerUrl(sourceId)
        : null;
  }

  String? sourcePeerIdentity(String sourceId) =>
      _sourceClient.sourcePeerIdentity(sourceId);

  @override
  Future<AnkiSourceNote?> readSourceNote(String sourceId) =>
      _sourceClient.readSourceNote(sourceId);

  Future<void> bindSourcePeer(
    String sourceId,
    String peerUrl, {
    required String pairingIdentity,
  }) =>
      _sourceClient.bindSourcePeer(
        sourceId,
        peerUrl,
        pairingIdentity: pairingIdentity,
      );

  @override
  Future<Map<String, String>> prepareSourceNoteFields({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      _sourceClient.prepareForwardedSourceNote(
        await _payloadBuilder.build(
          rawPayloadJson: rawPayloadJson,
          context: context,
        ),
      );

  @override
  Future<void> patchSourceNote({
    required AnkiSourceNote original,
    required Map<String, String> fields,
  }) =>
      _sourceClient.patchSourceNote(original: original, fields: fields);

  // ---- 配置类：委派本地仓库，保持设置页可配置本地 Anki ----

  /// 被包装的本地仓库。iOS 的 AnkiMobile 回传（`fushi://ankiFetch` / 回到前台）
  /// 要找的是它，而不是这层壳——BUG-2493 之前 `main.dart` 用 `is! AnkiMobileRepository`
  /// 判型，开了「制卡到已配对设备」后整条回传链被静默丢弃。
  BaseAnkiRepository get local => _local;

  @override
  Future<AnkiFetchResult> fetchConfiguration() => _local.fetchConfiguration();

  @override
  Future<bool> createDeck(String name) => _local.createDeck(name);

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      _local.createNoteType(template);

  // ---- Lapis 模板读写：跟随制卡落点，经互联作用于**主机端**卡型 ----
  //
  // 开关开启时卡片落在已配对主机的 Anki 上，样式客制化/备份/恢复必须作用于
  // 同一个 Anki——委派本地会在手机上把整个 Lapis 区隐藏（AnkiDroid 无模板
  // API，这正是「可视化配置 Lapis 不支持手机端」的根因），在桌面上则改到
  // 一个根本不落卡的本机 Anki。这也是手机端唯一的模板编辑通道（平台边界：
  // AnkiDroid / AnkiMobile 均无改已存在模板的 API）。
  //
  // 主机版本过旧（无 `/api/anki/note-type/*` 端点）时：读返回 null（UI 按
  // 「未找到 Lapis」提示），写返回 false（服务层转「后端不支持」失败）；
  // 主机不可达/token 被拒由 client 抛出，原样透传给 UI 显示。

  @override
  bool get supportsNoteTypeEditing => true;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(String modelName) =>
      _client.readNoteTypeDefinition(modelName);

  /// 卡在主机上按**主机的**设置建，本机设置配不上主机的模板；主机也没有回答这个
  /// 问题的端点 → 无法判定，保持偏好（BUG-2869）。
  @override
  Future<bool?> rendersSynchronizedClip() async => null;

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) =>
      _client.updateNoteTypeStyling(modelName, css);

  @override
  Future<bool> updateNoteTypeTemplates(
          String modelName, List<AnkiCardTemplate> templates) =>
      _client.updateNoteTypeTemplates(modelName, templates);

  // ── 媒体存储优化：作用于**主机端** collection.media ────────────────────
  //
  // 这里曾委派本地仓库（`_local.supportsMediaMaintenance`），那是把「配置类
  // 方法一律委派本地」的规则套错了地方：卡片落在主机的 Anki 上，重复媒体也
  // 堆在主机的 collection.media 里，客户端本机连那个目录都没有。委派本地的
  // 后果是——Android 上本地是 AnkiDroid（恒 false），于是明明主机能去重，
  // 手机上整区隐藏；而 note type 编辑（就在上面几行）却已经走远端。同一个
  // 「制卡到已配对设备」模式下两个维护动作指向两台不同机器，是自相矛盾的。
  //
  // 与 note type 编辑同构：能力与执行都在主机侧。

  @override
  bool get supportsMediaMaintenance => true;

  /// 整轮去重在主机进程里跑，进度与取消跨不过这一次 HTTP 往返。
  @override
  bool get supportsMediaMaintenanceProgress => false;

  @override
  Future<bool> probeMediaMaintenance() => _client.probeMediaMaintenance();

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({
    bool dryRun = false,
    Future<void> Function(Map<String, dynamic> entry)? onJournal,
    AnkiMediaDedupOnProgress? onProgress,
    bool Function()? shouldCancel,
  }) {
    // onJournal 有意不接：改写/删除都发生在主机，审计日志也该落在主机（主机
    // 侧经自己的 AnkiMediaDedupRunner 落 journal）。把主机的删除记进客户端的
    // 日志目录只会造出一份「本机什么都没删」的假账。
    // onProgress / shouldCancel 同理跨不过来，见 supportsMediaMaintenanceProgress。
    return _client.runMediaDedup(dryRun: dryRun);
  }
}
