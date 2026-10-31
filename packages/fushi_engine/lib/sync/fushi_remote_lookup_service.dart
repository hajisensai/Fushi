import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';

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

/// 「选择音频源」菜单（弹窗 ♪ 长按 / 右键）的可选能力：列出每个启用源各自解析
/// 出的全部候选。探测式接口（与 [FushiRemotePopupLookupService] 同法）——没实现它
/// 的 service 由 `/api/lookup/audio/list` 回落成「只有默认源」的单项列表，旧实现
/// 与测试替身不必改动。
abstract class FushiRemoteAudioListService {
  Future<List<RemoteAudioChoice>> listAudio({
    required String expression,
    required String reading,
  });
}

/// [FushiRemoteAudioListService.listAudio] 的一项：源显示名、源内变体名（可空）、
/// 已取回的音频字节。
class RemoteAudioChoice {
  const RemoteAudioChoice({
    required this.name,
    required this.variant,
    required this.audio,
  });

  final String name;
  final String variant;
  final RemoteAudioLookup audio;
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

/// 查词请求带了**请求方的查词语言**（wire 字段 [kRemoteLookupLanguageField]）时的可选
/// 能力：实现方按请求方语言决定查词行为（中文 → 引擎额外试简体 → 繁體变体），而不是按
/// 本机当前查词语言——两台设备可能正在读不同语言的内容。
///
/// 探测式接口（与 [FushiRemotePopupLookupService] 同法）：请求不带语言、或 service 没实现
/// 它（旧实现 / 测试替身）时一律走 [FushiRemoteLookupService.searchDictionary] 等旧方法，
/// 行为与从前逐字相同。分派只在 [searchRemoteDictionaryForRequest] /
/// [searchRemoteDictionaryPopupForRequest] 一处。
abstract class FushiRemoteLanguageLookupService {
  /// [language] 为请求方声明的 BCP-47 语言标签（已裁掉空白、非空）。
  Future<DictionarySearchResult?> searchDictionaryInLanguage({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required String language,
  });

  /// [FushiRemotePopupLookupService.searchDictionaryPopup] 的带语言版本；[timing] 非 null
  /// 时与 [FushiRemoteTimedPopupLookupService] 同语义地记录阶段耗时。
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopupInLanguage({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required String language,
    RemoteDictionaryPopupTiming? timing,
  });
}

/// 查词请求带了**原文自带振假名**（wire 字段 [kRemoteLookupRubyField]，`[{s, e, r}]`，
/// 以请求的 `term` 为 UTF-16 坐标系）时的可选能力：实现方把区间交给引擎
/// （`LookupOptions::ruby_readings`），同匹配长度的候选里读音与原文 ruby 吻合的排前面。
/// 只用来源自带的读音，不推断读音。
///
/// 探测式接口（与 [FushiRemoteLanguageLookupService] 同法）：请求不带 ruby、或 service
/// 没实现它（旧实现 / 测试替身）时一律走旧方法，结果照原序。[language] 为 null = 请求
/// 没声明查词语言（旧行为）。分派只在 [searchRemoteDictionaryForRequest] /
/// [searchRemoteDictionaryPopupForRequest] 一处。
abstract class FushiRemoteRubyLookupService {
  /// [rubySpans] 非空，以 [term]（清洗前）为坐标系；实现方负责与清洗后的查询串对齐。
  Future<DictionarySearchResult?> searchDictionaryWithRuby({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required List<FushiRubySpan> rubySpans,
    String? language,
  });

