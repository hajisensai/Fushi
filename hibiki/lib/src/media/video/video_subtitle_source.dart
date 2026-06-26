import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// 视频字幕源统一模型与枚举/加载逻辑。
///
/// 两类字幕源：
/// - **内嵌轨**（[EmbeddedSubtitleTrack]）：mkv/mp4 容器内的字幕流，用 ffmpeg
///   `-map 0:s:N` 抽出。一个容器常有多条（如龙女仆的 forced/default 两条 ass）。
/// - **外挂文件**：视频同目录的 `.srt/.ass/.ssa/.vtt`（含 `.ja.srt` 等带语言后缀）。
///
/// 解析路由覆盖 srt/ass/ssa/vtt 四类文本字幕格式（图形字幕 pgs/dvd 无法转 cue，
/// 枚举时仍列出但加载会返回空）。

/// 一条内嵌字幕轨的元数据。
///
/// [streamIndex] 是**字幕类型内的相对序号**（第一条 Subtitle=0，第二条=1…），
/// 用于 ffmpeg `-map 0:s:$streamIndex`，**不是** `#0:N` 里的全局流号。
class EmbeddedSubtitleTrack {
  const EmbeddedSubtitleTrack({
    required this.streamIndex,
    required this.codec,
    this.language,
    this.title,
  });

  /// 字幕流相对序号（0,1,2…），用于 `-map 0:s:N`。
  final int streamIndex;

  /// 字幕编码（如 `ass` / `subrip` / `webvtt` / `hdmv_pgs_subtitle`）。
  final String codec;

  /// 语言（ISO code，如 `eng` / `jpn`）；ffmpeg 日志里 `#0:N(lang)` 的括号内容。
  final String? language;

  /// 轨标题（ffmpeg 日志 metadata 块里的 `title` / mp4 回退 `handler_name`；
  /// 无则为 null）。例如龙女仆 ass 轨的 `Full Subtitles` / `Signs & Songs`。
  final String? title;
}

enum EmbeddedSubtitleTrackProbeStatus {
  success,
  missingFile,
  timeout,
  ffmpegUnavailable,
  failed,
}

class EmbeddedSubtitleTrackProbeResult {
  const EmbeddedSubtitleTrackProbeResult({
    required this.tracks,
    required this.status,
    required this.timeout,
    required this.sizeBytes,
  });

  final List<EmbeddedSubtitleTrack> tracks;
  final EmbeddedSubtitleTrackProbeStatus status;
  final Duration timeout;
  final int sizeBytes;

  bool get timedOut => status == EmbeddedSubtitleTrackProbeStatus.timeout;
}

/// 字幕文本格式（决定用哪个 parser）。
enum SubtitleFormat { srt, ass, vtt }

/// 匹配 `Stream #0:N(lang): Subtitle: codec ...` 行的正则。
///
/// - `(lang)` 可选（无语言括号的字幕轨语言为 null）。
/// - codec 取 `Subtitle: ` 之后的第一个 token（如 `ass`、`subrip`、
///   `hdmv_pgs_subtitle`），后面的 `(ssa)` / `(forced)` / `(default)` 是
///   ffmpeg 附加描述，不并入 codec。
/// - `#0:1` 与 `(lang)` 之间可能有一段十六进制流 id `[0x2]`（新版 ffmpeg 对
///   mp4/mov 字幕流会打印它）；这段可选，匹配时跳过，否则 mp4 内封字幕整条漏掉
///   （枚举为 0）。
final RegExp _subtitleStreamPattern = RegExp(
  r'Stream #\d+:\d+(?:\[0x[0-9a-fA-F]+\])?(?:\(([^)]+)\))?: Subtitle:\s+([A-Za-z0-9_]+)',
);

/// 匹配 ffmpeg 任意 `Stream #N:M ...` 行（任意类型：Video/Audio/Subtitle/
/// Attachment…）。解析字幕轨 metadata 块时用它识别「下一条 Stream 行」边界——
/// metadata 块是该 Stream 行下方更深缩进的独立行，扫到下一条 Stream 即停。
final RegExp _anyStreamLinePattern = RegExp(r'Stream #\d+:\d+');

/// 匹配 ffmpeg metadata 块里的 `title           : <值>` 行（mkv 软字幕的轨名）。
/// 键名大小写不敏感，冒号两侧允许任意空白。
final RegExp _metadataTitlePattern = RegExp(
  r'^\s*title\s*:\s*(.+?)\s*$',
  caseSensitive: false,
);

/// 匹配 ffmpeg metadata 块里的 `handler_name : <值>` 行（mp4 容器轨名所在）。
final RegExp _metadataHandlerNamePattern = RegExp(
  r'^\s*handler_name\s*:\s*(.+?)\s*$',
  caseSensitive: false,
);

/// mp4 `handler_name` 常见的容器噪声值（非用户可读轨名），需过滤掉。
const Set<String> _handlerNameNoise = <String>{
  'subtitlehandler',
  'soundhandler',
  'videohandler',
  'mainconcept video media handler',
  'core media audio',
  'core media video',
};

/// **纯函数**：解析 `ffmpeg -i <video>` 的 stderr，提取所有内嵌字幕轨。
///
/// 按出现顺序为每条字幕分配相对序号（0,1,2…），即 `-map 0:s:N` 的 N。提取
/// 语言（括号内）、codec（`Subtitle: ` 后第一个 token）以及轨标题 [title]。
///
/// 轨标题不在 `Stream #0:N` 行上，而在其下方更深缩进的独立 `Metadata:` 块里
/// （mkv 为 `title : <名字>`；mp4 容器一般写 `handler_name : <名字>`，但
/// `SubtitleHandler` 之类是无意义的容器噪声，需过滤）。扫到字幕 Stream 行后继续
/// 向后读其 metadata 块，直到下一条 Stream 行或输入结束。无字幕轨 / 空输入返回
/// 空列表。不碰文件系统，可单测。
List<EmbeddedSubtitleTrack> parseSubtitleStreamsFromFfmpegLog(
  String ffmpegStderr,
) {
  final List<EmbeddedSubtitleTrack> tracks = <EmbeddedSubtitleTrack>[];
  final List<String> lines = const LineSplitter().convert(ffmpegStderr);
  int relativeIndex = 0;
  for (int i = 0; i < lines.length; i++) {
    final RegExpMatch? m = _subtitleStreamPattern.firstMatch(lines[i]);
    if (m == null) continue;
    final String? language = m.group(1);
    final String codec = m.group(2)!;
    final String? title = _extractTrackTitle(lines, i + 1);
    tracks.add(EmbeddedSubtitleTrack(
      streamIndex: relativeIndex,
      codec: codec,
      language: language,
      title: title,
    ));
    relativeIndex++;
  }
  return tracks;
}

