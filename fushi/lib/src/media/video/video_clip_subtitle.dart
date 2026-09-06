import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;

/// 片段导出的字幕封装：把**播放器内存里的 cue 列表**裁成片段区间的 SRT 文本。
///
/// 为什么真相源是 cue 而不是源文件的 `0:s:N`：Hibiki 的视频字幕不走 libmpv 渲染
/// （[VideoPlayerController.load] 里 `setSubtitleTrack(SubtitleTrack.no())` +
/// `buildSubtitleSuppressionProperties()` 把 libmpv 字幕彻底关掉），内嵌轨、外挂
/// 文件、自动对轴结果全部被解析成统一的 `List<AudioCue>` 交给 Flutter overlay 渲染
/// （所以能逐字查词）。于是「用户选中的字幕」只存在于 cue 列表里：
///
/// - 外挂字幕在源文件里根本没有对应的 `0:s:N` 流，`-map 0:s` 拿不到；
/// - 内嵌轨即便能 map，也丢掉了用户调过的 [VideoPlayerController.delayMs] 偏移和
///   自动对轴修正，导出的时间轴与屏幕上看到的不一致。
///
/// 从 cue 生成，这些来源差异全部消失——一条路径，没有 if/else 分支，导出的字幕
/// 恰好是用户屏幕上看到的那条。

/// 把 [cues] 裁成 `[startMs, endMs)` 区间的 SRT 文本，时间轴平移到片段起点为 0。
///
/// [delayMs] 是用户在播放器里调过的字幕偏移。语义与 [effectiveSubtitlePositionMs]
/// 互逆：overlay 用 `effective = pos - delay` 去 cue 轴查找，因此 cue 在**视频轴**
/// 上的真实出现时间是 `cue + delay`。导出必须按视频轴计算，否则用户调过轴的字幕
/// 导出后会整体错位。
///
/// 与区间有交集的 cue 都保留，跨界部分 clamp 到片段边界（半句话被截断时宁可显示
/// 半句，也不整条丢掉）。区间内没有任何可见文本时返回 null——调用方据此**不加**
/// 字幕输入，避免 ffmpeg 因空字幕文件失败。
String? buildClipSrtContent({
  required List<AudioCue> cues,
  required int startMs,
  required int endMs,
  int delayMs = 0,
}) {
  final List<ClipSubtitleCue> picked = buildClipSubtitleCues(
    cues: cues,
    startMs: startMs,
    endMs: endMs,
    delayMs: delayMs,
  );
  if (picked.isEmpty) return null;

  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < picked.length; i++) {
    final ClipSubtitleCue cue = picked[i];
    buffer
      ..writeln(i + 1)
      ..writeln('${formatSrtTimestamp(cue.startMs)} --> '
          '${formatSrtTimestamp(cue.endMs)}')
      ..writeln(cue.text)
      ..writeln();
  }
  return buffer.toString();
}

/// 片段区间内的一条字幕：时间轴**已平移到片段起点为 0**、已 clamp 到片段边界、
/// 文本已清洗。软字幕（SRT）与硬字幕烧录（`video_clip_subtitle_burn.dart`）共用
/// 同一份，两条路径不会因为各自挑 cue 而显示出不同的字幕。
@immutable
class ClipSubtitleCue {
  const ClipSubtitleCue({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.isSecondary = false,
  });

  /// 相对片段起点的出现时刻（毫秒）。
  final int startMs;

  /// 相对片段起点的消失时刻（毫秒）。恒 `> startMs`。
  final int endMs;

  /// 已清洗的文本（无空行，多行用单个 `\n` 连接）。恒非空。
  final String text;

  /// 这条 cue 属于副字幕层。
  ///
  /// 只有硬字幕烧录用得到：主副两层在屏幕上锚在画面的**对侧**（主底 → 副顶，见
  /// [resolveLayerForcedAnchor]），扁平成一个列表后必须靠这个标记还原层归属，否则
  /// 副字幕会和主字幕叠印在同一个位置。SRT 生成不看它（两条轨各生成各的）。
  final bool isSecondary;

  @override
  bool operator ==(Object other) =>
      other is ClipSubtitleCue &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.text == text &&
      other.isSecondary == isSecondary;

  @override
  int get hashCode => Object.hash(startMs, endMs, text, isSecondary);

  @override
  String toString() => 'ClipSubtitleCue($startMs..$endMs, "$text"'
      '${isSecondary ? ', secondary' : ''})';
}

