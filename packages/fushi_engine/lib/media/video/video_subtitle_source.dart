import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/strm_file.dart'
    show lacksLocalMediaFile;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/subtitle/plain_subtitle_overlap.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_target.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart'
    show isSidecarSubtitleSuffix, rankSidecarSubtitles;
import 'package:fushi_engine/platform/media_disk_identity.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:meta/meta.dart';

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
    this.audioLanguages = const <String>[],
  });

  final List<EmbeddedSubtitleTrack> tracks;

  /// 同一次 `ffmpeg -i` 里各音轨声明的语言（按出现顺序，去掉没写 / `und`）。挑字幕
  /// 时语言链全空的最后一条证据（[audioSubtitleLanguageTarget]），不另起进程。
  final List<String> audioLanguages;
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

/// 匹配 `Stream #0:N(lang): Audio:` 行，取括号里的语言。
final RegExp _audioStreamPattern = RegExp(
  r'Stream #\d+:\d+(?:\[0x[0-9a-fA-F]+\])?\(([^)]+)\): Audio:',
);

/// **纯函数**：`ffmpeg -i` stderr 里各音轨声明的语言（按出现顺序；没写语言的轨、
/// `und` 跳过）。
List<String> parseAudioStreamLanguagesFromFfmpegLog(String ffmpegStderr) =>
    <String>[
      for (final String line in const LineSplitter().convert(ffmpegStderr))
        if (_audioStreamPattern.firstMatch(line)?.group(1)?.trim()
            case final String lang
            when lang.isNotEmpty && lang.toLowerCase() != 'und')
          lang,
    ];

/// 语言链全空时，从音轨语言推挑字幕的目标：第一条认得出语言的音轨。认不出 / 没有
/// 音轨语言返回 null（不猜）。
SubtitleLanguageTarget? audioSubtitleLanguageTarget(
  List<String> audioLanguages,
) {
  for (final String lang in audioLanguages) {
    final SubtitleLanguageTarget? target = SubtitleLanguageTarget.parse(lang);
    if (target != null) return target;
  }
  return null;
}

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
    tracks.add(
      EmbeddedSubtitleTrack(
        streamIndex: relativeIndex,
        codec: codec,
        language: language,
        title: title,
      ),
    );
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
    final RegExpMatch? handlerMatch = _metadataHandlerNamePattern.firstMatch(
      line,
    );
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
  if (SubtitleSource.isHostSidecarPersisted(persisted)) return false;
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

///
/// SRT / VTT 的部分重叠在这里收口（[clampPlainTextCueOverlaps]，拍板台 0jnNr_P5Rd：
/// 重叠的纯文本句子在 overlay 槽位里上下交替跳）；ASS 原样保留。
List<AudioCue> parseSubtitleContent(
  SubtitleFormat format, {
  required String content,
  required String bookUid,
  bool includeDrawings = false,
}) {
  // AudioCue is keyed by `bookKey` (name-PK rename); a video book's owner key
  // for its cues is its own book_uid, so pass bookUid as the cue's bookKey.
  switch (format) {
    case SubtitleFormat.srt:
      return clampPlainTextCueOverlaps(
        SrtParser.parseString(content: content, bookKey: bookUid),
      );
    case SubtitleFormat.ass:
      return AssParser.parseString(
        content: content,
        bookKey: bookUid,
        includeDrawings: includeDrawings,
      );
    case SubtitleFormat.vtt:
      return clampPlainTextCueOverlaps(
        VttParser.parseString(content: content, bookKey: bookUid),
      );
  }
}

/// 纯函数（B：浏览器扩展加载外挂字幕文件）：把用户上传的字幕文件（按 [filename] 扩展名判
/// 格式）解析成扩展面板可消费的 cue JSON `{format, cues:[{text,startMs,endMs}]}`。复用 app
/// 内已测的 SRT/ASS/VTT parser（`parseSubtitleContent` 无 IO）。不支持的扩展名返回
/// `{error:'unsupported', cues:[]}`（不抛，扩展侧提示格式不支持）。
Map<String, dynamic> buildParsedSubtitleResponse({
  required String filename,
  required String content,
}) {
  final SubtitleFormat? format = subtitleFormatForPath(filename);
  if (format == null) {
    return <String, dynamic>{'error': 'unsupported', 'cues': <dynamic>[]};
  }
  final List<AudioCue> cues = parseSubtitleContent(
    format,
    content: content,
    bookUid: 'ext',
  );
  return <String, dynamic>{
    'format': format.name,
    'cues': <Map<String, dynamic>>[
      for (final AudioCue c in cues)
        <String, dynamic>{
          'text': c.text,
          'startMs': c.startMs,
          'endMs': c.endMs,
        },
    ],
  };
}

/// 异步版 [parseSubtitleContent]，重叠收口语义相同。
///
/// 解析与解析后的整轨处理（SRT / VTT 的复制 + 排序 + 重叠收口，
/// [clampPlainTextCueOverlaps]）是**同一个任务**：大内容（超过
/// [SrtParser.shouldParseInIsolate] 的阈值）整个在后台 isolate 里做完才回来，调用方
/// isolate（播放器页面 = UI isolate）只收结果。此前只把 parser 本体派到后台，回来后
/// 在调用方 isolate 上复制整表、排序、再走一遍重叠收口——大字幕轨首帧 / 切轨时这段
/// O(n log n) 的整轨处理又回到了 UI isolate（HBK-AUDIT-012）。
Future<List<AudioCue>> parseSubtitleContentAsync(
  SubtitleFormat format, {
  required String content,
  required String bookUid,
  bool includeDrawings = false,
}) async {
  final List<AudioCue> Function() parse = _subtitleContentParseTask(
    format,
    content: content,
    bookUid: bookUid,
    includeDrawings: includeDrawings,
  );
  if (SrtParser.shouldParseInIsolate(content)) {
    return Isolate.run(parse, debugName: 'parseSubtitleContent');
  }
  return parse();
}