/// 从字幕 Stream 行之后（[start] 起）向后扫描其 metadata 块，提取有意义的轨标题。
///
/// 扫描到下一条 `Stream #N:M` 行即停（metadata 块只属于上一条 Stream）。优先取
/// `title`（mkv 软字幕轨名）；mp4 容器没有 title 时回退第一条 `handler_name`，但
/// 过滤掉 `SubtitleHandler` 之类的容器噪声。没有可用标题返回 null（保持旧行为不
/// 显示标题）。
String? _extractTrackTitle(List<String> lines, int start) {
  String? handlerFallback;
  for (int i = start; i < lines.length; i++) {
    final String line = lines[i];
    if (_anyStreamLinePattern.hasMatch(line)) break;
    final RegExpMatch? titleMatch = _metadataTitlePattern.firstMatch(line);
    if (titleMatch != null) {
      final String value = titleMatch.group(1)!.trim();
      if (value.isNotEmpty) return value;
    }
    final RegExpMatch? handlerMatch =
        _metadataHandlerNamePattern.firstMatch(line);
    if (handlerMatch != null && handlerFallback == null) {
      final String value = handlerMatch.group(1)!.trim();
      if (value.isNotEmpty &&
          !_handlerNameNoise.contains(value.toLowerCase())) {
        handlerFallback = value;
      }
    }
  }
  return handlerFallback;
}

/// 按文件扩展名判定字幕格式（外挂文件用）。`.ssa` 归入 [SubtitleFormat.ass]；
/// 未知扩展名返回 null。
SubtitleFormat? subtitleFormatForPath(String path) {
  final String ext = p.extension(path).toLowerCase();
  switch (ext) {
    case '.srt':
      return SubtitleFormat.srt;
    case '.ass':
    case '.ssa':
      return SubtitleFormat.ass;
    case '.vtt':
      return SubtitleFormat.vtt;
    default:
      return null;
  }
}

/// **纯函数**：判断持久化字幕源值 [persisted] 是否「显式导入/下载的外挂字幕文件」
/// ——即非内嵌（`embedded:`）前缀、且扩展名是受支持字幕格式（srt/ass/ssa/vtt）。
///
/// 这类源（用户手动导入 / Jimaku 下载）被拷到 `<appDocs>/video_subtitles/`，其持久化
/// 值就是文件绝对路径、与视频/剧集目录无关，恢复时应**直接按路径加载**（BUG-132）；
/// 不能只靠 [listAllSubtitleSources]——它仅扫视频同目录 + 内封轨，扫不到 app 文档目录
/// 里的导入文件，导致播放列表换集/重进后「字幕又要重新导入」。是否真在磁盘上由调用方
/// 另查（本函数不碰文件系统，可单测）。
bool isImportedExternalSubtitlePath(String persisted) {
  if (persisted.isEmpty) return false;
  if (persisted.startsWith(SubtitleSource.embeddedPrefix)) return false;
  return subtitleFormatForPath(persisted) != null;
}

/// **纯函数**：换集时是否应「原样沿用」上一集持久化的外挂字幕路径 [persisted]，
/// 而非按新集名重新匹配同目录 sidecar。
///
/// 背景（BUG-165 / BUG-132）：BUG-132 给播放列表恢复加了「持久化值是显式导入字幕
/// （[isImportedExternalSubtitlePath]）且文件在磁盘上就按路径直接加载」的捷径，救
/// 「导入字幕住在 `<appDocs>/video_subtitles/`、不在剧集目录里、换集枚举不到」的丢
/// 失。但该捷径只看扩展名，把**剧集自带、住在视频同目录**的 sidecar（如上一集
/// `EP01.ja.srt`）也截下来跨集原样沿用 → 切到 `EP02` 仍显示 `EP01` 字幕（BUG-165）。
///
/// 区分依据是**目录归属**，不是扩展名：真正的导入/下载字幕住在独立目录
/// （video_subtitles 等），与剧集目录无关；剧集自带 sidecar 与新集视频**同目录**。
/// 规则：
/// - [persisted] 非导入外挂字幕（内嵌 `embedded:` / 空 / 非字幕扩展名）→ false
///   （捷径本就不该接管，交给原有同类匹配/枚举）。
/// - [persisted] 的目录 == 新集视频 [episodeVideoPath] 的目录 → false：这是上一集
///   的同目录 sidecar，换集应按新集 basename 重新匹配（走 [pickEpisodeSubtitleSource]）。
/// - 否则（导入字幕，住别处）→ true：与剧集目录无关，跨集沿用同一文件。
///
/// 不碰文件系统（是否真在磁盘上由调用方另查），可单测。
bool shouldReusePersistedSubtitleAcrossEpisode(
  String persisted,
  String episodeVideoPath,
) {
  if (!isImportedExternalSubtitlePath(persisted)) return false;
  final String subtitleDir = p.canonicalize(p.dirname(persisted));
  final String episodeDir = p.canonicalize(p.dirname(episodeVideoPath));
  return subtitleDir != episodeDir;
}

/// 从一组拖入文件路径 [paths] 中挑出第一个受支持的字幕文件
/// （srt/ass/ssa/vtt），无则 null。
///
/// **纯函数**：复用 [subtitleFormatForPath] 判定扩展名（DRY），供视频播放页
/// 拖拽落地时过滤——用户可能一次拖入视频+字幕+图片，只取第一个能解析的字幕。
String? firstSubtitlePath(List<String> paths) {
  for (final String path in paths) {
    if (subtitleFormatForPath(path) != null) return path;
  }
  return null;
}

