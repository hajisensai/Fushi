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
/// M0 明确只做「静态截图 + 文本」：无音频、无 GIF。若 [screenshotBytes] 为 null
/// （截图失败），返回的请求 `providedCoverBytes==null` 且无其它媒体源——引擎会以
/// 「no cover and no audio produced」中止（fail-open，不产出空壳卡）。调用方应在截图
/// 失败时优先给出明确错误提示，不把 null 字节喂进来假装成功。
///
/// galgame 一键制卡（docs/specs/galgame-mining）在 M0 基础上补 [audioBytes]：优先使用逐句
/// 游戏资源语音并转码，资源不可用时才由上层降级为引擎 PCM / Loopback 混音切片；传入的必须是
/// 已封装 AAC/m4a 容器字节（不能是裸 PCM——引擎对 `providedAudioBytes` 逐字节写盘不重编码，
/// 裸流 Anki 播不了）。
/// 只有 [audioBytes] 非空时才把 [ImmersionMiningRequest.requireAudio] 打开——「本应有音频
/// 却最终丢了」才算失败；纯截图卡（无 [audioBytes]）保持 M0 的 `requireAudio:false`，
/// 不因无声中止（Never break：截图卡本就无声）。
ImmersionMiningRequest buildExternalWindowRequest({
  required Map<String, String> fields,
  required String sentence,
  Uint8List? screenshotBytes,
  // galgame 一键制卡默认出 GIF 动图：调用点传 `'external_window.gif'` 让引擎按
  // 动图封面处理（引擎据 providedCoverName 后缀区分 GIF/静图）。缺省保持
  // `'external_window.png'`，不传的既有调用行为不变（Never break）。
  String? coverName,
  Uint8List? audioBytes,
  String? audioName,
  String? cueSentence,
  String? documentTitle,
  AnkiMiningSource source = AnkiMiningSource.video,
  String? bookTitleTag,
  int? updateNoteId,
}) {
  final bool hasAudio = audioBytes != null && audioBytes.isNotEmpty;
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
    providedCoverName:
        screenshotBytes == null ? null : (coverName ?? 'external_window.png'),
    providedAudioBytes: hasAudio ? audioBytes : null,
    providedAudioName: hasAudio
        ? (audioName ?? 'galgame_audio.${immersionMiningAudioExtension()}')
        : null,
    // 有音频 -> requireAudio 开（本应有音频却丢=失败）；纯截图卡 -> false（本就无声）。
    requireAudio: hasAudio,
  );
}