/// [parseSubtitleContentAsync] 的整轨任务：只捕获不可变入参（跨 isolate 发送），
/// 放在非 async 函数里建闭包，免得把 async 帧的上下文一并带过去。
List<AudioCue> Function() _subtitleContentParseTask(
  SubtitleFormat format, {
  required String content,
  required String bookUid,
  required bool includeDrawings,
}) =>
    () => parseSubtitleContent(
      format,
      content: content,
      bookUid: bookUid,
      includeDrawings: includeDrawings,
    );

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
  }) : isEmbedded = true,
       externalPath = null;

  const SubtitleSource.external({
    required String this.externalPath,
    required this.label,
  }) : isEmbedded = false,
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

  /// 远端播放选中「互联 host 上某一条外挂字幕」的持久化编码前缀：
  /// `hostsidecar:<host 上的文件名>`（反馈 -CaVsioFhG）。它不是本机文件路径——
  /// 重进时按文件名向 host 重新下载（`GET .../subtitle?sidecar=`），不能当路径读。
  static const String hostSidecarPrefix = 'hostsidecar:';

  /// 持久化值 [persisted] 是否是 [hostSidecarPrefix] 编码。
  static bool isHostSidecarPersisted(String? persisted) =>
      persisted != null && persisted.startsWith(hostSidecarPrefix);

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

  /// 持久化值 [persisted] 是否代表**内嵌字幕轨**（`embedded:<n>`，见 [embeddedPrefix]）。
  /// `null`（旧数据/无偏好）、外挂绝对路径、关闭哨兵 [offSentinel] 均返回 false
  /// （TODO-1246：单视频重开内嵌轨样式重解析的判据）。
  static bool isEmbeddedPersisted(String? persisted) =>
      persisted != null && persisted.startsWith(embeddedPrefix);

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
    this.cueFailure,
  });

  final DefaultEmbeddedSubtitleLoadStatus status;
  final List<AudioCue> cues;
  final EmbeddedSubtitleTrackProbeResult embeddedProbe;
  final SubtitleSource? source;

  /// [DefaultEmbeddedSubtitleLoadStatus.emptyCues] 时选中轨加载失败的真实原因
  /// （抽取卡住 / 抽取失败 / 读不出 / 解析不出…），日志与提示按它分流（BUG-4838）。
  final SubtitleCueLoadFailure? cueFailure;

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
///
/// BUG-4838：`emptyCues`（枚举已成功、选中轨也已经过一次整轨抽取 / 解析）**不是**
/// 瞬态：抽取按进度判活，慢盘上的抽取会一直跑到读完，失败只剩真失败（ffmpeg 卡住 /
/// 坏轨 / 解析不出），再起一次只是把整个容器再读一遍、把一次失败放大成两次。
bool isTransientDefaultEmbeddedSubtitleLoad(
  DefaultEmbeddedSubtitleLoadStatus status,
) {
  switch (status) {
    case DefaultEmbeddedSubtitleLoadStatus.enumerationTimeout:
    case DefaultEmbeddedSubtitleLoadStatus.enumerationFailed:
      return true;
    case DefaultEmbeddedSubtitleLoadStatus.emptyCues:
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
///
/// [cancel] 交给默认加载（[loadDefaultTextEmbeddedSubtitleCues]）的整轨抽取：播放器
/// 换片 / 销毁时完成（注入 [loadOnce] 的测试不经过它）。[onExtractionStarted] 同样原样
/// 交给默认加载。
Future<DefaultEmbeddedSubtitleLoadResult>
loadDefaultTextEmbeddedSubtitleCuesWithReadinessRetry({
  required String videoPath,
  required String bookUid,
  required Future<void> Function() waitForReady,
  required bool Function() isStillCurrent,
  String langCode = '',
  List<String> preferredLanguages = const <String>[],
  Future<void>? cancel,
  void Function(SubtitleSource chosen)? onExtractionStarted,
  Future<DefaultEmbeddedSubtitleLoadResult> Function({
    required String videoPath,
    required String bookUid,
    String langCode,
    List<String> preferredLanguages,
  })?
  loadOnce,
}) async {
  final Future<DefaultEmbeddedSubtitleLoadResult> Function({
    required String videoPath,
    required String bookUid,
    String langCode,
    List<String> preferredLanguages,
  })
  load =
      loadOnce ??
      ({
        required String videoPath,
        required String bookUid,
        String langCode = '',
        List<String> preferredLanguages = const <String>[],
      }) => loadDefaultTextEmbeddedSubtitleCues(
        videoPath: videoPath,
        bookUid: bookUid,
        langCode: langCode,
        preferredLanguages: preferredLanguages,
        cancel: cancel,
        onExtractionStarted: onExtractionStarted,
      );

  DefaultEmbeddedSubtitleLoadResult result = await load(
    videoPath: videoPath,
    bookUid: bookUid,
    langCode: langCode,
    preferredLanguages: preferredLanguages,
  );
  if (!isStillCurrent()) return result;
  if (!isTransientDefaultEmbeddedSubtitleLoad(result.status)) return result;

  await waitForReady();
  if (!isStillCurrent()) return result;
  result = await load(
    videoPath: videoPath,
    bookUid: bookUid,
    langCode: langCode,
    preferredLanguages: preferredLanguages,
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
  // 一次 async stat 同时拿体积与存在性：互联 host 的 streamurl / 内封字幕端点在 app
  // 主 isolate 上调这里，视频常在网络盘上，同步 stat 会冻结全部端点与 UI（BUG-3756）。
  // 没有本机媒体字节的路径（网络流 / `.strm` / DVD title）不碰文件系统、按缺失处理
  // （video_member_file.dart 第 2 种问法）。
  final FileStat? videoStat = lacksLocalMediaFile(videoPath)
      ? null
      : await _regularFileStat(videoPath);
  final int sizeBytes = videoStat?.size ?? 0;
  final Duration timeout = subtitleExtractTimeoutForBytes(sizeBytes);
  if (videoStat == null) {
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
    final FfmpegRunResult result = await resolveFfmpegBackend().run(<String>[
      '-hide_banner',
      '-i',
      videoPath,
    ], timeout);
    final List<EmbeddedSubtitleTrack> tracks =
        parseSubtitleStreamsFromFfmpegLog(result.output);
    final List<String> audioLanguages = parseAudioStreamLanguagesFromFfmpegLog(
      result.output,
    );
    // 真正失败（超时 SIGKILL → returnCode:null）必须留痕，否则「0 条字幕」与
    // 「真无字幕」无从区分，整类静默失败不可调试。不抛，保持优雅降级契约。
    if (result.returnCode == null) {
      fushiDebugPrint(
        '[VideoSubtitleSource] embedded enumeration timed out for "$videoPath" '
        '(size=$sizeBytes bytes) — menu will show no '
        'embedded subtitles this time',
      );
      return EmbeddedSubtitleTrackProbeResult(
        tracks: tracks,
        status: EmbeddedSubtitleTrackProbeStatus.timeout,
        timeout: timeout,
        sizeBytes: sizeBytes,
        audioLanguages: audioLanguages,
      );
    }
    if (result.returnCode != 0 && result.output.trim().isEmpty) {
      fushiDebugPrint(
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
      audioLanguages: audioLanguages,
    );
  } on ProcessException catch (e) {
    // ffmpeg 未安装：优雅降级为无内嵌字幕。
    fushiDebugPrint('[VideoSubtitleSource] ffmpeg unavailable: $e');
    return EmbeddedSubtitleTrackProbeResult(
      tracks: const <EmbeddedSubtitleTrack>[],
      status: EmbeddedSubtitleTrackProbeStatus.ffmpegUnavailable,
      timeout: timeout,
      sizeBytes: sizeBytes,
    );
  } catch (e, stack) {
    fushiDebugPrint(
      '[VideoSubtitleSource] embedded enumeration failed: $e\n$stack',
    );
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
/// [langCode] 是本视频的目标语言标签（`ja` / `zh-Hant` …，空串 = 未知）。**列全部
/// 同名字幕不变**，但会被自动加载的那些按自动加载的先后排在前
/// （[rankSidecarSubtitles]，与播放器起播挑的是同一条），其余保持 [dirFiles] 原序，
/// 让菜单第一项就是自动加载会选的那份。
///
/// 不碰文件系统，可单测。
List<String> pickSameNameSubs(
  String videoBaseNoExt,
  List<String> dirFiles, {
  required String langCode,
}) {
  final String baseLower = videoBaseNoExt.toLowerCase();
  final List<String> matches = <String>[
    for (final String name in dirFiles)
      if (name.toLowerCase().startsWith(baseLower) &&
          _externalSubtitleExtensions.contains(p.extension(name.toLowerCase())))
        name,
  ];
  final List<String> ranked = rankSidecarSubtitles(videoBaseNoExt, <String>[
    for (final String name in matches)
      if (isSidecarSubtitleSuffix(name.substring(videoBaseNoExt.length))) name,
  ], langCode: langCode);
  final Set<String> rankedSet = ranked.toSet();
  return <String>[
    ...ranked,
    for (final String name in matches)
      if (!rankedSet.contains(name)) name,
  ];
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

  final List<SubtitleSource> embedded = sources
      .where((SubtitleSource s) => s.isEmbedded)
      .toList();
  final List<SubtitleSource> external = sources
      .where((SubtitleSource s) => !s.isEmbedded)
      .toList();

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
/// 不列。[langCode] 是本视频的目标语言标签（见 [pickSameNameSubs]），让自动加载会选的
/// 外挂字幕排在前。目录读取失败时只返回内嵌部分。
Future<SubtitleSourceListing> listAllSubtitleSourcesWithDiagnostics(
  String videoPath, {
  required String langCode,
}) async {
  final List<SubtitleSource> sources = <SubtitleSource>[];

  // ① 内嵌轨。
  final EmbeddedSubtitleTrackProbeResult embeddedProbe =
      await probeEmbeddedSubtitleTracks(videoPath);
  for (final EmbeddedSubtitleTrack track in embeddedProbe.tracks) {
    sources.add(
      SubtitleSource.embedded(
        streamIndex: track.streamIndex,
        language: track.language,
        codec: track.codec,
        label: embeddedSubtitleTrackLabel(track),
      ),
    );
  }

  // ② 同目录、与当前视频同名前缀的外挂字幕文件。
  final String dir = p.dirname(videoPath);
  final String videoBaseNoExt = p.basenameWithoutExtension(videoPath);
  // async 列目录：视频目录常在网络盘上（BUG-3756）。目录不存在同样落进
  // FileSystemException 分支。
  try {
    final List<String> dirFiles = <String>[];
    await for (final FileSystemEntity e in Directory(
      dir,
    ).list(followLinks: false)) {
      if (e is File) dirFiles.add(p.basename(e.path));
    }
    for (final String name in pickSameNameSubs(
      videoBaseNoExt,
      dirFiles,
      langCode: langCode,
    )) {
      sources.add(
        SubtitleSource.external(
          externalPath: p.normalize(p.join(dir, name)),
          label: name,
        ),
      );
    }
  } on FileSystemException {
    // 目录读取失败：只保留内嵌部分。
  }

  return SubtitleSourceListing(sources: sources, embeddedProbe: embeddedProbe);
}

Future<List<SubtitleSource>> listAllSubtitleSources(
  String videoPath, {
  required String langCode,
}) async {
  return (await listAllSubtitleSourcesWithDiagnostics(
    videoPath,
    langCode: langCode,
  )).sources;
}

typedef SubtitleCueLoader =
    Future<List<AudioCue>> Function(
      SubtitleSource source,
      String videoPath,
      String bookUid,
    );

/// Adds the currently persisted imported subtitles to a menu source list.
///
/// [listAllSubtitleSources] intentionally sees only embedded tracks and sidecar
/// files next to [videoPath]. User-imported subtitles live in app documents, so
/// the menu needs these explicit persisted paths. It never scans the import
/// directory and never adds unrelated historical imports.
///
/// The current persisted imports are placed before enumerated tracks. The
/// subtitle sheet has a capped viewport; appending after embedded tracks can
/// keep the active import below the initially visible menu items after
/// reopening.
///
/// BUG-2094：**主字幕和副字幕各是一条独立的持久化指针，两条都要被补齐**。此前只补
/// [currentSubtitleSource] 一条，于是「只被选作副字幕的导入档」在重开视频后从列表里
/// 彻底消失：枚举按设计看不到 `<dataRoot>/documents/video_subtitles/`，本会话登记的
/// [mergeImportedSubtitleSourcesForMenu] 输入又按视频源作用域清空，而副字幕 cue 仍从
/// 库里重放——用户看到「副字幕没了，但视频里还在显示」，且副字幕组里没有任何一行是
/// 高亮的（当前源不在列表里）。这正是 BUG-1861 在主字幕那半已修掉的同一个洞。
/// 两条指针走**同一条**补齐规则（导入档 + 文件在盘上 + 能解析出 cue），用循环而不是
/// 主/副两套分支；主字幕排在副字幕前，与「当前主字幕最靠前」的既有约定一致。
Future<List<SubtitleSource>> includeCurrentPersistedSubtitleForMenu(
  List<SubtitleSource> sources, {
  required String videoPath,
  required String bookUid,
  required String? currentSubtitleSource,
  String? currentSecondarySubtitleSource,
  List<AudioCue> currentCues = const <AudioCue>[],
  List<AudioCue> currentSecondaryCues = const <AudioCue>[],
  SubtitleCueLoader? loadCues,
}) async {
  final List<SubtitleSource> result = List<SubtitleSource>.of(sources);
  final List<SubtitleSource> extras = <SubtitleSource>[];
  final List<(String?, List<AudioCue>)> persistedSelections =
      <(String?, List<AudioCue>)>[
        (currentSubtitleSource, currentCues),
        (currentSecondarySubtitleSource, currentSecondaryCues),
      ];

  for (final (String? persisted, List<AudioCue> cues) in persistedSelections) {
    if (persisted == null ||
        !isImportedExternalSubtitlePath(persisted) ||
        await _regularFileStat(persisted) == null) {
      continue;
    }
    // 已被枚举列出（视频同目录 sidecar）或已被另一条指针补进来（主副选同一档）
    // 都不重复列出——去重判据与列表高亮同一个（大小写 / 分隔符归一）。
    if (result.any(
          (SubtitleSource source) =>
              sameExternalSubtitlePathForMenu(source, persisted),
        ) ||
        extras.any(
          (SubtitleSource source) =>
              sameExternalSubtitlePathForMenu(source, persisted),
        )) {
      continue;
    }
    final SubtitleSource source = SubtitleSource.external(
      externalPath: persisted,
      label: p.basename(persisted),
    );
    final bool hasUsableCues =
        cues.isNotEmpty ||
        (await (loadCues ?? loadCuesForSource)(
          source,
          videoPath,
          bookUid,
        )).isNotEmpty;
    if (!hasUsableCues) continue;
    extras.add(source);
  }

  if (extras.isEmpty) return result;
  return <SubtitleSource>[...extras, ...result];
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
  return sameSubtitleFilePath(source.externalPath!, currentSubtitleSource);
}

/// **纯函数**：两个字幕文件路径是否指向同一个档案（大小写 / 分隔符 / `..` 归一）。
/// [sameExternalSubtitlePathForMenu] 的裸路径版，供尚未包成 [SubtitleSource] 的登记 /
/// 去重路径复用同一判据（BUG-1861）。
bool sameSubtitleFilePath(String a, String b) =>
    _subtitleMenuPathKey(a) == _subtitleMenuPathKey(b);

/// **纯函数**：[path] 是否是一个可以进字幕轨菜单的**外挂档案路径**，而不是源指针
/// （`embedded:<n>` 内封轨指针 / `off:` 显式关闭哨兵 / 空串）。
///
/// BUG-1861：这是「本会话落盘的档案」登记路径（`_registerImportedSubtitleSource`）的
/// 唯一过滤条件，**刻意不看扩展名**。登记的语义是「这个档案就在盘上、刚刚被应用」，
/// 而扩展名是 provider 给的：Jimaku / OpenSubtitles 的 `fileName` 只经
/// `safeSubtitleFileName` 防路径逃逸，不做白名单，`.sup` / `.smi` / `.ttml` 一样会落进
/// `<dataRoot>/documents/video_subtitles/`。拿扩展名当登记门 = 下完之后列表里连它的名字
/// 都看不到，用户只能猜自己有没有下成功——与「坏档也该列出来、不按应用成功门控」
/// （`_openJimakuDialog` / `_importExternalSubtitleInner` 的既有约定）自相矛盾。
///
/// 与 [isImportedExternalSubtitlePath] 是**两件事**，不要合并：那个判的是「一条**持久化
/// 值**是否可以按路径直接重放」，扩展名是它的必要条件（restore 时要真去解析这个档），
/// 消费方在 [shouldReusePersistedSubtitleAcrossEpisode] 与视频页的换集恢复链路上，保持
/// 不变。
bool isExternalSubtitleFilePathForMenu(String path) {
  if (path.trim().isEmpty) return false;
  if (path.startsWith(SubtitleSource.embeddedPrefix)) return false;
  if (SubtitleSource.isHostSidecarPersisted(path)) return false;
  if (SubtitleSource.isOff(path)) return false;
  return true;
}

/// **纯函数**：把「本次播放会话里落盘并应用过的外挂字幕档」[imported] 并进字幕轨菜单
/// 的枚举结果 [enumerated]，返回最终要渲染的列表（导入档排在前，与
/// [includeCurrentPersistedSubtitleForMenu] 的「当前导入排最前」约定一致）。
///
/// BUG-1861：这一层存在的理由是**枚举结果与「用户刚拿到的字幕档」是两件独立的事实**。
/// [listAllSubtitleSources] 按设计只看内封轨 + 视频同目录 sidecar；Jimaku 下载 / 手动
/// 导入的档案住在 `<dataRoot>/documents/video_subtitles/`，它永远枚举不到。而枚举本身
/// 会失败（ffprobe 不可用 / 超时）、会在途（大容器探测数秒到数十秒）、也会因换集而让
/// 缓存 key 失配。BUG-1329 把「并入新档」挂在「枚举缓存有效」这个前置条件上，于是上述
/// 三种情况下新档被**静默丢弃** —— 用户看到「字幕明明应用上了、列表里却没有它」。
///
/// 两份列表在渲染时合并（而不是把新档写进枚举缓存）：枚举缓存保持「纯枚举结果」语义，
/// 后到的枚举结果整体覆盖它时也不会把导入档冲掉。按路径去重（[sameSubtitleFilePath]），
/// 导入档若同时是视频同目录 sidecar（已在 [enumerated] 里）则不重复列出。
List<SubtitleSource> mergeImportedSubtitleSourcesForMenu(
  List<SubtitleSource> enumerated,
  List<SubtitleSource> imported,
) {
  if (imported.isEmpty) return enumerated;
  final List<SubtitleSource> extras = <SubtitleSource>[];
  for (final SubtitleSource source in imported) {
    final String? path = source.externalPath;
    if (path == null) continue;
    final bool listed =
        enumerated.any(
          (SubtitleSource s) => sameExternalSubtitlePathForMenu(s, path),
        ) ||
        extras.any(
          (SubtitleSource s) => sameExternalSubtitlePathForMenu(s, path),
        );
    if (listed) continue;
    extras.add(source);
  }
  if (extras.isEmpty) return enumerated;
  return <SubtitleSource>[...extras, ...enumerated];
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
/// 同时供本地 ffmpeg 探测与播放器实时轨道列表使用，保持菜单标签一致。
String embeddedSubtitleTrackLabel(EmbeddedSubtitleTrack track) {
  final List<String> parts = <String>[
    if ((track.language ?? '').isNotEmpty) track.language!,
    if ((track.title ?? '').isNotEmpty) track.title!,
    track.codec,
  ];
  return '内封 ${track.streamIndex}: ${parts.join(' / ')}';
}

/// 字幕 cue 加载失败的**原因**。
///
/// BUG-1490：原实现把「格式不支持」「图形轨」「ffmpeg 抽取失败」「文件读不出」
/// 「内容解析不出」五种完全不同的根因统统压成一个空 `List<AudioCue>`，UI 只能
/// 用同一句「可能是图形或不支持的字幕轨」兜底——对一个明明是文本 ASS 的文件，
/// 那句话是**错的**，把用户引向「换个字幕」而不是真正的问题。
enum SubtitleCueLoadFailure {
  /// 扩展名 / codec 不在受支持的文本字幕格式里（含图形轨如 PGS/VobSub）。
  unsupportedFormat,

  /// 内嵌轨需要 ffmpeg demux，但没抽出文件（ffmpeg 缺失 / 坏轨 / 本机 ffmpeg 解不了）。
  extractionFailed,

  /// 抽内嵌轨时读视频文件卡住：ffmpeg 的读取进度在卡死判据内没有推进（磁盘忙 /
  /// 网络盘断开 / 设备休眠）。与 [extractionFailed] 分开：轨本身没问题，问题在读盘。
  /// BUG-4838。
  extractionStalled,

  /// 抽取被调用方取消（离开播放页 / 换集）。结果本就作废，UI 侧按世代丢弃。
  extractionCancelled,

  /// 文件读不出来（不存在 / 无权限 / IO 错误）。
  fileUnreadable,

  /// 内容读到了，但解析不出任何 cue（结构损坏、空文件、解析器抛异常）。
  parseFailed,
}

/// 一次字幕 cue 加载的结果：要么拿到非空 cue，要么带一个明确的失败原因。
///
/// 不变式：`cues.isNotEmpty` ⇔ `failure == null`。
@immutable
class SubtitleCueLoadResult {
  const SubtitleCueLoadResult.loaded(this.cues) : failure = null;

  const SubtitleCueLoadResult.failed(SubtitleCueLoadFailure this.failure)
    : cues = const <AudioCue>[];

  final List<AudioCue> cues;
  final SubtitleCueLoadFailure? failure;

  bool get isFailure => failure != null;
}

/// 加载某字幕源为 cue 列表。
///
/// - 内嵌源：ffmpeg `-map 0:s:N` 抽到临时文件 → [readTextWithEncoding] →
///   按 codec 路由 parser。图形字幕（codec 无文本格式）返回空。
/// - 外挂源：[readTextWithEncoding] 读文件 → 按扩展名路由 parser。
///
/// 任一步失败（ffmpeg 缺失 / 文件读不出 / 格式不支持）返回空列表，不抛。
/// **需要区分失败原因（例如给用户不同文案）时用 [loadSubtitleCueResult]**；
/// 本函数只是它丢掉原因的薄封装，保留给不关心原因的调用方。
///
/// [cancel]：内嵌轨需要整轨抽取时，完成即退出等待；共享的抽取在所有可取消的等待方都
/// 撤走、且没有不可取消的等待方时才被强杀（见 [_ensureAllEmbeddedSubtitlesExtracted]）。
Future<List<AudioCue>> loadCuesForSource(
  SubtitleSource source,
  String videoPath,
  String bookUid, {
  Future<void>? cancel,
}) async {
  final SubtitleCueLoadResult result = await loadSubtitleCueResult(
    source,
    videoPath,
    bookUid,
    cancel: cancel,
  );
  return result.cues;
}

/// 同 [loadCuesForSource]，但**保留失败原因**（[SubtitleCueLoadFailure]）。不抛。
///
/// [onExtractionStarted]：内嵌轨缓存未命中、**真要去读整个容器**之前同步回调一次（缓存
/// 命中 / 外挂源不回调）。播放页据此在抽取期间先让播放器解码这条轨即时出字（整轨抽取在
/// 慢盘上要一分钟以上），抽完再换成完整 cue 列表。
Future<SubtitleCueLoadResult> loadSubtitleCueResult(
  SubtitleSource source,
  String videoPath,
  String bookUid, {
  Future<void>? cancel,
  void Function()? onExtractionStarted,
}) async {
  if (source.isEmbedded) {
    return _loadEmbeddedCues(
      source,
      videoPath,
      bookUid,
      cancel: cancel,
      onExtractionStarted: onExtractionStarted,
    );
  }
  return loadExternalSubtitleCueResult(source.externalPath!, bookUid);
}

/// 自动挑一条能转文本的内封轨抽成 cue。挑轨顺序：
/// 1. [preferredLanguages]（用户的主字幕默认语言，见 [parseSubtitleLanguagePreferences]，
///    反馈 Fz9HXThdSW）按其顺序第一条命中的文本轨；
/// 2. 本视频的目标语言 [langCode]（语言标签，`ja` / `zh-Hant` …，见
///    `subtitle_language_target.dart`）最匹配的文本轨——中文先挑繁 / 简对上的；
///    [langCode] 为空（语言链全空）时退用同一次探测里的音轨语言
///    （[audioSubtitleLanguageTarget]）；
/// 3. 都不命中才回退「第一条文本轨」（旧行为）。
///
/// [onExtractionStarted]：挑中的轨缓存未命中、要整轨抽取时回调挑中的源（语义同
/// [loadSubtitleCueResult]）。
Future<DefaultEmbeddedSubtitleLoadResult> loadDefaultTextEmbeddedSubtitleCues({
  required String videoPath,
  required String bookUid,
  String langCode = '',
  List<String> preferredLanguages = const <String>[],
  Future<void>? cancel,
  void Function(SubtitleSource chosen)? onExtractionStarted,
}) => _asForegroundDiskRead(
  videoPath,
  () => _loadDefaultTextEmbeddedSubtitleCues(
    videoPath: videoPath,
    bookUid: bookUid,
    langCode: langCode,
    preferredLanguages: preferredLanguages,
    cancel: cancel,
    onExtractionStarted: onExtractionStarted,
  ),
);

Future<DefaultEmbeddedSubtitleLoadResult> _loadDefaultTextEmbeddedSubtitleCues({
  required String videoPath,
  required String bookUid,
  required String langCode,
  required List<String> preferredLanguages,
  required Future<void>? cancel,
  required void Function(SubtitleSource chosen)? onExtractionStarted,
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

  final bool hasEmbedded = listing.sources.any(
    (SubtitleSource source) => source.isEmbedded,
  );
  if (!hasEmbedded) {
    return DefaultEmbeddedSubtitleLoadResult(
      status: DefaultEmbeddedSubtitleLoadStatus.noEmbeddedTracks,
      cues: const <AudioCue>[],
      embeddedProbe: probe,
    );
  }

  final SubtitleSource? chosen =
      pickSubtitleSourceByPreference(
        listing.sources,
        preferredLanguages,
        accept: isTextEmbeddedSubtitleSource,
      ) ??
      pickSubtitleSourceForTarget(
        listing.sources,
        SubtitleLanguageTarget.parse(langCode) ??
            audioSubtitleLanguageTarget(probe.audioLanguages),
        accept: isTextEmbeddedSubtitleSource,
      ) ??
      firstTextEmbeddedSubtitleSource(listing.sources);
  if (chosen == null) {
    return DefaultEmbeddedSubtitleLoadResult(
      status: DefaultEmbeddedSubtitleLoadStatus.noTextTrack,
      cues: const <AudioCue>[],
      embeddedProbe: probe,
    );
  }

  final SubtitleCueLoadResult loaded = await loadSubtitleCueResult(
    chosen,
    videoPath,
    bookUid,
    cancel: cancel,
    onExtractionStarted: onExtractionStarted == null
        ? null
        : () => onExtractionStarted(chosen),
  );
  if (loaded.isFailure) {
    return DefaultEmbeddedSubtitleLoadResult(
      status: DefaultEmbeddedSubtitleLoadStatus.emptyCues,
      source: chosen,
      cues: const <AudioCue>[],
      embeddedProbe: probe,
      cueFailure: loaded.failure,
    );
  }
  return DefaultEmbeddedSubtitleLoadResult(
    status: DefaultEmbeddedSubtitleLoadStatus.loaded,
    source: chosen,
    cues: loaded.cues,
    embeddedProbe: probe,
  );
}

/// 把整轨抽取的失败原因翻成 cue 加载的失败原因（BUG-1490 按原因分流的延伸）。
/// null（单趟成功却没有这条轨的文件：空轨 / 枚举没列出它）归 [SubtitleCueLoadFailure.extractionFailed]。
@visibleForTesting
SubtitleCueLoadFailure subtitleCueFailureForExtract(
  EmbeddedSubtitleExtractFailure? failure,
) {
  switch (failure) {
    case EmbeddedSubtitleExtractFailure.stalled:
      return SubtitleCueLoadFailure.extractionStalled;
    case EmbeddedSubtitleExtractFailure.cancelled:
      return SubtitleCueLoadFailure.extractionCancelled;
    case EmbeddedSubtitleExtractFailure.inputMissing:
    case EmbeddedSubtitleExtractFailure.ffmpegUnavailable:
    case EmbeddedSubtitleExtractFailure.failed:
    case null:
      return SubtitleCueLoadFailure.extractionFailed;
  }
}

Future<SubtitleCueLoadResult> _loadEmbeddedCues(
  SubtitleSource source,
  String videoPath,
  String bookUid, {
  Future<void>? cancel,
  void Function()? onExtractionStarted,
}) => _asForegroundDiskRead(
  videoPath,
  () => _loadEmbeddedCuesNow(
    source,
    videoPath,
    bookUid,
    cancel: cancel,
    onExtractionStarted: onExtractionStarted,
  ),
);

Future<SubtitleCueLoadResult> _loadEmbeddedCuesNow(
  SubtitleSource source,
  String videoPath,
  String bookUid, {
  required Future<void>? cancel,
  required void Function()? onExtractionStarted,
}) async {
  final SubtitleFormat? format = subtitleFormatForCodec(source.codec ?? '');
  if (format == null) {
    return const SubtitleCueLoadResult.failed(
      SubtitleCueLoadFailure.unsupportedFormat,
    );
  }

  // BUG-104: extracting one embedded subtitle out of a multi-GB interleaved
  // container costs a full read of the file (~20s for a 27GB BluRay REMUX),
  // with no UI feedback the user reads as "switching didn't work". Pay that read
  // **once** by demuxing all text tracks into a per-video cache the first time
  // any track is needed; every later switch is an instant cached-file read.
  final int index = source.streamIndex!;
  final Directory cacheDir = await embeddedSubtitleCacheDir(videoPath);
  final File cached = File(p.join(cacheDir.path, 'sub_$index${_ext(format)}'));

  EmbeddedSubtitleExtractFailure? extractFailure;
  if (!await _isNonEmptyFile(cached)) {
    onExtractionStarted?.call();
    extractFailure = await _ensureAllEmbeddedSubtitlesExtracted(
      videoPath,
      cacheDir,
      cancel: cancel,
    );
  }
  if (!await _isNonEmptyFile(cached)) {
    return SubtitleCueLoadResult.failed(
      subtitleCueFailureForExtract(extractFailure),
    );
  }
  return _readAndParse(cached, format, bookUid);
}

/// 读文件 + 解析的公共尾段：把「读不出」「解析不出」分开成两种失败原因。
///
/// 异常按来源分流而不是 `catch (_)` 一把抓——读文件的异常是
/// [SubtitleCueLoadFailure.fileUnreadable]，解析阶段的异常是
/// [SubtitleCueLoadFailure.parseFailed]。编码问题不再会出现在这里：
/// [readTextWithEncoding] 已经保证任何字节都能解出字符串（BUG-1490）。
///
/// [contentReader] 仅供测试注入（默认 [readTextWithEncoding]）。
Future<SubtitleCueLoadResult> _readAndParse(
  File file,
  SubtitleFormat format,
  String bookUid, {
  Future<String> Function(File file)? contentReader,
}) async {
  final String text;
  try {
    text = await (contentReader ?? readTextWithEncoding)(file);
  } catch (e) {
    // 不带栈：读文件失败的异常本身已含路径与 OS errno，栈没有额外信息，
    // 而这条路径（缺失的 sidecar 等）在正常使用中会反复命中。
    fushiDebugPrint('[subtitle] read failed: ${file.path}: $e');
    return const SubtitleCueLoadResult.failed(
      SubtitleCueLoadFailure.fileUnreadable,
    );
  }
  final List<AudioCue> cues;
  try {
    // 播放路径要 `\p` 绘图事件（招牌白底遮罩靠它）：它们随 cue 列表进
    // [VideoPlayerController.setCues] 被分流成渲染专用流；落库侧
    // （`VideoBookRepository`）按 [AudioCue.isRenderOnly] 过滤，不会写进对白表。
    cues = await parseSubtitleContentAsync(
      format,
      content: text,
      bookUid: bookUid,
      includeDrawings: true,
    );
  } catch (e, stack) {
    fushiDebugPrint('[subtitle] parse failed: ${file.path}: $e\n$stack');
    return const SubtitleCueLoadResult.failed(
      SubtitleCueLoadFailure.parseFailed,
    );
  }
  if (cues.isEmpty) {
    return const SubtitleCueLoadResult.failed(
      SubtitleCueLoadFailure.parseFailed,
    );
  }
  return SubtitleCueLoadResult.loaded(cues);
}

/// Pre-extracts text embedded subtitle tracks for [videoPath] into the shared
/// cache without parsing or applying cues.
///
/// Callers should fire-and-forget this after video load. It reuses the same
/// in-flight extraction as manual switching, so a user selecting a subtitle
/// while prewarm is still running waits for that task instead of launching a
/// second full-container read. Failures are swallowed: manual switching keeps
/// the existing fallback path and user-facing load failure message.
///
/// [cancel]：播放页退出 / 换集时完成，撤掉本次预热对共享抽取的占用（见
/// [_ensureAllEmbeddedSubtitlesExtracted]）；还在排队时完成 = 不再开始。
///
/// [background]：预热的不是正在看的这一集（下一集）。它只是为了换集时字幕瞬时出现，
/// 不能和当前集的整片读盘抢同一块盘——两个顺序读同时压在一块机械盘 / 慢 USB 盘上，
/// 磁头来回跳、两边都慢得多，当前集的字幕更晚出来、播放也跟着卡。所以后台预热先排队：
/// 同一块盘（[mediaDiskIdentity]）上还有前台读盘（当前集的预热 / 自动加载 / 菜单切轨）
/// 或别的已开始的后台预热时，等它们结束（或被取消）再开始。
Future<void> prewarmEmbeddedSubtitleCache(
  String videoPath, {
  Future<void>? cancel,
  bool background = false,
}) async {
  if (!background) {
    return _asForegroundDiskRead(
      videoPath,
      () => _prewarmEmbeddedSubtitleCacheNow(videoPath, cancel: cancel),
    );
  }
  final _EmbeddedDiskRead read = _EmbeddedDiskRead(
    videoPath,
    foreground: false,
  );
  _embeddedDiskReads.add(read);
  try {
    if (!await _awaitBackgroundDiskTurn(read, cancel)) return;
    await _prewarmEmbeddedSubtitleCacheNow(videoPath, cancel: cancel);
  } finally {
    _releaseDiskRead(read);
  }
}

Future<void> _prewarmEmbeddedSubtitleCacheNow(
  String videoPath, {
  required Future<void>? cancel,
}) async {
  try {
    await _ensureAllEmbeddedSubtitlesExtracted(
      videoPath,
      await embeddedSubtitleCacheDir(videoPath),
      cancel: cancel,
    );
  } catch (e, stack) {
    fushiDebugPrint(
      '[VideoSubtitleSource] embedded subtitle prewarm failed: '
      '$e\n$stack',
    );
  }
}

/// 一次可能读整个容器的内封字幕操作（排队判据用，见 [prewarmEmbeddedSubtitleCache]）。
class _EmbeddedDiskRead {
  _EmbeddedDiskRead(this.videoPath, {required this.foreground})
    : running = foreground;

  final String videoPath;

  /// 前台 = 正在看的这一集（预热 / 自动加载 / 菜单切轨）：从不排队，登记即算在读。
  final bool foreground;

  /// 后台预热轮到了、已经开始读。
  bool running;

  final Completer<void> released = Completer<void>();

  /// 只在有后台预热要比较时才去问系统（大多数登记的前台读盘根本用不到）。
  late final Future<Set<String>?> disk = mediaDiskIdentity(videoPath).then((
    Set<String>? value,
  ) {
    diskResolved = true;
    diskValue = value;
    return value;
  });
  bool diskResolved = false;
  Set<String>? diskValue;
}

final List<_EmbeddedDiskRead> _embeddedDiskReads = <_EmbeddedDiskRead>[];

/// **同步**登记一次前台读盘再跑 [body]：调用方在第一个 await 之前就占住盘，后台预热
/// 不会因为「当前集还在算缓存目录」的那几毫秒抢先开始。
Future<T> _asForegroundDiskRead<T>(
  String videoPath,
  Future<T> Function() body,
) async {
  final _EmbeddedDiskRead read = _EmbeddedDiskRead(videoPath, foreground: true);
  _embeddedDiskReads.add(read);
  try {
    return await body();
  } finally {
    _releaseDiskRead(read);
  }
}

void _releaseDiskRead(_EmbeddedDiskRead read) {
  _embeddedDiskReads.remove(read);
  if (!read.released.isCompleted) read.released.complete();
}

/// 后台预热 [read] 等到同一块盘上没有别的前台读盘 / 已开始的后台预热为止；轮到时置
/// [_EmbeddedDiskRead.running] 并返回 true，[cancel] 先完成返回 false。
///
/// 盘标识判不出时按可能同盘处理（[mayShareDisk]）。判定与置 running 在同一段同步代码
/// 里完成，两条后台预热不会同时判到「没人在读」。
Future<bool> _awaitBackgroundDiskTurn(
  _EmbeddedDiskRead read,
  Future<void>? cancel,
) async {
  bool cancelled = false;
  final Future<void> cancelSignal = cancel == null
      ? Completer<void>().future
      : cancel.then((_) => cancelled = true);
  while (true) {
    if (cancelled) return false;
    final Set<String>? mine = await Future.any(<Future<Set<String>?>>[
      read.disk,
      cancelSignal.then((_) => null),
    ]);
    if (cancelled) return false;
    final List<_EmbeddedDiskRead> blockers = <_EmbeddedDiskRead>[
      for (final _EmbeddedDiskRead other in _embeddedDiskReads)
        if (!identical(other, read) &&
            (other.foreground || other.running) &&
            (!other.diskResolved || mayShareDisk(mine, other.diskValue)))
          other,
    ];
    if (blockers.isEmpty) {
      read.running = true;
      return true;
    }
    // 盘标识还没解析出来的：等它解析完再判；同盘的：等它结束。
    await Future.any(<Future<void>>[
      for (final _EmbeddedDiskRead b in blockers)
        b.diskResolved ? b.released.future : b.disk.then((_) {}),
      cancelSignal,
    ]);
  }
}

/// 测试用：当前登记着的内封字幕读盘（前台 / 后台）里，后台预热已开始的视频路径。
@visibleForTesting
List<String> debugRunningBackgroundSubtitlePrewarms() => <String>[
  for (final _EmbeddedDiskRead r in _embeddedDiskReads)
    if (!r.foreground && r.running) r.videoPath,
];

/// [videoPath] 第 [streamIndex] 条内嵌文本轨的缓存文件；缓存没有就先整轨抽取一次。
/// 抽不出 / 不是文本轨返回 null。要拿**多条**轨时用 [extractEmbeddedSubtitleTrackFiles]：
/// 逐条调本函数在抽取失败时会每条轨各触发一次整个容器的读取。
Future<File?> extractEmbeddedSubtitleTrackFile({
  required String videoPath,
  required int streamIndex,
  required String codec,
}) async {
  final SubtitleFormat? format = subtitleFormatForCodec(codec);
  if (format == null) return null;
  final Directory cacheDir = await embeddedSubtitleCacheDir(videoPath);
  final File cached = File(
    p.join(
      cacheDir.path,
      'sub_$streamIndex${subtitleExtensionForFormat(format)}',
    ),
  );
  if (!await _isNonEmptyFile(cached)) {
    await _asForegroundDiskRead(
      videoPath,
      () => _ensureAllEmbeddedSubtitlesExtracted(videoPath, cacheDir),
    );
  }
  return await _isNonEmptyFile(cached) ? cached : null;
}

/// [tracks] 里每条内嵌文本轨的缓存文件（相对序号 → 文件；抽不出 / 非文本轨不在结果里）。
///
/// 任一条缺缓存时**整体只抽一次**（单趟读完整个容器、写出全部文本轨），然后只读缓存：
/// 不像逐条 [extractEmbeddedSubtitleTrackFile] 那样在抽取失败时对每条轨各读一遍整个
/// 容器（30 条轨 = 30 次全量读盘，BUG-4838）。
Future<Map<int, File>> extractEmbeddedSubtitleTrackFiles({
  required String videoPath,
  required List<EmbeddedSubtitleTrack> tracks,
  Future<void>? cancel,
}) async {
  final Directory cacheDir = await embeddedSubtitleCacheDir(videoPath);
  final Map<int, File> wanted = <int, File>{};
  for (final EmbeddedSubtitleTrack track in tracks) {
    final SubtitleFormat? format = subtitleFormatForCodec(track.codec);
    if (format == null) continue;
    wanted[track.streamIndex] = File(
      p.join(
        cacheDir.path,
        'sub_${track.streamIndex}${subtitleExtensionForFormat(format)}',
      ),
    );
  }
  bool anyMissing = false;
  for (final File f in wanted.values) {
    if (!await _isNonEmptyFile(f)) {
      anyMissing = true;
      break;
    }
  }
  if (anyMissing) {
    await _asForegroundDiskRead(
      videoPath,
      () => _ensureAllEmbeddedSubtitlesExtracted(
        videoPath,
        cacheDir,
        cancel: cancel,
      ),
    );
  }
  final Map<int, File> out = <int, File>{};
  for (final MapEntry<int, File> e in wanted.entries) {
    if (await _isNonEmptyFile(e.value)) out[e.key] = e.value;
  }
  return out;
}

/// 一次在途的整轨抽取，以及等它的调用方（BUG-4838）。
///
/// 抽取是按视频共享的（同一缓存目录只跑一个 ffmpeg），等待方各有各的生命周期：播放页
/// 预热、自动加载、菜单切换带取消信号；互联 host 端点、ASR 取证等不带。只有当可取消的
/// 等待方全部撤走、且从没有不可取消的等待方加入过时，才强杀进程——否则一个页面退出
/// 会把别人正在等的抽取一起杀掉。
class _EmbeddedExtractJob {
  _EmbeddedExtractJob();

  /// 完成即强杀 ffmpeg（交给 [extractEmbeddedSubtitlesViaFfmpeg] 的 `cancel`）。
  final Completer<void> kill = Completer<void>();

  /// 还在等、可取消的等待方个数。
  int cancellableWaiters = 0;

  /// 有不可取消的等待方加入过：此后永不强杀。
  bool pinned = false;

  late final Future<EmbeddedSubtitleExtractFailure?> done;

  void releaseCancellableWaiter() {
    cancellableWaiters--;
    if (cancellableWaiters <= 0 && !pinned && !kill.isCompleted) {
      kill.complete();
    }
  }
}

final Map<String, _EmbeddedExtractJob> _embeddedExtractInFlight =
    <String, _EmbeddedExtractJob>{};

/// Ensures every text embedded subtitle track of [videoPath] is demuxed into
/// [cacheDir] (single ffmpeg pass). Idempotent and de-duplicated across
/// concurrent callers. Returns the extraction failure reason (null = the pass
/// succeeded or there was nothing to extract).
///
/// [cancel] 完成时本调用立即以 [EmbeddedSubtitleExtractFailure.cancelled] 返回，并撤掉
/// 自己对共享抽取的占用（规则见 [_EmbeddedExtractJob]）。上一次抽取正在被强杀时，
/// 先等它的进程真正退出再起新的（两个 ffmpeg 不能同时写同一批缓存文件）。
Future<EmbeddedSubtitleExtractFailure?> _ensureAllEmbeddedSubtitlesExtracted(
  String videoPath,
  Directory cacheDir, {
  Future<void>? cancel,
}) async {
  bool cancelled = false;
  unawaited(cancel?.then((_) => cancelled = true));
  final String key = cacheDir.path;
  _EmbeddedExtractJob? job = _embeddedExtractInFlight[key];
  while (job != null && job.kill.isCompleted) {
    await job.done;
    if (cancelled) return EmbeddedSubtitleExtractFailure.cancelled;
    job = _embeddedExtractInFlight[key];
  }
  if (job == null) {
    final _EmbeddedExtractJob created = _EmbeddedExtractJob();
    created.done =
        _extractAllEmbeddedSubtitles(
          videoPath,
          cacheDir,
          cancel: created.kill.future,
        ).whenComplete(() {
          if (identical(_embeddedExtractInFlight[key], created)) {
            _embeddedExtractInFlight.remove(key);
          }
        });
    _embeddedExtractInFlight[key] = created;
    job = created;
  }
  final _EmbeddedExtractJob joined = job;
  if (cancel == null) {
    joined.pinned = true;
    return joined.done;
  }
  joined.cancellableWaiters++;
  final Completer<EmbeddedSubtitleExtractFailure?> mine =
      Completer<EmbeddedSubtitleExtractFailure?>();
  unawaited(
    joined.done.then((EmbeddedSubtitleExtractFailure? failure) {
      if (!mine.isCompleted) mine.complete(failure);
    }),
  );
  unawaited(
    cancel.then((_) {
      if (mine.isCompleted) return;
      mine.complete(EmbeddedSubtitleExtractFailure.cancelled);
      joined.releaseCancellableWaiter();
    }),
  );
  return mine.future;
}

/// 测试用：当前有没有在途的整轨抽取（[videoPath] 的缓存目录为键）。
@visibleForTesting
Future<bool> debugEmbeddedSubtitleExtractInFlight(String videoPath) async =>
    _embeddedExtractInFlight.containsKey(
      (await embeddedSubtitleCacheDir(videoPath)).path,
    );

Future<EmbeddedSubtitleExtractFailure?> _extractAllEmbeddedSubtitles(
  String videoPath,
  Directory cacheDir, {
  required Future<void> cancel,
}) async {
  try {
    final List<EmbeddedSubtitleTrack> tracks = await listEmbeddedSubtitleTracks(
      videoPath,
    );
    // Only text tracks (graphic pgs/dvd → null format) get extracted; cache file
    // name carries the parser-deciding extension.
    final Map<int, String> outputs = <int, String>{};
    for (final EmbeddedSubtitleTrack track in tracks) {
      final SubtitleFormat? fmt = subtitleFormatForCodec(track.codec);
      if (fmt == null) continue;
      final String outputPath = p.join(
        cacheDir.path,
        'sub_${track.streamIndex}${_ext(fmt)}',
      );
      final File cached = File(outputPath);
      if (await _isNonEmptyFile(cached)) continue;
      // BUG-863 negative cache: a track already rejected as undecodable by the
      // bundled ffmpeg leaves an `.unsupported` sentinel (written by the
      // extractor only on a definitive failure, never on stall / cancel). Skip it
      // so we don't re-read the whole (possibly multi-GB) container and re-log
      // the same failure on every prewarm. The sentinel lives in the cache dir,
      // keyed by video size+mtime, so replacing the file in place still
      // re-attempts extraction.
      if (await File(
        '$outputPath$kUnsupportedEmbeddedSubtitleSentinelSuffix',
      ).exists()) {
        continue;
      }
      outputs[track.streamIndex] = outputPath;
    }
    if (outputs.isEmpty) return null;
    try {
      await cacheDir.create(recursive: true);
    } on FileSystemException {
      return EmbeddedSubtitleExtractFailure.failed;
    }
    // 按进度判活、可取消（BUG-4838）：不再给「60 s + 8 s/GB」的总预算——那个预算隐含
    // ≥125 MB/s 的读盘吞吐，慢盘上会把一直在推进的抽取杀掉。
    final EmbeddedSubtitleExtractResult result =
        await extractEmbeddedSubtitlesViaFfmpeg(
          inputPath: videoPath,
          outputs: outputs,
          cancel: cancel,
        );
    return result.failure;
  } catch (e, stack) {
    fushiDebugPrint(
      '[VideoSubtitleSource] embedded subtitle extraction failed: $e\n$stack',
    );
    return EmbeddedSubtitleExtractFailure.failed;
  }
}

/// [path] 是普通文件（跟随链接）则返回其 [FileStat]，否则 / stat 失败返回 null。
/// async：视频常在网络盘上，同步 stat 冷目录时会冻结调用方 isolate（BUG-3756）。
Future<FileStat?> _regularFileStat(String path) async {
  try {
    final FileStat stat = await File(path).stat();
    return stat.type == FileSystemEntityType.file ? stat : null;
  } on FileSystemException {
    return null;
  }
}

/// [file] 存在且非空（旧 `existsSync() && lengthSync() > 0` 的 async 版）。
Future<bool> _isNonEmptyFile(File file) async =>
    ((await _regularFileStat(file.path))?.size ?? 0) > 0;

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
  final String safe = videoBaseNoExt.replaceAll(
    RegExp(r'[^A-Za-z0-9_.-]'),
    '_',
  );
  return '${safe}_${sizeBytes}_$mtimeMs';
}

/// The cache directory (under the OS temp dir) holding [videoPath]'s extracted
/// embedded subtitle tracks. Stat failures fall back to a path-only key.
///
/// async：键要 stat 视频本体（size + mtime），视频常在网络盘上；互联 host 的内封字幕
/// 端点在 app 主 isolate 上调这里，同步 statSync 会冻结全部端点与 UI（BUG-3756）。
Future<Directory> embeddedSubtitleCacheDir(String videoPath) async =>
    embeddedSubtitleCacheDirForStat(
      videoPath,
      await _regularFileStat(videoPath),
    );

/// **Pure**：已拿到 [videoPath] 的 [stat]（普通文件；null = 不存在 / stat 失败）时
/// 的缓存目录。[embeddedSubtitleCacheDir] 的不做 IO 的那一半，供已持有 stat 的调用方
/// （以及在 fake-async 里不能 await 真 IO 的 widget 测试）复用同一条键规则。
Directory embeddedSubtitleCacheDirForStat(String videoPath, FileStat? stat) {
  final String base = p.basenameWithoutExtension(videoPath);
  int size = 0;
  int mtimeMs = 0;
  if (stat != null && stat.type == FileSystemEntityType.file) {
    size = stat.size;
    mtimeMs = stat.modified.millisecondsSinceEpoch;
  } else {
    // stat failed (deleted/locked): fall back to a stable path hash so we
    // still cache within the session.
    mtimeMs = videoPath.hashCode;
  }
  final String key = embeddedSubtitleCacheKey(base, size, mtimeMs);
  return Directory(p.join(Directory.systemTemp.path, 'fushi_vsub_cache', key));
}

/// **Pure**: a size-scaled total budget for one ffmpeg pass over the container.
/// Base 60s + 8s/GB, clamped to [60s, 1200s] (BUG-104).
///
/// 现在只给**枚举**（`ffmpeg -i` 读流头，[probeEmbeddedSubtitleTracks]）与音频能量
/// 探测用。整轨抽取已不吃它（BUG-4838）：抽取要把整个容器读完，耗时 = 体积 ÷ 读盘
/// 吞吐，这条预算隐含 ≥125 MB/s，慢盘上会杀掉一直在推进的抽取；抽取改为按进度判活
/// （[kEmbeddedSubtitleExtractStallTimeout]）。
@visibleForTesting
Duration subtitleExtractTimeoutForBytes(int sizeBytes) {
  final double gb = sizeBytes / (1024 * 1024 * 1024);
  final int seconds = (60 + gb * 8).clamp(60, 1200).round();
  return Duration(seconds: seconds);
}

/// 从一个**外挂字幕文件路径**读 cue，保留失败原因（[SubtitleCueLoadFailure]）。不抛。
///
/// 这是「本地字幕文件 → cue」的唯一入口：播放页选外挂源（[loadSubtitleCueResult]）
/// 与主页把字幕拖到视频卡（`attachSubtitleToVideoBook`）共用同一份失败分类，
/// 不各自 `readAsString` + 解析（那样失败原因会退化成空列表或未捕获异常，BUG-1504）。
///
/// [contentReader] 默认 [readTextWithEncoding]；播放页载入链注入自己的读法，同一份
/// 字节顺手判对齐产物（只读一次盘）。须与 [readTextWithEncoding] 同样任何字节都能解出
/// 字符串。
Future<SubtitleCueLoadResult> loadExternalSubtitleCueResult(
  String path,
  String bookUid, {
  Future<String> Function(File file)? contentReader,
}) async {
  final SubtitleFormat? format = subtitleFormatForPath(path);
  if (format == null) {
    return const SubtitleCueLoadResult.failed(
      SubtitleCueLoadFailure.unsupportedFormat,
    );
  }
  return _readAndParse(
    File(path),
    format,
    bookUid,
    contentReader: contentReader,
  );
}

/// 临时抽字幕文件的扩展名（让 ffmpeg 按扩展名选输出 muxer）。
String _ext(SubtitleFormat format) {
  return subtitleExtensionForFormat(format);
}