/// 按内嵌轨 codec 判定字幕格式。
///
/// 设计（**fail-open**，消除「白名单漏一个文本 codec 就静默无字幕」的整类 bug）：
/// - `ass`/`ssa` → ass、`webvtt`/`vtt` → vtt：原生 parser 保真（保留划词文本质量）。
/// - **已知图形字幕**（pgs/dvd/dvb/xsub 等位图，无法转文本 cue，需 OCR）→ null。
/// - **其余一律按文本字幕 → srt**：subrip/srt/mov_text/tx3g/text/microdvd/… 都由
///   ffmpeg 按 `.srt` 输出扩展名转码成 SubRip，再走 SrtParser（剥 HTML 标签）。
///   即便某个真图形 codec 不在上面的排除名单里，ffmpeg 也会因「位图无法编码成
///   srt」抽取失败 → cue 为空（与返回 null 同效，不会引入坏数据）。
///
/// 这样 mp4 的 `mov_text`（旧实现漏映射 → null → 切换内封后无字幕）等文本 codec
/// 一律可用（BUG-071）。
SubtitleFormat? subtitleFormatForCodec(String codec) {
  switch (codec.toLowerCase()) {
    case 'ass':
    case 'ssa':
      return SubtitleFormat.ass;
    case 'webvtt':
    case 'vtt':
      return SubtitleFormat.vtt;
    // 已知图形字幕（位图，需 OCR）：明确不支持，返回 null。
    case 'hdmv_pgs_subtitle':
    case 'pgssub':
    case 'dvd_subtitle':
    case 'dvdsub':
    case 'dvb_subtitle':
    case 'dvbsub':
    case 'xsub':
      return null;
    // 其余按文本字幕处理：ffmpeg 转码成 srt，SrtParser 解析。
    default:
      return SubtitleFormat.srt;
  }
}

/// **纯函数**：按格式路由到对应 parser，把字幕内容解析为 cue 列表。
String subtitleExtensionForFormat(SubtitleFormat format) {
  switch (format) {
    case SubtitleFormat.srt:
      return '.srt';
    case SubtitleFormat.ass:
      return '.ass';
    case SubtitleFormat.vtt:
      return '.vtt';
  }
}

String? subtitleExtensionForCodec(String codec) {
  final SubtitleFormat? format = subtitleFormatForCodec(codec);
  return format == null ? null : subtitleExtensionForFormat(format);
}

List<AudioCue> parseSubtitleContent(
  SubtitleFormat format, {
  required String content,
  required String bookUid,
}) {
  // AudioCue is keyed by `bookKey` (name-PK rename); a video book's owner key
  // for its cues is its own book_uid, so pass bookUid as the cue's bookKey.
  switch (format) {
    case SubtitleFormat.srt:
      return SrtParser.parseString(content: content, bookKey: bookUid);
    case SubtitleFormat.ass:
      return AssParser.parseString(content: content, bookKey: bookUid);
    case SubtitleFormat.vtt:
      return VttParser.parseString(content: content, bookKey: bookUid);
  }
}

Future<List<AudioCue>> parseSubtitleContentAsync(
  SubtitleFormat format, {
  required String content,
  required String bookUid,
}) {
  // AudioCue is keyed by `bookKey` (name-PK rename); a video book's owner key
  // for its cues is its own book_uid, so pass bookUid as the cue's bookKey.
  switch (format) {
    case SubtitleFormat.srt:
      return SrtParser.parseStringAsync(content: content, bookKey: bookUid);
    case SubtitleFormat.ass:
      return AssParser.parseStringAsync(content: content, bookKey: bookUid);
    case SubtitleFormat.vtt:
      return VttParser.parseStringAsync(content: content, bookKey: bookUid);
  }
}

/// 统一字幕源：内嵌轨或外挂文件二选一。
///
/// 持久化到 `VideoBooks.subtitleSource`：外挂源存绝对路径；内嵌源存约定字符串
/// `embedded:<streamIndex>`（复用同一列，不新增 schema）。
class SubtitleSource {
  const SubtitleSource.embedded({
    required int this.streamIndex,
    required this.label,
    this.language,
    this.codec,
  })  : isEmbedded = true,
        externalPath = null;

  const SubtitleSource.external({
    required String this.externalPath,
    required this.label,
  })  : isEmbedded = false,
        streamIndex = null,
        language = null,
        codec = null;

  /// 是否内嵌轨（true=内嵌，false=外挂文件）。
  final bool isEmbedded;

  /// 内嵌轨相对序号（`-map 0:s:N`）；外挂源为 null。
  final int? streamIndex;

  /// 外挂字幕绝对路径；内嵌源为 null。
  final String? externalPath;

  /// 内嵌轨语言（如 `eng`）；外挂源为 null。
  final String? language;

  /// 内嵌轨 codec（如 `ass`）；外挂源为 null。
  final String? codec;

  /// 菜单显示标签。
  final String label;

  /// 内嵌源约定前缀（持久化时拼 streamIndex）。
  static const String embeddedPrefix = 'embedded:';

  /// 「用户显式关闭字幕」哨兵（持久化到 `VideoBooks.subtitleSource`）。
  ///
  /// 第三态的单一真值：补全 `subtitleSource` 列原本只有「非空=选了具体源」与
  /// `null=从未选过/无偏好` 两态、把「显式关闭」与「无偏好」压成同一 `null` 的歧义
  /// （TODO-818）。与 [embeddedPrefix] 同命名空间但不撞——外挂源是绝对路径、内嵌源是
  /// `embedded:<n>`，都不会是裸 `off:`。
  ///
  /// 向后兼容铁律：旧数据里的 `null` 仍按「无偏好→自动选默认」处理；只有新写入的本
  /// 哨兵才表示「显式关闭」，故 [isOff] 只认这一字符串，绝不把 `null` 当关闭。
  static const String offSentinel = 'off:';

  /// 持久化值 [persisted] 是否代表「用户显式关闭字幕」（见 [offSentinel]）。
  /// `null`（旧数据/无偏好）返回 false。
  static bool isOff(String? persisted) => persisted == offSentinel;

  /// 持久化值：内嵌 → `embedded:<n>`，外挂 → 绝对路径。
  String toPersistedValue() =>
      isEmbedded ? '$embeddedPrefix$streamIndex' : externalPath!;

  /// 该源是否就是 [persisted] 持久化值代表的源（用于菜单高亮当前选中）。
  bool matchesPersisted(String? persisted) {
    if (persisted == null) return false;
    return toPersistedValue() == persisted;
  }

  /// 是否「图形（位图）内嵌轨」：内嵌轨且 codec 无文本格式映射
  /// （pgs/dvd/dvb/xsub 等），即 [subtitleFormatForCodec] 返回 null。
  ///
  /// 图形字幕没有文字数据、不做 OCR 就无法转可查词 cue（ffmpeg 抽 srt 直接报
  /// `bitmap to bitmap` 拒绝）。这类轨只能交给 libmpv 当画面字幕渲染（看得到、
  /// 不可逐字查词），故菜单要区分标注、选中走不同分支（不抽 cue）。外挂源恒 false。
  bool get isGraphicEmbedded =>
      isEmbedded && subtitleFormatForCodec(codec ?? '') == null;
}

class SubtitleSourceListing {
  const SubtitleSourceListing({
    required this.sources,
    required this.embeddedProbe,
  });

  final List<SubtitleSource> sources;
  final EmbeddedSubtitleTrackProbeResult embeddedProbe;
}