  /// [searchDictionaryWithRuby] 的 popup 快路径版本；[timing] 同
  /// [FushiRemoteTimedPopupLookupService]。
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopupWithRuby({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required List<FushiRubySpan> rubySpans,
    String? language,
    RemoteDictionaryPopupTiming? timing,
  });
}

/// 查词请求体里「原文振假名区间」的字段名（可选；缺省 / 空数组 = 旧行为）。
const String kRemoteLookupRubyField = 'ruby';

/// 从请求体取原文振假名区间（畸形项丢弃，见 [FushiRubySpan.listFromWire]）。
List<FushiRubySpan> remoteLookupRubySpansOf(Map<String, dynamic> body) =>
    FushiRubySpan.listFromWire(body[kRemoteLookupRubyField]);

/// 查词请求体里「请求方查词语言」的字段名（可选；缺省 = 旧行为，按 host 本机语言）。
const String kRemoteLookupLanguageField = 'language';

/// 从请求体（JSON body / ctl 查询参数）取请求方查词语言：非字符串、空串、纯空白都当没给。
String? remoteLookupLanguageOf(Map<String, dynamic> body) {
  final Object? raw = body[kRemoteLookupLanguageField];
  if (raw is! String) return null;
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 完整查词结果的唯一分派点：请求带了语言且 [lookup] 认识语言时走
/// [FushiRemoteLanguageLookupService.searchDictionaryInLanguage]，否则走旧方法。
Future<DictionarySearchResult?> searchRemoteDictionaryForRequest(
  FushiRemoteLookupService lookup, {
  required String term,
  required bool wildcards,
  required int maximumTerms,
  required String? language,
  List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
}) {
  final Object service = lookup;
  if (rubySpans.isNotEmpty && service is FushiRemoteRubyLookupService) {
    return service.searchDictionaryWithRuby(
      term: term,
      wildcards: wildcards,
      maximumTerms: maximumTerms,
      rubySpans: rubySpans,
      language: language,
    );
  }
  if (language != null && service is FushiRemoteLanguageLookupService) {
    return service.searchDictionaryInLanguage(
      term: term,
      wildcards: wildcards,
      maximumTerms: maximumTerms,
      language: language,
    );
  }
  return lookup.searchDictionary(
    term: term,
    wildcards: wildcards,
    maximumTerms: maximumTerms,
  );
}

/// 本次请求能否走 popup 快路径（[searchRemoteDictionaryPopupForRequest]）；false 时调用方
/// 回落完整查词。单列成判断而不是让快路径返回 null，免得「没有快路径」与「快路径查无
/// 结果」混成同一个 null。
bool hasPopupFastPath(
  FushiRemoteLookupService lookup, {
  String? language,
  List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
}) {
  final Object service = lookup;
  return (rubySpans.isNotEmpty && service is FushiRemoteRubyLookupService) ||
      (language != null && service is FushiRemoteLanguageLookupService) ||
      service is FushiRemotePopupLookupService;
}

/// 见 [hasPopupFastPath]：调用前必须先确认它为 true。
Future<RemoteDictionaryPopupLookup?> searchRemoteDictionaryPopupForRequest(
  FushiRemoteLookupService lookup, {
  required String term,
  required bool wildcards,
  required int maximumTerms,
  required String? language,
  RemoteDictionaryPopupTiming? timing,
  List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
}) {
  final Object service = lookup;
  if (rubySpans.isNotEmpty && service is FushiRemoteRubyLookupService) {
    return service.searchDictionaryPopupWithRuby(
      term: term,
      wildcards: wildcards,
      maximumTerms: maximumTerms,
      rubySpans: rubySpans,
      language: language,
      timing: timing,
    );
  }
  if (language != null && service is FushiRemoteLanguageLookupService) {
    return service.searchDictionaryPopupInLanguage(
      term: term,
      wildcards: wildcards,
      maximumTerms: maximumTerms,
      language: language,
      timing: timing,
    );
  }
  if (service is! FushiRemotePopupLookupService) {
    throw StateError('lookup service has no popup fast path');
  }
  if (timing != null && service is FushiRemoteTimedPopupLookupService) {
    return service.searchDictionaryPopupWithTiming(
      term: term,
      wildcards: wildcards,
      maximumTerms: maximumTerms,
      timing: timing,
    );
  }
  return service.searchDictionaryPopup(
    term: term,
    wildcards: wildcards,
    maximumTerms: maximumTerms,
  );
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
abstract class FushiRemoteSourceNoteService {
  Future<AnkiSourceNote?> readSourceNote(String sourceId);

  Future<Map<String, String>> prepareForwardedSourceNote(
    ForwardedMinePayload payload,
  );

  Future<void> patchSourceNote({
    required AnkiSourceNote original,
    required Map<String, String> fields,
  });
}

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

  /// Issue #1409：浏览器扩展查词弹窗的 ↗「在 Anki 中打开这个词的卡」。与 app 内
  /// `openInAnki` 桥（`overlay_bridge_handlers._handleOpenInAnkiBridge`）同一
  /// `repo.openWordInAnki`——判据与画 ✓ 的查重一致（BUG-2051）。实现方不得抛：
  /// 后端不可达/未配置/异常一律回 [AnkiOpenWordOutcome.failed]。
  Future<AnkiOpenWordOutcome> openWordInAnki({
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

/// 把一次查词结果写入 Fushi 查词历史（无 UI 副作用）。浏览器扩展 record 用。
abstract class FushiRemoteHistoryService {
  void recordHistory(DictionarySearchResult result);
}

/// 对端 host 返回的单词音频查询结果（原始字节 + Content-Type，wire DTO）。
class RemoteAudioLookup {
  const RemoteAudioLookup({required this.bytes, required this.contentType});

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
