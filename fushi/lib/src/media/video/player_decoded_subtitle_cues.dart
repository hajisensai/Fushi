import 'package:fushi_audio/fushi_audio.dart';

/// 远端直出容器里服务器抽不出的内嵌**文本**字幕轨（BUG-2590 的兼容层场景）：
/// libmpv 正在 demux 这条流，本就会把这条轨解码成文本。与其让它把字画进画面
/// （不可点、无列表），不如只借它的解码结果——`sub-text` + `sub-start` /
/// `sub-end`——拼成 cue 喂回可点 overlay。零额外流量；代价是 cue 只能边播边
/// 累积（没播到的句子服务器不给、我们也不再读一遍流）。
///
/// 这里是把 mpv 每次上报的一句合进累积列表的纯函数，控制器只负责喂数据。

/// mpv 秒值属性（`sub-start` / `sub-end` 形如 `"12.345000"`）→ 毫秒；
/// 无当前字幕时 mpv 报错或空串 → null。
int? parseMpvSecondsToMs(String raw) {
  final double? seconds = double.tryParse(raw.trim());
  if (seconds == null || seconds.isNaN || seconds.isInfinite) return null;
  if (seconds < 0) return null;
  return (seconds * 1000).round();
}

/// mpv 拿不到 `sub-end` 时（个别 demuxer 报的包没有时长）给的暂定时长；下一次
/// 字幕变化会按真实位置收尾（[closePlayerDecodedCue]）。
const int kPlayerDecodedCueProvisionalMs = 5000;

/// 用 mpv 上报的一句构造 cue。[text] 为空（句间空档）返回 null。
/// [startMs] 缺失时退回 [positionMs]（事件到达时的播放位置）。
AudioCue? buildPlayerDecodedCue({
  required String text,
  required int? startMs,
  required int? endMs,
  required int positionMs,
}) {
  final String normalized = text.replaceAll('\r\n', '\n').trim();
  if (normalized.isEmpty) return null;
  final int start = startMs ?? positionMs;
  final int end = (endMs != null && endMs > start)
      ? endMs
      : start + kPlayerDecodedCueProvisionalMs;
  return AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = normalized
    ..startMs = start
    ..endMs = end
    ..audioFileIndex = 0;
}

/// BUG-3319：图形字幕（PGS / VobSub，libmpv 自绘、Dart 侧无 cue）当前在屏那句的
/// 查词 / 制卡锚点 cue。
///
/// [startMs] / [endMs] 是 mpv `sub-start` / `sub-end` 换算的毫秒。mpv 的
/// `sub_get_times` 先把视频 pts 换到字幕时基（减 `sub-delay`）再查当前句，返回的起止
/// **不加回** `sub-delay`——即字幕文件原始坐标，与文本字幕 cue 的坐标系相同。图形模式
/// 下 `sub-delay` = 主轨调轴，故制卡照常 `+ delayMs` 逆变换回播放器轴即可。
///
/// [startMs] 为 null（此刻画面上没有字幕，mpv 报属性不可用）→ null：不按播放位置
/// 编一个假窗，交给制卡的「无区间 → 当前帧静图」路径。[endMs] 缺失（个别容器的 PGS
/// 结束段未到）沿用 [kPlayerDecodedCueProvisionalMs] 暂定时长。[text] 是用户在暂停
/// OCR 层点的那行识别文字（图形字幕没有 `sub-text`），为空同样返回 null。
AudioCue? buildGraphicSubtitleAnchorCue({
  required String text,
  required int? startMs,
  required int? endMs,
}) {
  if (startMs == null) return null;
  return buildPlayerDecodedCue(
    text: text,
    startMs: startMs,
    endMs: endMs,
    positionMs: startMs,
  );
}

/// 暂停 OCR 在「没有字幕轨可锚」的画面（硬字幕 / 烧进画面的文字）上点字查词时，默认
/// 句子音频窗口的长度：暂停位置往前这么久。
const int kFrameOcrFallbackWindowMs = 4000;