enum DefaultEmbeddedSubtitleLoadStatus {
  loaded,
  missingFile,
  enumerationTimeout,
  enumerationFailed,
  noEmbeddedTracks,
  noTextTrack,
  emptyCues,
}

class DefaultEmbeddedSubtitleLoadResult {
  const DefaultEmbeddedSubtitleLoadResult({
    required this.status,
    required this.cues,
    required this.embeddedProbe,
    this.source,
  });

  final DefaultEmbeddedSubtitleLoadStatus status;
  final List<AudioCue> cues;
  final EmbeddedSubtitleTrackProbeResult embeddedProbe;
  final SubtitleSource? source;

  bool get shouldNotifyFailure {
    switch (status) {
      case DefaultEmbeddedSubtitleLoadStatus.enumerationTimeout:
      case DefaultEmbeddedSubtitleLoadStatus.enumerationFailed:
      case DefaultEmbeddedSubtitleLoadStatus.emptyCues:
        return true;
      case DefaultEmbeddedSubtitleLoadStatus.loaded:
      case DefaultEmbeddedSubtitleLoadStatus.missingFile:
      case DefaultEmbeddedSubtitleLoadStatus.noEmbeddedTracks:
      case DefaultEmbeddedSubtitleLoadStatus.noTextTrack:
        return false;
    }
  }
}

/// **Pure**: whether a default embedded-subtitle load result is a *transient*
/// failure worth retrying once after a readiness signal.
///
/// First-open of a large container (cold page cache) makes the `ffmpeg -i`
/// enumeration race the prewarm extraction (`ffmpeg -map`) and libmpv demuxing
/// for disk IO; the probe can time out and return zero tracks even though the
/// container *does* carry text subtitles. Those statuses ("should have had a
/// subtitle but this attempt did not get one") can succeed on a retry once the
/// contention has subsided / the cache is warm. Terminal statuses (no embedded
/// track / no text track / missing file / already loaded) never benefit from a
/// retry. Mirrors TODO-521's "re-read once the readiness signal arrives".
bool isTransientDefaultEmbeddedSubtitleLoad(
  DefaultEmbeddedSubtitleLoadStatus status,
) {
  switch (status) {
    case DefaultEmbeddedSubtitleLoadStatus.enumerationTimeout:
    case DefaultEmbeddedSubtitleLoadStatus.enumerationFailed:
    case DefaultEmbeddedSubtitleLoadStatus.emptyCues:
      return true;
    case DefaultEmbeddedSubtitleLoadStatus.loaded:
    case DefaultEmbeddedSubtitleLoadStatus.noEmbeddedTracks:
    case DefaultEmbeddedSubtitleLoadStatus.noTextTrack:
    case DefaultEmbeddedSubtitleLoadStatus.missingFile:
      return false;
  }
}

/// Loads default text embedded subtitle cues, retrying **once** after a
/// readiness signal when the first attempt is a transient IO-contention failure
/// (TODO-572). Player-agnostic: callers inject [waitForReady] (e.g. wait for
/// libmpv subtitle tracks) and [isStillCurrent] (player identity + load token)
/// so this stays unit-testable without a real Player.
///
/// Order: first load → if [isStillCurrent] is false at any await boundary,
/// returns the latest result without applying side effects (caller drops it);
/// transient failure → [waitForReady] → re-check current → second load.
/// Non-transient (terminal/loaded) results are returned immediately without a
/// retry. Returns the final [DefaultEmbeddedSubtitleLoadResult]; the caller
/// decides whether to apply cues / notify, also gated on [isStillCurrent].
Future<DefaultEmbeddedSubtitleLoadResult>
    loadDefaultTextEmbeddedSubtitleCuesWithReadinessRetry({
  required String videoPath,
  required String bookUid,
  required Future<void> Function() waitForReady,
  required bool Function() isStillCurrent,
  String langCode = 'ja',
  Future<DefaultEmbeddedSubtitleLoadResult> Function({
    required String videoPath,
    required String bookUid,
    String langCode,
  })? loadOnce,
}) async {
  final Future<DefaultEmbeddedSubtitleLoadResult> Function({
    required String videoPath,
    required String bookUid,
    String langCode,
  }) load = loadOnce ?? loadDefaultTextEmbeddedSubtitleCues;

  DefaultEmbeddedSubtitleLoadResult result = await load(
    videoPath: videoPath,
    bookUid: bookUid,
    langCode: langCode,
  );
  if (!isStillCurrent()) return result;
  if (!isTransientDefaultEmbeddedSubtitleLoad(result.status)) return result;

  await waitForReady();
  if (!isStillCurrent()) return result;
  result = await load(
    videoPath: videoPath,
    bookUid: bookUid,
    langCode: langCode,
  );
  return result;
}

