/// 歌词模式滑动窗口的纯计算（无 Flutter / WebView 依赖，便于单测）。
///
/// 歌词文档只装整书 cue 的一段（窗口）。窗口首 / 末句接近视口、或播放句接近窗口
/// 边缘时，往那一侧原地补装一段，同时从另一端卸掉离**锚点**足够远的句子，保证
/// 窗口常驻不超过 [kLyricsModeMaxInitialCues] 句（BUG-4004 复审）。
///
/// 锚点：跟随播放时是当前播放句；手动浏览（JS 浏览态，或「跟随音频」关）时是
/// 用户视口中线那句——否则暂停后一路往后滑，播放句钉在原地，卸载量恒为 0，
/// 窗口无上限地涨到整书。
library;

/// 窗口常驻上限（也是首次装载窗口的大小）。
const int kLyricsModeMaxInitialCues = 600;

/// 滑动窗口一次原地补装的 cue 数。
const int kLyricsWindowChunk = 200;

/// 播放推进时，当前句离窗口边缘不足这么多句就先补装（不等视口碰到边）。
const int kLyricsWindowEdgeMargin = 120;

/// 卸载远端时，锚点句身后 / 身前至少保留的句数（覆盖视口内所有行）。
const int kLyricsWindowKeep = 150;

/// 一次滑动的结果：新窗口为整书 `[keptStart, keptEnd)`；JS 侧先从头 / 尾卸掉
/// [trimHead] / [trimTail] 句，再在头部插 `[loadStart, oldStart)`、尾部插
/// `[oldEnd, loadEnd)`。
typedef LyricsWindowSlide = ({
  int loadStart,
  int loadEnd,
  int trimHead,
  int trimTail,
});

/// 计算往 [forward] 方向滑一次窗口。当前窗口是整书 `[start, end)`，整书共
/// [total] 句；[anchor] 是整书下标（< 0 = 无锚点，可随意卸载）。
///
/// 不变式：
/// * 结果窗口长度 ≤ max([cap], 原窗口长度)——补装量受「另一端最多能卸多少」
///   约束，卸不动就少补（锚点离请求的一端太远时一句不补，返回 null）；
/// * 锚点前后各 [keep] 句（落在原窗口内的部分）永不被卸掉，视口内的行不会
///   从 DOM 里消失，JS 按锚点句补偿滚动后屏上不位移。
///
/// 已到整书首 / 尾、或这次一句都补不进来时返回 null。
LyricsWindowSlide? planLyricsWindowSlide({
  required int total,
  required int start,
  required int end,
  required bool forward,
  required int anchor,
  int chunk = kLyricsWindowChunk,
  int cap = kLyricsModeMaxInitialCues,
  int keep = kLyricsWindowKeep,
}) {
  if (start < 0 || end > total || start >= end) return null;
  final int len = end - start;
  // 原窗口已超上限（理论上不出现）时，以原长度为上限：只许持平，不许再涨。
  final int limit = len > cap ? len : cap;
  if (forward) {
    if (end >= total) return null;
    // 头部最多能卸多少：锚点身后留 keep 句。
    final int maxTrim = anchor < 0
        ? len
        : (anchor - keep - start).clamp(0, len);
    int loadEnd = end + chunk;
    if (loadEnd > total) loadEnd = total;
    if (loadEnd > start + maxTrim + limit) loadEnd = start + maxTrim + limit;
    if (loadEnd <= end) return null;
    final int over = (loadEnd - start) - limit;
    return (
      loadStart: start,
      loadEnd: loadEnd,
      trimHead: over > 0 ? over : 0,
      trimTail: 0,
    );
  }
  if (start <= 0) return null;
  // 尾部最多能卸多少：锚点身前留 keep 句。
  final int maxTrim = anchor < 0
      ? len
      : (end - (anchor + keep + 1)).clamp(0, len);
  int loadStart = start - chunk;
  if (loadStart < 0) loadStart = 0;
  if (loadStart < end - maxTrim - limit) loadStart = end - maxTrim - limit;
  if (loadStart >= start) return null;
  final int over = (end - loadStart) - limit;
  return (
    loadStart: loadStart,
    loadEnd: end,
    trimHead: 0,
    trimTail: over > 0 ? over : 0,
  );
}

/// 已装进歌词文档的窗口 [window]（整书下标从 [offset] 起）是不是**当前**整书 cue
/// [source] 的同一段：首 / 末元素按对象身份比对。
///
/// 只能比元素身份、不能比列表身份：reader 每装一章都把同一份缓存的整书 cue 重灌给
/// 控制器，`setAllBookCues` 每次 `List.from` 拷一份新列表，元素对象不变。元素换了
/// （重新对齐 / SRT 重建）= 窗口里的下标已经对不上，只能整页重载；没换 = 窗口照常
/// 可用，跨章不该重载（反馈 NSP86pcPHI / BUG-4202）。
bool lyricsWindowIsSliceOf<T extends Object>({
  required List<T> window,
  required int offset,
  required List<T> source,
}) {
  if (window.isEmpty || offset < 0) return false;
  final int end = offset + window.length;
  if (end > source.length) return false;
  return identical(source[offset], window.first) &&
      identical(source[end - 1], window.last);
}