/// 硬字幕画面上 OCR 点字查词的锚点 cue：没有任何字幕时间窗（硬字幕烧进画面，mpv 没有
/// `sub-start`），制卡区间会塌成 `0..0`（无句子音频）。这里退而求其次，把窗口定成
/// 「暂停位置往前 [windowMs]」，用户再用高级制卡的起止偏移微调。
///
/// 返回的 cue 时刻在**字幕轴**（制卡会按 `miningClipTimeMs` 加回 [delayMs] 换算到播放器
/// 轴），所以这里先减去 [delayMs]，保证最终裁的就是 `[positionMs - windowMs, positionMs]`。
/// 窗口下界夹到 0；[text] 为空或窗口为空（位置在片头 0）返回 null。
AudioCue? buildFrameOcrFallbackCue({
  required String text,
  required int positionMs,
  required int delayMs,
  int windowMs = kFrameOcrFallbackWindowMs,
}) {
  final int playerEndMs = positionMs < 0 ? 0 : positionMs;
  final int playerStartMs = playerEndMs - windowMs < 0
      ? 0
      : playerEndMs - windowMs;
  if (playerEndMs <= playerStartMs) return null;
  return buildPlayerDecodedCue(
    text: text,
    startMs: playerStartMs - delayMs,
    endMs: playerEndMs - delayMs,
    positionMs: playerStartMs - delayMs,
  );
}

/// 把 [cue] 合进按 startMs 升序的 [cues]，返回新列表（不改入参）、这句落在第几位
/// [index]，以及是不是插入 [inserted]（false = 原地替换）。
///
/// - 同一起点的已有句（seek 回看重放 / mpv 对同一句重复上报）→ 替换，不重复；
/// - 否则按起点插入；
/// - 结果的 [AudioCue.sentenceIndex] 按列表位置重排（字幕列表 / 跳句按它编号）。
///
/// 调用方据此维护下标类播放态：替换不动任何下标，插入只把 ≥ [index] 的下标
/// 后移一位（[shiftCueIndexForInsert]）。整体作废会让「重播本句」的单句停与
/// 「字幕结束暂停」失效——播到目标句时 mpv 必然重新上报这一句。
({List<AudioCue> cues, int index, bool inserted}) mergePlayerDecodedCue(
  List<AudioCue> cues,
  AudioCue cue,
) {
  final List<AudioCue> next = List<AudioCue>.of(cues);
  final int same = next.indexWhere((AudioCue c) => c.startMs == cue.startMs);
  final int index;
  final bool inserted;
  if (same >= 0) {
    next[same] = cue;
    index = same;
    inserted = false;
  } else {
    int insertAt = next.length;
    for (int i = 0; i < next.length; i++) {
      if (next[i].startMs > cue.startMs) {
        insertAt = i;
        break;
      }
    }
    next.insert(insertAt, cue);
    index = insertAt;
    inserted = true;
  }
  for (int i = 0; i < next.length; i++) {
    next[i].sentenceIndex = i;
  }
  return (cues: next, index: index, inserted: inserted);
}

/// 图形字幕（PGS / VobSub / DVB，libmpv 自绘）**边播边记**的一句：mpv 此刻在屏那句的
/// `sub-start` / `sub-end`（毫秒，字幕时基）合进逐句时间表 [cues]（按 startMs 升序）。
///
/// 位图字幕没有 `sub-text`，但 libmpv 的位图解码驱动（`sd_lavc`）实现了 `get_times`：
/// 画面上有位图时 `sub-start` 就是那句的显示起点，`sub-end` 在结束段解码后才可用
/// （之前不可用）。所以：
/// - 同一起点已在表里 → 只在拿到真实结束时**原地**改它的 endMs（不换对象：制卡流按
///   身份认 cue，换对象会让正在用它的制卡认不出所属流）；结束仍未知则不动；
/// - 否则按起点插入一句**无文字** cue，结束未知用 [kPlayerDecodedCueProvisionalMs]
///   暂定（调用方在下一句出现时按 mpv 自己的规则收尾，见 [closePlayerDecodedCue]）。
///
/// 返回新表（插入时为新列表，原地改时为原列表）、这句的 cue、表是否有变化，以及这句
/// 是不是新插入的 [inserted]（调用方据此认「结束未知的新句」= 暂定句）。
({List<AudioCue> cues, AudioCue cue, bool changed, bool inserted})
mergeGraphicSubtitleLiveTiming(
  List<AudioCue> cues, {
  required int startMs,
  required int? endMs,
}) {
  final int? end = endMs != null && endMs > startMs ? endMs : null;
  for (final AudioCue existing in cues) {
    if (existing.startMs != startMs) continue;
    if (end == null || existing.endMs == end) {
      return (cues: cues, cue: existing, changed: false, inserted: false);
    }
    existing.endMs = end;
    return (cues: cues, cue: existing, changed: true, inserted: false);
  }
  final AudioCue cue = AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = ''
    ..startMs = startMs
    ..endMs = end ?? startMs + kPlayerDecodedCueProvisionalMs
    ..audioFileIndex = 0;
  final List<AudioCue> next = List<AudioCue>.of(cues);
  int insertAt = next.length;
  for (int i = 0; i < next.length; i++) {
    if (next[i].startMs > startMs) {
      insertAt = i;
      break;
    }
  }
  next.insert(insertAt, cue);
  for (int i = 0; i < next.length; i++) {
    next[i].sentenceIndex = i;
  }
  return (cues: next, cue: cue, changed: true, inserted: true);
}