/// 跑 `ffmpeg -i <videoPath>` 并解析 stderr 得到所有内嵌字幕轨（IO 包装）。
///
/// `ffmpeg -i` 无输出文件时退出码非 0，但 stderr 仍含完整流信息，属正常；故不看
/// 退出码，只解析 stderr。ffmpeg 不存在 / 出错时静默返回空列表（与无字幕一致）。
/// 仅桌面端有意义（移动端无 ffmpeg），调用方门控。
///
/// BUG-303（TODO-412）：`-i` 探测的超时**必须随容器体积放大**。固定 30s 对小文件
/// 够用，但对大体积交错容器（多 GB REMUX / 1GB+ 多字体附件 mkv）在**冷缓存 +
/// 同时跑 [prewarmEmbeddedSubtitleCache] 整轨抽取 + libmpv 正在播放**三方争用磁盘
/// IO 时，连「读到字幕流 codec 参数」这一步都可能超过 30s——`-i` 为给交错容器里
/// 靠后的流定 codec 参数，会读到远超 probesize 的位置。一旦超时，[FfmpegBackend]
/// 返回 `returnCode:null + output:''`（按设计**不回退** PATH——超时是慢 IO 非坏二进制，
/// 见 ffmpeg_backend BUG-283 注释），解析空字符串 → **0 条字幕、菜单静默无内封字幕**
/// （字幕菜单「一个字幕没有」的真根因；离线单跑 ffmpeg 无争用故复现不出）。
/// 抽取路径（[subtitleExtractTimeoutForBytes]，BUG-104）早已学到这一课，枚举路径
/// 当时漏改；本修复让两条路径用同一条 size-scaled 超时，消除这类静默失败。
Future<EmbeddedSubtitleTrackProbeResult> probeEmbeddedSubtitleTracks(
  String videoPath,
) async {
  final int sizeBytes = _fileSizeOrZero(videoPath);
  final Duration timeout = subtitleExtractTimeoutForBytes(sizeBytes);
  if (!File(videoPath).existsSync()) {
    return EmbeddedSubtitleTrackProbeResult(
      tracks: const <EmbeddedSubtitleTrack>[],
      status: EmbeddedSubtitleTrackProbeStatus.missingFile,
      timeout: timeout,
      sizeBytes: sizeBytes,
    );
  }
  try {
    // 经统一 FfmpegBackend 跑 `-i`（CLI 后端 = 旧 Process 路径；捆绑后端可在移动端
    // 工作），解析合并的 stderr 输出。`-i` 无输出文件时退出码非 0，但 stderr 仍含
    // 完整流信息，故只看 output 不看退出码。超时按容器字节数放大（见上）。
    final FfmpegRunResult result = await resolveFfmpegBackend().run(
      <String>['-hide_banner', '-i', videoPath],
      timeout,
    );
    final List<EmbeddedSubtitleTrack> tracks =
        parseSubtitleStreamsFromFfmpegLog(result.output);
    // 真正失败（超时 SIGKILL → returnCode:null）必须留痕，否则「0 条字幕」与
    // 「真无字幕」无从区分，整类静默失败不可调试。不抛，保持优雅降级契约。
    if (result.returnCode == null) {
      debugPrint(
        '[VideoSubtitleSource] embedded enumeration timed out for "$videoPath" '
        '(size=$sizeBytes bytes) — menu will show no '
        'embedded subtitles this time',
      );
      return EmbeddedSubtitleTrackProbeResult(
        tracks: tracks,
        status: EmbeddedSubtitleTrackProbeStatus.timeout,
        timeout: timeout,
        sizeBytes: sizeBytes,
      );
    }
    if (result.returnCode != 0 && result.output.trim().isEmpty) {
      debugPrint(
        '[VideoSubtitleSource] embedded enumeration failed without ffmpeg '
        'diagnostics for "$videoPath" (returnCode=${result.returnCode}, '
        'size=$sizeBytes bytes)',
      );
      return EmbeddedSubtitleTrackProbeResult(
        tracks: const <EmbeddedSubtitleTrack>[],
        status: EmbeddedSubtitleTrackProbeStatus.failed,
        timeout: timeout,
        sizeBytes: sizeBytes,
      );
    }
    return EmbeddedSubtitleTrackProbeResult(
      tracks: tracks,
      status: EmbeddedSubtitleTrackProbeStatus.success,
      timeout: timeout,
      sizeBytes: sizeBytes,
    );
  } on ProcessException catch (e) {
    // ffmpeg 未安装：优雅降级为无内嵌字幕。
    debugPrint('[VideoSubtitleSource] ffmpeg unavailable: $e');
    return EmbeddedSubtitleTrackProbeResult(
      tracks: const <EmbeddedSubtitleTrack>[],
      status: EmbeddedSubtitleTrackProbeStatus.ffmpegUnavailable,
      timeout: timeout,
      sizeBytes: sizeBytes,
    );
  } catch (e, stack) {
    debugPrint('[VideoSubtitleSource] embedded enumeration failed: $e\n$stack');
    return EmbeddedSubtitleTrackProbeResult(
      tracks: const <EmbeddedSubtitleTrack>[],
      status: EmbeddedSubtitleTrackProbeStatus.failed,
      timeout: timeout,
      sizeBytes: sizeBytes,
    );
  }
}

Future<List<EmbeddedSubtitleTrack>> listEmbeddedSubtitleTracks(
  String videoPath,
) async {
  return (await probeEmbeddedSubtitleTracks(videoPath)).tracks;
}

/// 视频同目录的外挂字幕扩展名（小写比较）。
const Set<String> _externalSubtitleExtensions = <String>{
  '.srt',
  '.ass',
  '.ssa',
  '.vtt',
};

/// **纯函数**：从目录文件名列表 [dirFiles] 中挑出与 [videoBaseNoExt] **同前缀**的
/// 外挂字幕文件名（大小写不敏感），返回原始文件名。
///
/// 「同前缀」= 文件名（小写）以 `<videoBaseNoExt>` 开头，且扩展名 ∈
/// {srt,ass,ssa,vtt}。即 `S01E01.mkv`（base=`S01E01`）只挑 `S01E01.srt` /
/// `S01E01.ja.srt` / `S01E01.en.srt`，**不挑** `S01E02.ja.srt`。这样换集/同目录混放
/// 多集字幕时，字幕菜单只列当前集的字幕，不被别集刷屏。
///
/// [langCode] 是 app 目标学习语言代码（如 `'ja'`）。**列全部同名字幕不变**，但带该
/// 语言标记 `.<langCode>.` 的字幕排在前（稳定排序：组内保持 [dirFiles] 原序），让
/// 菜单第一项是学习语言对应的字幕。
///
/// 不碰文件系统，可单测。
List<String> pickSameNameSubs(
  String videoBaseNoExt,
  List<String> dirFiles, {
  required String langCode,
}) {
  final String baseLower = videoBaseNoExt.toLowerCase();
  final String langMarker = '.${langCode.toLowerCase()}.';
  final List<String> langFirst = <String>[];
  final List<String> rest = <String>[];
  for (final String name in dirFiles) {
    final String nameLower = name.toLowerCase();
    if (!nameLower.startsWith(baseLower)) continue;
    final String ext = p.extension(nameLower);
    if (!_externalSubtitleExtensions.contains(ext)) continue;
    if (nameLower.contains(langMarker)) {
      langFirst.add(name);
    } else {
      rest.add(name);
    }
  }
  return <String>[...langFirst, ...rest];
}

