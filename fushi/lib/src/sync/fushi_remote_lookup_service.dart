import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';

abstract class FushiRemoteLookupService {
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  });

  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  });
}

/// 浏览器扩展只渲染弹框时的可选快路径。
///
/// [FushiRemoteLookupService.searchDictionary] 必须构造可写历史、可同步的完整
/// [DictionarySearchResult]；扩展的 `popupOnly` 请求只需要已经面向 popup.js 的 JSON
/// 与命中长度。实现此能力的 service 可以跳过完整 DictionaryEntry/extra 的物化。
/// handler 只在 `popupOnly && !record` 时探测本接口，旧实现与完整响应契约不受影响。
abstract class FushiRemotePopupLookupService {
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopup({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  });
}

/// [FushiRemotePopupLookupService] 的可选诊断能力。
///
/// 保持原 popup 快路径接口不变，只有需要服务端阶段计时的调用方才探测本接口并传入
/// 一次请求独享的 [RemoteDictionaryPopupTiming]。这样旧实现、完整查词和同步 host 都
/// 不需要知道性能诊断，也不会被迫承担 Stopwatch 开销。
abstract class FushiRemoteTimedPopupLookupService
    implements FushiRemotePopupLookupService {
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopupWithTiming({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required RemoteDictionaryPopupTiming timing,
  });
}

/// popup 快路径内部阶段计时（微秒）。
///
/// 这是每请求可变 collector，不进入查询缓存，也不随 popup JSON 序列化；HTTP 层把它
/// 转成 `Server-Timing`。即使查询返回 null，collector 仍能保留慢 miss 的 FFI 时间。
class RemoteDictionaryPopupTiming {
  bool measured = false;
  String cache = 'miss';
  int normalizeMicros = 0;
  int popupCacheMicros = 0;
  int fullCacheMicros = 0;
  int ffiCacheMicros = 0;
  int ffiLookupMicros = 0;
  int popupJsonMicros = 0;
  int serviceTotalMicros = 0;

  void reset() {
    measured = true;
    cache = 'miss';
    normalizeMicros = 0;
    popupCacheMicros = 0;
    fullCacheMicros = 0;
    ffiCacheMicros = 0;
    ffiLookupMicros = 0;
    popupJsonMicros = 0;
    serviceTotalMicros = 0;
  }
}

class RemoteDictionaryPopupLookup {
  const RemoteDictionaryPopupLookup({
    required this.popupJson,
    required this.bestLength,
  });

  final String popupJson;
  final int bestLength;
}