/// 图形字幕的**有效**逐句时间表：整轨抽取结果 [extracted] 是权威（字幕包里的真实起止，
/// 覆盖整条轨）；边播边记的 [live] 只在抽取结果还没到（或这条来源抽不了）时顶上，抽取
/// 结果到了以后只保留与它**不重叠**的句子（抽取解析丢掉的句子才由它补上）。
///
/// 两边的 cue 对象原样复用（制卡流按身份认 cue）；结果按起点升序、
/// [AudioCue.sentenceIndex] 按位置重排。
List<AudioCue> mergeGraphicSubtitleTimingTables({
  required List<AudioCue> extracted,
  required List<AudioCue> live,
}) {
  if (extracted.isEmpty) return List<AudioCue>.unmodifiable(live);
  bool overlapsExtracted(AudioCue cue) => extracted.any(
    (AudioCue e) =>
        e.startMs == cue.startMs ||
        (cue.startMs < e.endMs && e.startMs < cue.endMs),
  );
  final List<AudioCue> merged = <AudioCue>[
    ...extracted,
    for (final AudioCue cue in live)
      if (!overlapsExtracted(cue)) cue,
  ]..sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
  for (int i = 0; i < merged.length; i++) {
    merged[i].sentenceIndex = i;
  }
  return List<AudioCue>.unmodifiable(merged);
}

/// 在第 [insertedAt] 位插入一句后，原下标 [index] 的新位置（null 保持 null）。
int? shiftCueIndexForInsert(int? index, int insertedAt) {
  if (index == null || index < 0) return index;
  return index >= insertedAt ? index + 1 : index;
}

/// mpv 没给 `sub-end` 的那句（暂定时长）在字幕下一次变化时按真实位置 [atMs]
/// 收尾；[atMs] 不在该句区间内（seek 走了）则保持暂定值。返回是否改动。
bool closePlayerDecodedCue(AudioCue cue, int atMs) {
  if (atMs <= cue.startMs || atMs >= cue.endMs) return false;
  cue.endMs = atMs;
  return true;
}

/// media_kit `Player.stream.subtitle` / `state.subtitle` 的第 [slot] 槽文本：
/// 0 = 主字幕 `sub-text`，1 = 副字幕 `secondary-sub-text`。列表不够长按空串。
String playerSubtitleSlotText(List<String> texts, int slot) =>
    slot < texts.length ? texts[slot] : '';

/// 只在第 [slot] 槽文本**真的变化**时出事件（初值 [initial] = 订阅时已处理过的那句）。
///
/// media_kit 把 `sub-text` 与 `secondary-sub-text` 合成同一条 `[主, 副]` 流上报：
/// 副字幕一换句，主字幕的订阅也会收到一次「主文本不变」的事件。回流逻辑把每次事件
/// 当作「上一句到此结束」（[closePlayerDecodedCue]），不按槽去重，另一槽换句就会把
/// 这一槽没给 end 的暂定句提前截断。
Stream<String> playerSubtitleSlotChanges(
  Stream<List<String>> reports,
  int slot,
  String initial,
) {
  String last = initial;
  return reports
      .map((List<String> texts) => playerSubtitleSlotText(texts, slot))
      .where((String text) {
        if (text == last) return false;
        last = text;
        return true;
      });
}