/// **纯函数**：换集时按「同类偏好」从新集可用字幕源 [sources] 里挑一个。
///
/// [lastPersisted] 是上一集持久化的字幕源（外挂路径 / `embedded:<n>` / null）。
/// 规则：
/// - null（无偏好）→ 返回 null（调用方走默认 sidecar 检测）。
/// - `embedded:<n>` → 优先新集同 streamIndex 的内嵌轨；无则回退第一个内嵌轨；
///   无内嵌轨则 null。
/// - 外挂路径 → 取其语言/扩展名后缀（如 `.ja.srt` / `.ass`），优先新集同后缀的
///   外挂源；无同后缀则回退新集第一个外挂源；无外挂源则 null。
///
/// 不碰文件系统，可单测。
SubtitleSource? pickEpisodeSubtitleSource(
  String? lastPersisted,
  List<SubtitleSource> sources,
) {
  if (lastPersisted == null || lastPersisted.isEmpty) return null;
  if (sources.isEmpty) return null;

  final List<SubtitleSource> embedded =
      sources.where((SubtitleSource s) => s.isEmbedded).toList();
  final List<SubtitleSource> external =
      sources.where((SubtitleSource s) => !s.isEmbedded).toList();

  if (lastPersisted.startsWith(SubtitleSource.embeddedPrefix)) {
    final int? wantIndex = int.tryParse(
      lastPersisted.substring(SubtitleSource.embeddedPrefix.length),
    );
    for (final SubtitleSource s in embedded) {
      if (s.streamIndex == wantIndex) return s;
    }
    return embedded.isNotEmpty ? embedded.first : null;
  }

  // 外挂偏好：按「语言+扩展名」后缀匹配（去掉同名 base 前缀后剩下的尾巴）。
  final String wantSuffix = _externalSubtitleSuffix(lastPersisted);
  for (final SubtitleSource s in external) {
    if (_externalSubtitleSuffix(s.externalPath!) == wantSuffix) return s;
  }
  return external.isNotEmpty ? external.first : null;
}

/// 取外挂字幕路径的「语言+扩展名」后缀（小写），用于换集同类匹配。
///
/// `S01E01.ja.srt` → `.ja.srt`；`S01E01.ass` → `.ass`。规则：basename 去掉首个
/// `.` 之前的主名后剩下的全部（含中间语言段），保证 `.ja.srt` 与 `.srt` 区分开。
String _externalSubtitleSuffix(String path) {
  final String name = p.basename(path).toLowerCase();
  final int firstDot = name.indexOf('.');
  if (firstDot < 0) return '';
  return name.substring(firstDot);
}

/// 枚举 [videoPath] 的全部字幕源：① 内嵌轨 ② 同目录**同名前缀**外挂字幕文件。
///
/// 返回合并列表（内嵌在前，外挂在后）。外挂只收与视频同 basename（去扩展名）前缀的
/// srt/ass/ssa/vtt（含 `.ja.srt` 等带语言后缀），见 [pickSameNameSubs]——别集字幕
/// 不列。[langCode] 是 app 学习语言代码，让带该语言标记的外挂字幕排在前。目录读取
/// 失败时只返回内嵌部分。
Future<SubtitleSourceListing> listAllSubtitleSourcesWithDiagnostics(
  String videoPath, {
  required String langCode,
}) async {
  final List<SubtitleSource> sources = <SubtitleSource>[];

  // ① 内嵌轨。
  final EmbeddedSubtitleTrackProbeResult embeddedProbe =
      await probeEmbeddedSubtitleTracks(videoPath);
  for (final EmbeddedSubtitleTrack track in embeddedProbe.tracks) {
    sources.add(SubtitleSource.embedded(
      streamIndex: track.streamIndex,
      language: track.language,
      codec: track.codec,
      label: embeddedSubtitleTrackLabel(track),
    ));
  }

  // ② 同目录、与当前视频同名前缀的外挂字幕文件。
  final String dir = p.dirname(videoPath);
  final String videoBaseNoExt = p.basenameWithoutExtension(videoPath);
  final Directory directory = Directory(dir);
  if (directory.existsSync()) {
    try {
      final List<String> dirFiles = directory
          .listSync(followLinks: false)
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .toList();
      for (final String name
          in pickSameNameSubs(videoBaseNoExt, dirFiles, langCode: langCode)) {
        sources.add(SubtitleSource.external(
          externalPath: p.normalize(p.join(dir, name)),
          label: name,
        ));
      }
    } on FileSystemException {
      // 目录读取失败：只保留内嵌部分。
    }
  }

  return SubtitleSourceListing(
    sources: sources,
    embeddedProbe: embeddedProbe,
  );
}

Future<List<SubtitleSource>> listAllSubtitleSources(
  String videoPath, {
  required String langCode,
}) async {
  return (await listAllSubtitleSourcesWithDiagnostics(
    videoPath,
    langCode: langCode,
  ))
      .sources;
}

typedef SubtitleCueLoader = Future<List<AudioCue>> Function(
  SubtitleSource source,
  String videoPath,
  String bookUid,
);

/// Adds the currently persisted imported subtitle to a menu source list.
///
/// [listAllSubtitleSources] intentionally sees only embedded tracks and sidecar
/// files next to [videoPath]. User-imported subtitles live in app documents, so
/// the menu needs this one explicit persisted path. It never scans the import
/// directory and never adds unrelated historical imports.
///
/// The current persisted import is placed before enumerated tracks. The subtitle
/// sheet has a capped viewport; appending after embedded tracks can keep the
/// active import below the initially visible menu items after reopening.
Future<List<SubtitleSource>> includeCurrentPersistedSubtitleForMenu(
  List<SubtitleSource> sources, {
  required String videoPath,
  required String bookUid,
  required String? currentSubtitleSource,
  List<AudioCue> currentCues = const <AudioCue>[],
  SubtitleCueLoader? loadCues,
}) async {
  final List<SubtitleSource> result = List<SubtitleSource>.of(sources);
  if (currentSubtitleSource == null ||
      !isImportedExternalSubtitlePath(currentSubtitleSource) ||
      !File(currentSubtitleSource).existsSync()) {
    return result;
  }

  if (result.any((SubtitleSource source) =>
      sameExternalSubtitlePathForMenu(source, currentSubtitleSource))) {
    return result;
  }

  final SubtitleSource source = SubtitleSource.external(
    externalPath: currentSubtitleSource,
    label: p.basename(currentSubtitleSource),
  );
  final bool hasUsableCues = currentCues.isNotEmpty ||
      (await (loadCues ?? loadCuesForSource)(source, videoPath, bookUid))
          .isNotEmpty;
  if (!hasUsableCues) return result;

  return <SubtitleSource>[source, ...result];
}

bool subtitleSourceMatchesPersistedForMenu(
  SubtitleSource source,
  String? currentSubtitleSource,
) {
  if (source.matchesPersisted(currentSubtitleSource)) return true;
  if (currentSubtitleSource == null ||
      !isImportedExternalSubtitlePath(currentSubtitleSource)) {
    return false;
  }
  return sameExternalSubtitlePathForMenu(source, currentSubtitleSource);
}

bool sameExternalSubtitlePathForMenu(
  SubtitleSource source,
  String currentSubtitleSource,
) {
  if (source.isEmbedded || source.externalPath == null) return false;
  return _subtitleMenuPathKey(source.externalPath!) ==
      _subtitleMenuPathKey(currentSubtitleSource);
}

