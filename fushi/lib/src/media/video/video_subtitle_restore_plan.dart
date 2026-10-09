/// 单视频起播时「持久化内嵌字幕轨」的恢复计划（BUG-3103）。
///
/// 视频页 `_loadSingle` 在库里有 cue 缓存、且持久化源是内嵌轨（`embedded:<n>`）时，会
/// 重解析这条内嵌轨（拿回 ASS 样式，TODO-1246）。重解析的结果有三种：文本轨 cue、
/// **图形轨**（PGS / VobSub，没有 cue，只能交给 libmpv 画面渲染）、或解析不出来。
///
/// 旧实现只认第一种：图形轨返回的「空 cue + graphicStreamIndex」被当成「解析不出来」，
/// 于是继续用库里的旧 cue（之前选过的文本字幕 / OCR 转出的字幕留下的），
/// `renderGraphicStreamIndex` 也没传给播放器——用户选的图形字幕在重开视频后不再渲染，
/// 画面上换成了旧文本字幕，看起来就是「被自动取消选中」。播放列表里的一集选图形轨时
/// 只写源指针、不清库里的 cue，这份旧 cue 一直留着，所以合集里每次重开都会复现。
///
/// 纯函数，单测钉住三种结果的去向。
library;

import 'package:fushi_audio/fushi_audio.dart';

/// `_restorePersistedSubtitle` 的结果：实际持久化值 + cue + 图形轨序号（文本轨为 null）。
typedef RestoredSubtitleSource = ({
  String persisted,
  List<AudioCue> cues,
  int? graphicStreamIndex,
});

/// 交给 `_applyLoad` 的字幕部分：cue、外挂 / 内嵌源指针、要让 libmpv 渲染的图形轨序号。
typedef SubtitleLoadPlan = ({
  List<AudioCue> cues,
  String? externalSubtitle,
  int? graphicStreamIndex,
});

/// 把重解析持久化内嵌轨的结果 [restored] 并进起播计划。[cachedCues] 是库里的 cue
/// 缓存，[persisted] 是持久化源指针。
SubtitleLoadPlan mergeRestoredEmbeddedSubtitle({
  required List<AudioCue> cachedCues,
  required String? persisted,
  required RestoredSubtitleSource? restored,
}) {
  if (restored == null) {
    // 缓存被清 / 容器不可读：保留库里的 cue，仅缺样式不缺内容。
    return (
      cues: cachedCues,
      externalSubtitle: persisted,
      graphicStreamIndex: null,
    );
  }
  final int? graphic = restored.graphicStreamIndex;
  if (graphic != null) {
    // 图形轨：库里的 cue 一定是别的源留下的旧数据，不能盖在图形字幕上。
    return (
      cues: const <AudioCue>[],
      externalSubtitle: restored.persisted,
      graphicStreamIndex: graphic,
    );
  }
  if (restored.cues.isNotEmpty) {
    return (
      cues: restored.cues,
      externalSubtitle: restored.persisted,
      graphicStreamIndex: null,
    );
  }
  return (
    cues: cachedCues,
    externalSubtitle: persisted,
    graphicStreamIndex: null,
  );
}
