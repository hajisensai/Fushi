import 'dart:typed_data';

import 'package:hibiki_anki/hibiki_anki.dart' show AnkiMiningSource;

import 'package:hibiki/src/mining/immersion_mining_request.dart';

/// TODO-1162 外部窗口挖矿 M0：把外部窗口抓到的一帧静态截图字节 + 当前 texthooker 句子
/// 组成喂 [ImmersionMiningEngine] 的 [ImmersionMiningRequest]（纯函数，可单测）。
///
/// 与 Netflix 后台捕获（`buildImmersionRequest`）同形状：截图字节走
/// [ImmersionMiningRequest.providedCoverBytes]（引擎写临时文件 -> AnkiMiningContext.coverPath），
/// 无本地媒体源（`mediaSource=null`）、无时间区间（`clip*Ms=0`）。
///
/// M0 明确只做「静态截图 + 文本」：无音频、无 GIF，故 [ImmersionMiningRequest.requireAudio]
/// 恒 false（外部窗口截图卡本就无音轨，不因缺音频中止）。若 [screenshotBytes] 为 null
/// （截图失败），返回的请求 `providedCoverBytes==null` 且无其它媒体源——引擎会以
/// 「no cover and no audio produced」中止（fail-open，不产出空壳卡）。调用方应在截图
/// 失败时优先给出明确错误提示，不把 null 字节喂进来假装成功。
ImmersionMiningRequest buildExternalWindowRequest({
  required Map<String, String> fields,
  required String sentence,
  Uint8List? screenshotBytes,
  String? cueSentence,
  String? documentTitle,
  AnkiMiningSource source = AnkiMiningSource.video,
  String? bookTitleTag,
  int? updateNoteId,
}) {
  return ImmersionMiningRequest(
    fields: fields,
    mediaSource: null,
    clipStartMs: 0,
    clipEndMs: 0,
    sentence: sentence,
    cueSentence: cueSentence,
    documentTitle: documentTitle,
    source: source,
    bookTitleTag: bookTitleTag,
    updateNoteId: updateNoteId,
    providedCoverBytes: screenshotBytes,
    providedCoverName: screenshotBytes == null ? null : 'external_window.png',
    // M0 静态截图卡无音频 -> 不因缺音频中止（Never break: 截图卡本就无声）。
    requireAudio: false,
  );
}