SubtitleSource? firstTextEmbeddedSubtitleSource(
  Iterable<SubtitleSource> sources,
) {
  for (final SubtitleSource source in sources) {
    if (!source.isEmbedded) continue;
    if (subtitleFormatForCodec(source.codec ?? '') != null) return source;
  }
  return null;
}

String _subtitleMenuPathKey(String path) {
  final String key = p.canonicalize(path);
  return Platform.isWindows ? key.toLowerCase() : key;
}

/// 内嵌轨菜单标签：`内封 N: lang / title / codec`（lang、title 缺省各自省略）。
///
/// title 取自轨 metadata（mkv `title` / mp4 `handler_name`），有则纳入显示，
/// 拼接顺序与远端 `_remoteEmbeddedSubtitleLabel`（lang / title / codec）一致。
///
/// 用「内封」而非「内嵌」：容器内封装的软字幕（mkv/mp4 的字幕流）业界叫**内封**；
/// 「内嵌」在字幕圈指烧进画面像素的硬字幕。早先误用「内嵌」会让用户误判（BUG-122）。
@visibleForTesting
String embeddedSubtitleTrackLabel(EmbeddedSubtitleTrack track) {
  final List<String> parts = <String>[
    if ((track.language ?? '').isNotEmpty) track.language!,
    if ((track.title ?? '').isNotEmpty) track.title!,
    track.codec,
  ];
  return '内封 ${track.streamIndex}: ${parts.join(' / ')}';
}

/// 加载某字幕源为 cue 列表。
///
/// - 内嵌源：ffmpeg `-map 0:s:N` 抽到临时文件 → [readTextWithEncoding] →
///   按 codec 路由 parser。图形字幕（codec 无文本格式）返回空。
/// - 外挂源：[readTextWithEncoding] 读文件 → 按扩展名路由 parser。
///
/// 任一步失败（ffmpeg 缺失 / 文件读不出 / 格式不支持）返回空列表，不抛。
Future<List<AudioCue>> loadCuesForSource(
  SubtitleSource source,
  String videoPath,
  String bookUid,
) async {
  if (source.isEmbedded) {
    return _loadEmbeddedCues(source, videoPath, bookUid);
  }
  return _loadExternalCues(source, bookUid);
}

Future<DefaultEmbeddedSubtitleLoadResult> loadDefaultTextEmbeddedSubtitleCues({
  required String videoPath,
  required String bookUid,
  String langCode = 'ja',
}) async {
  final SubtitleSourceListing listing =
      await listAllSubtitleSourcesWithDiagnostics(
    videoPath,
    langCode: langCode,
  );
  final EmbeddedSubtitleTrackProbeResult probe = listing.embeddedProbe;
  if (probe.status == EmbeddedSubtitleTrackProbeStatus.missingFile) {
    return DefaultEmbeddedSubtitleLoadResult(
      status: DefaultEmbeddedSubtitleLoadStatus.missingFile,
      cues: const <AudioCue>[],
      embeddedProbe: probe,
    );
  }
  if (probe.status == EmbeddedSubtitleTrackProbeStatus.timeout &&
      probe.tracks.isEmpty) {
    return DefaultEmbeddedSubtitleLoadResult(
      status: DefaultEmbeddedSubtitleLoadStatus.enumerationTimeout,
      cues: const <AudioCue>[],
      embeddedProbe: probe,
    );
  }
  if ((probe.status == EmbeddedSubtitleTrackProbeStatus.failed ||
          probe.status == EmbeddedSubtitleTrackProbeStatus.ffmpegUnavailable) &&
      probe.tracks.isEmpty) {
    return DefaultEmbeddedSubtitleLoadResult(
      status: DefaultEmbeddedSubtitleLoadStatus.enumerationFailed,
      cues: const <AudioCue>[],
      embeddedProbe: probe,
    );
  }

  final bool hasEmbedded =
      listing.sources.any((SubtitleSource source) => source.isEmbedded);
  if (!hasEmbedded) {
    return DefaultEmbeddedSubtitleLoadResult(
      status: DefaultEmbeddedSubtitleLoadStatus.noEmbeddedTracks,
      cues: const <AudioCue>[],
      embeddedProbe: probe,
    );
  }

  final SubtitleSource? chosen =
      firstTextEmbeddedSubtitleSource(listing.sources);
  if (chosen == null) {
    return DefaultEmbeddedSubtitleLoadResult(
      status: DefaultEmbeddedSubtitleLoadStatus.noTextTrack,
      cues: const <AudioCue>[],
      embeddedProbe: probe,
    );
  }

  final List<AudioCue> cues = await loadCuesForSource(
    chosen,
    videoPath,
    bookUid,
  );
  if (cues.isEmpty) {
    return DefaultEmbeddedSubtitleLoadResult(
      status: DefaultEmbeddedSubtitleLoadStatus.emptyCues,
      source: chosen,
      cues: const <AudioCue>[],
      embeddedProbe: probe,
    );
  }
  return DefaultEmbeddedSubtitleLoadResult(
    status: DefaultEmbeddedSubtitleLoadStatus.loaded,
    source: chosen,
    cues: cues,
    embeddedProbe: probe,
  );
}

Future<List<AudioCue>> _loadEmbeddedCues(
  SubtitleSource source,
  String videoPath,
  String bookUid,
) async {
  final SubtitleFormat? format = subtitleFormatForCodec(source.codec ?? '');
  if (format == null) return const <AudioCue>[];

  // BUG-104: extracting one embedded subtitle out of a multi-GB interleaved
  // container costs a full read of the file (~20s for a 27GB BluRay REMUX),
  // with no UI feedback the user reads as "switching didn't work". Pay that read
  // **once** by demuxing all text tracks into a per-video cache the first time
  // any track is needed; every later switch is an instant cached-file read.
  final int index = source.streamIndex!;
  final Directory cacheDir = embeddedSubtitleCacheDir(videoPath);
  final File cached = File(p.join(cacheDir.path, 'sub_$index${_ext(format)}'));

  if (!(cached.existsSync() && cached.lengthSync() > 0)) {
    await _ensureAllEmbeddedSubtitlesExtracted(videoPath, cacheDir);
  }
  if (!(cached.existsSync() && cached.lengthSync() > 0)) {
    return const <AudioCue>[];
  }
  try {
    final String text = await readTextWithEncoding(cached);
    return await parseSubtitleContentAsync(
      format,
      content: text,
      bookUid: bookUid,
    );
  } catch (_) {
    return const <AudioCue>[];
  }
}