/// 纯函数：把播放器内存里的 cue 裁成片段区间的字幕列表（**选择与裁剪的唯一真相源**）。
///
/// 语义与 [buildClipSrtContent] 逐字相同（后者现在就建在它之上）：
/// - `delayMs` 把 cue 轴换算到视频轴（cue 在视频轴上的真实时刻是 `cue + delay`）；
/// - 与区间有交集的 cue 都保留，跨界部分 clamp 到片段边界（半句话被截断时宁可显示
///   半句，也不整条丢掉）；
/// - 文本清洗后为空的 cue 丢弃（纯样式/空行 cue）；
/// - 零长或负长 cue 给 1ms 保底可见宽度——多数播放器对零长 cue 根本不显示，而
///   `overlay` 的 `enable='between(t,a,b)'` 在 `a>=b` 时恒假，两边同病。
List<ClipSubtitleCue> buildClipSubtitleCues({
  required List<AudioCue> cues,
  required int startMs,
  required int endMs,
  int delayMs = 0,
  bool isSecondary = false,
}) {
  if (cues.isEmpty || endMs <= startMs) return const <ClipSubtitleCue>[];
  final int durationMs = endMs - startMs;

  final List<ClipSubtitleCue> out = <ClipSubtitleCue>[];
  for (final AudioCue cue in cues) {
    // cue 轴 → 视频轴。
    final int cueStart = cue.startMs + delayMs;
    final int cueEnd = cue.endMs + delayMs;
    if (cueEnd <= startMs || cueStart >= endMs) continue;

    final String text = _sanitizeSrtText(cue.text);
    if (text.isEmpty) continue;

    final int outStart = (cueStart - startMs).clamp(0, durationMs);
    int outEnd = (cueEnd - startMs).clamp(0, durationMs);
    // 零长（或负长）cue 在多数播放器里根本不显示；给 1ms 保底可见宽度。
    if (outEnd <= outStart) outEnd = (outStart + 1).clamp(0, durationMs);
    if (outEnd <= outStart) continue;

    out.add(ClipSubtitleCue(
      startMs: outStart,
      endMs: outEnd,
      text: text,
      isSecondary: isSecondary,
    ));
  }
  return List<ClipSubtitleCue>.unmodifiable(out);
}

/// SRT 时间戳：`HH:MM:SS,mmm`。负值 clamp 到 0（SRT 无负时间轴）。
String formatSrtTimestamp(int ms) {
  final int safe = ms < 0 ? 0 : ms;
  final int totalSeconds = safe ~/ 1000;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;
  final int millis = safe % 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(hours)}:${two(minutes)}:${two(seconds)},'
      '${millis.toString().padLeft(3, '0')}';
}

/// 清洗 cue 文本，使其能安全放进 SRT 块。
///
/// SRT 用**空行**分隔字幕块，所以文本内部绝不能出现空行，否则后续块全部错位解析。
/// 统一换行符、逐行 trim、丢掉空行、多行用单个 `\n` 连接。
String _sanitizeSrtText(String raw) {
  return raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .join('\n');
}

/// 输出容器能封装什么字幕编码。按**输出扩展名**判定（片段导出的输出扩展名跟随
/// 输入）。返回 null = 该容器封不了文本字幕，调用方跳过字幕、只导视频音频。
///
/// 为什么必须判定而不是无脑 `-c copy`：往 mp4 里 copy 一条 SRT 流会让 ffmpeg
/// **整个任务硬失败**（`Subtitle codec 0x17000 is not supported`），把原本能成功的
/// 视频导出一起拖垮。加字幕不能以破坏既有导出为代价。
String? resolveClipSubtitleCodec(String outputPath) {
  switch (p.extension(outputPath).toLowerCase()) {
    // Matroska / WebM 原生吃 SRT，直接 copy。
    case '.mkv':
    case '.mka':
    case '.webm':
      return 'copy';
    // ISO-BMFF 系只认 3GPP Timed Text（`tx3g`），而 **tx3g 轨会让整个片段在 QQ
    // 这类 IM 的内置播放器里判为不可播**（BUG-2202）。用户在真 QQ 上二分过：同一份
    // 源，只差字幕轨的两个变体，带轨打不开、去轨能放；再把轨的 `tkhd` enabled 位
    // 清零、把 `hdlr` 从 `sbtl` 改成规范的 `text`，两种补丁都仍然打不开。而即便它
    // 能播，QQ 也不会渲染 tx3g——内封字幕在「导出→分享」这个主场景里是纯负资产：
    // 既让文件播不了，播得了也看不见字。
    //
    // 所以 mp4 系一律返回 null（= 跳过字幕，只导视频音频）。**不加新分支**：调用方
    // 早就有「容器封不下文本字幕 → 退回纯视频音频导出」这条降级链，这里改返回值就
    // 够了。字幕会以**硬字幕**形式回来（`video_clip_subtitle_burn.dart` 的 `overlay`
    // 烧录），届时它走的是完全不同的路径，与本函数无关。
    case '.mp4':
    case '.m4v':
    case '.mov':
      return null;
    // .ts / .avi / .flv / .wmv 等：无可靠的文本字幕封装，跳过。
    default:
      return null;
  }
}