/// 浏览器扩展挖词的窄接口（与查词分离，避免 server 直接依赖 AnkiRepository）。
abstract class FushiRemoteMiningService {
  /// 返回 [RemoteMineResult]（结果名 + 失败/部分成功诊断）。
  Future<RemoteMineResult> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  });

  /// TODO-1000：沉浸制卡（截图/GIF/音频 + 不回放）。实现方持 AnkiRepository，可调后台软解
  /// 实例（2B）；server 只解析 body 成 [ImmersionMinePayload] 后转发，不 new 引擎、不碰 repo。
  /// TODO-1303：返回 [RemoteMineResult]——除结果名外还带 [RemoteMineResult.message]/
  /// [RemoteMineResult.detail]（失败原因 / 音频落空警告），实现方须同时把失败写进错误日志，
  /// 终结「制卡失败报成功 + 诊断黑洞」。
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload);

  /// 互联「制卡到服务端」：客户端把**未渲染**的制卡请求（rawPayloadJson + context 文本 +
  /// 全部本地媒体字节）转发过来，本机用**自己的** Anki 后端 + 字段映射/牌组渲染并落卡
  /// （服务端拥有制卡配置）。实现方须把 [ForwardedMinePayload] 的媒体字节落成本机临时文件/
  /// 词典缓存、重建 `AnkiMiningContext` 后调 `repo.mineEntry`，与 app 内本地制卡同一渲染链路。
  /// 与 [mineEntry]（浏览器扩展纯文本，已渲染 fields）是独立路径，互不影响契约。
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload);

  /// TODO-1176：浏览器扩展查词弹窗制卡按钮真查重（`+`→`✓`，与 app 内一致）。经 Anki 后端
  /// （AnkiConnect `findNotes` / AnkiDroid `findDuplicateNotes`）判断 [expression]/[reading]
  /// 是否已在当前牌组+笔记类型存在。与 app 内 `dictionary_page_mixin.checkDuplicate` 同一
  /// `repo.isDuplicate` 路径，fail-soft（后端不可用/未配置 → false，绝不让查重探测阻断查词）。
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  });

  // ── 互联 Lapis 客制化：主机端 note type 模板读写 ──────────────────────
  //
  // 开启「制卡到已配对设备」时卡片落在**主机**的 Anki 上，改客户端本机卡型
  // 毫无意义——Lapis 样式客制化因此必须经互联作用于主机端卡型。三个方法与
  // `BaseAnkiRepository` 同名同契约，实现方直接委派主机本地 Anki 仓库。
  // （客户端本机能不能改模板是另一回事：AnkiDroid 经 Content Provider 可以，
  // iOS 的 AnkiMobile 只有加卡的 URL scheme，不行。）

  /// 读主机端 [modelName] 的完整定义（字段/卡模板/CSS）。主机后端不支持模板
  /// 读写或模型不存在返回 `null`；主机 Anki 不可达照抛（调用方转成失败响应）。
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(String modelName);

  /// 覆写主机端 [modelName] 的 styling。返回 `false` = 主机后端不支持。
  Future<bool> updateNoteTypeStyling(String modelName, String css);

  /// 覆写主机端 [modelName] 的全部卡模板。返回 `false` = 主机后端不支持。
  Future<bool> updateNoteTypeTemplates(
    String modelName,
    List<AnkiCardTemplate> templates,
  );

  // ── 互联媒体存储优化：主机端 collection.media 字节级去重 ────────────────
  //
  // 卡片落在主机的 Anki 上，媒体副本也堆在**主机**的 collection.media 里；
  // 客户端（手机）本机根本没有那个目录。去重因此与上面的模板读写同类：能力与
  // 执行都在主机侧，客户端只发起、只看结果。

  /// 主机端此刻能不能做媒体去重（= 主机本地 Anki 仓库的
  /// `probeMediaMaintenance`）。主机 Anki 不可达照抛。
  Future<bool> probeMediaMaintenance();

  /// 在主机端跑一轮媒体去重。返回 `null` = 主机后端不支持。
  ///
  /// **不带进度与取消**：这条链路是一次 HTTP 往返，进度回调与取消判据都在
  /// 主机进程内，跨不过来。客户端据此隐藏取消按钮（见
  /// `AnkiMediaDedupRunner.supportsCancel`），绝不摆一个点了没用的按钮。
  Future<AnkiMediaDedupReport?> runMediaDedup({bool dryRun});
}

/// 把一次查词结果写入 Hibiki 查词历史（无 UI 副作用）。浏览器扩展 record 用。
abstract class FushiRemoteHistoryService {
  void recordHistory(DictionarySearchResult result);
}

/// 对端 host 返回的单词音频查询结果（原始字节 + Content-Type，wire DTO）。
class RemoteAudioLookup {
  const RemoteAudioLookup({
    required this.bytes,
    required this.contentType,
  });

  final Uint8List bytes;
  final String contentType;
}

/// TODO-1303：远端制卡结果 + 诊断。此前挖词接口只回 `MineResult.name`，把
/// [MineOutcome.errorDetail]/[MineOutcome.audioWarning] 和引擎中止原因全丢了 → 扩展
/// 只能盲判「非 success 就重试」，用户看到「制卡失败报成功」而无从排查。
///
/// * [result]：`MineResult.name`（`'success'|'duplicate'|'notConfigured'|'error'`）。
/// * [message]：人类可读的简短原因。`error` 时是失败文案；`success` 且单词音频落空
///   （部分成功）时是音频警告——让扩展区分「真成功」与「卡建了但没音频」。
/// * [detail]：更长的技术细节（如引擎中止原因 / errorDetail 原文），可空。
///
/// 由 [buildRemoteMineResponse] 摊进 `/api/mine` 响应体（`{result, message?, detail?}`），
/// 浏览器扩展 content.js 读 `resp.data.message` 弹 toast 显因。
class RemoteMineResult {
  const RemoteMineResult({
    required this.result,
    this.message,
    this.detail,
    this.deckName,
  });

  final String result;
  final String? message;
  final String? detail;

  /// BUG-1549：`success` 时主机**实际落卡**的牌组名（主机侧配置的 deck），随
  /// `/api/mine/forward` 响应回传给客户端的成功 toast；失败为 `null`。旧客户端
  /// 忽略此字段即旧行为（向后兼容）。
  final String? deckName;
}