/// Pre-extracts text embedded subtitle tracks for [videoPath] into the shared
/// cache without parsing or applying cues.
///
/// Callers should fire-and-forget this after video load. It reuses the same
/// in-flight extraction as manual switching, so a user selecting a subtitle
/// while prewarm is still running waits for that task instead of launching a
/// second full-container read. Failures are swallowed: manual switching keeps
/// the existing fallback path and user-facing load failure message.
Future<void> prewarmEmbeddedSubtitleCache(String videoPath) async {
  try {
    await _ensureAllEmbeddedSubtitlesExtracted(
      videoPath,
      embeddedSubtitleCacheDir(videoPath),
    );
  } catch (e, stack) {
    debugPrint('[VideoSubtitleSource] embedded subtitle prewarm failed: '
        '$e\n$stack');
  }
}

/// In-flight extract-all futures keyed by cache dir, so two near-simultaneous
/// switches (or initial load + a quick switch) don't both re-demux the file.
Future<File?> extractEmbeddedSubtitleTrackFile({
  required String videoPath,
  required int streamIndex,
  required String codec,
}) async {
  final SubtitleFormat? format = subtitleFormatForCodec(codec);
  if (format == null) return null;
  final Directory cacheDir = embeddedSubtitleCacheDir(videoPath);
  final File cached = File(
    p.join(
      cacheDir.path,
      'sub_$streamIndex${subtitleExtensionForFormat(format)}',
    ),
  );
  if (!(cached.existsSync() && cached.lengthSync() > 0)) {
    await _ensureAllEmbeddedSubtitlesExtracted(videoPath, cacheDir);
  }
  return cached.existsSync() && cached.lengthSync() > 0 ? cached : null;
}

final Map<String, Future<void>> _embeddedExtractInFlight =
    <String, Future<void>>{};

/// Ensures every text embedded subtitle track of [videoPath] is demuxed into
/// [cacheDir] (single ffmpeg pass). Idempotent and de-duplicated across
/// concurrent callers. Returns when extraction finished (or immediately if a
/// peer call is already doing it).
Future<void> _ensureAllEmbeddedSubtitlesExtracted(
  String videoPath,
  Directory cacheDir,
) {
  final String key = cacheDir.path;
  final Future<void>? existing = _embeddedExtractInFlight[key];
  if (existing != null) return existing;
  final Future<void> fut =
      _extractAllEmbeddedSubtitles(videoPath, cacheDir).whenComplete(() {
    _embeddedExtractInFlight.remove(key);
  });
  _embeddedExtractInFlight[key] = fut;
  return fut;
}

Future<void> _extractAllEmbeddedSubtitles(
  String videoPath,
  Directory cacheDir,
) async {
  final List<EmbeddedSubtitleTrack> tracks =
      await listEmbeddedSubtitleTracks(videoPath);
  // Only text tracks (graphic pgs/dvd → null format) get extracted; cache file
  // name carries the parser-deciding extension.
  final Map<int, String> outputs = <int, String>{};
  for (final EmbeddedSubtitleTrack track in tracks) {
    final SubtitleFormat? fmt = subtitleFormatForCodec(track.codec);
    if (fmt == null) continue;
    final String outputPath =
        p.join(cacheDir.path, 'sub_${track.streamIndex}${_ext(fmt)}');
    final File cached = File(outputPath);
    if (cached.existsSync() && cached.lengthSync() > 0) continue;
    outputs[track.streamIndex] = outputPath;
  }
  if (outputs.isEmpty) return;
  try {
    cacheDir.createSync(recursive: true);
  } catch (_) {
    return;
  }
  await extractEmbeddedSubtitlesViaFfmpeg(
    inputPath: videoPath,
    outputs: outputs,
    timeout: subtitleExtractTimeoutForBytes(_fileSizeOrZero(videoPath)),
  );
}

int _fileSizeOrZero(String path) {
  try {
    return File(path).lengthSync();
  } catch (_) {
    return 0;
  }
}

/// **Pure**: the on-disk cache key for a video's extracted embedded subtitles.
///
/// Keyed by base name + byte size + mtime millis so replacing a file in place
/// (same path, new content) misses the stale cache. Non-`[A-Za-z0-9_.-]` chars
/// in the base name are collapsed to `_` to stay a valid directory segment.
@visibleForTesting
String embeddedSubtitleCacheKey(
  String videoBaseNoExt,
  int sizeBytes,
  int mtimeMs,
) {
  final String safe =
      videoBaseNoExt.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  return '${safe}_${sizeBytes}_$mtimeMs';
}

/// The cache directory (under the OS temp dir) holding [videoPath]'s extracted
/// embedded subtitle tracks. Stat failures fall back to a path-only key.
Directory embeddedSubtitleCacheDir(String videoPath) {
  final String base = p.basenameWithoutExtension(videoPath);
  int size = 0;
  int mtimeMs = 0;
  try {
    final FileStat stat = File(videoPath).statSync();
    size = stat.size;
    mtimeMs = stat.modified.millisecondsSinceEpoch;
  } catch (_) {
    // statSync failed (deleted/locked): fall back to a stable path hash so we
    // still cache within the session.
    mtimeMs = videoPath.hashCode;
  }
  final String key = embeddedSubtitleCacheKey(base, size, mtimeMs);
  return Directory(
    p.join(Directory.systemTemp.path, 'hibiki_vsub_cache', key),
  );
}

/// **Pure**: how long to allow a single extract-all pass given the container's
/// byte size. The read time of an interleaved container grows with its size, so
/// a fixed 30s timeout silently fails on big REMUX files (and worse under
/// playback I/O contention). Base 60s + 8s/GB, clamped to [60s, 1200s]: a 27GB
/// REMUX gets ~276s of headroom instead of timing out at 30s (BUG-104).
@visibleForTesting
Duration subtitleExtractTimeoutForBytes(int sizeBytes) {
  final double gb = sizeBytes / (1024 * 1024 * 1024);
  final int seconds = (60 + gb * 8).clamp(60, 1200).round();
  return Duration(seconds: seconds);
}

Future<List<AudioCue>> _loadExternalCues(
  SubtitleSource source,
  String bookUid,
) async {
  final String path = source.externalPath!;
  final SubtitleFormat? format = subtitleFormatForPath(path);
  if (format == null) return const <AudioCue>[];
  try {
    final String text = await readTextWithEncoding(File(path));
    return await parseSubtitleContentAsync(
      format,
      content: text,
      bookUid: bookUid,
    );
  } catch (_) {
    return const <AudioCue>[];
  }
}

/// 临时抽字幕文件的扩展名（让 ffmpeg 按扩展名选输出 muxer）。
String _ext(SubtitleFormat format) {
  return subtitleExtensionForFormat(format);
}
