import 'dart:convert';
import 'dart:io';

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

  /// 轨标题（若 ffmpeg 日志含 metadata title，当前解析不提取，预留）。
  final String? title;
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

/// **纯函数**：解析 `ffmpeg -i <video>` 的 stderr，提取所有内嵌字幕轨。
///
/// 按出现顺序为每条字幕分配相对序号（0,1,2…），即 `-map 0:s:N` 的 N。提取
/// 语言（括号内）与 codec（`Subtitle: ` 后第一个 token）。无字幕轨 / 空输入返回
/// 空列表。不碰文件系统，可单测。
List<EmbeddedSubtitleTrack> parseSubtitleStreamsFromFfmpegLog(
  String ffmpegStderr,
) {
  final List<EmbeddedSubtitleTrack> tracks = <EmbeddedSubtitleTrack>[];
  int relativeIndex = 0;
  for (final String line in const LineSplitter().convert(ffmpegStderr)) {
    final RegExpMatch? m = _subtitleStreamPattern.firstMatch(line);
    if (m == null) continue;
    final String? language = m.group(1);
    final String codec = m.group(2)!;
    tracks.add(EmbeddedSubtitleTrack(
      streamIndex: relativeIndex,
      codec: codec,
      language: language,
    ));
    relativeIndex++;
  }
  return tracks;
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

  /// 持久化值：内嵌 → `embedded:<n>`，外挂 → 绝对路径。
  String toPersistedValue() =>
      isEmbedded ? '$embeddedPrefix$streamIndex' : externalPath!;

  /// 该源是否就是 [persisted] 持久化值代表的源（用于菜单高亮当前选中）。
  bool matchesPersisted(String? persisted) {
    if (persisted == null) return false;
    return toPersistedValue() == persisted;
  }
}

/// 跑 `ffmpeg -i <videoPath>` 并解析 stderr 得到所有内嵌字幕轨（IO 包装）。
///
/// `ffmpeg -i` 无输出文件时退出码非 0，但 stderr 仍含完整流信息，属正常；故不看
/// 退出码，只解析 stderr。ffmpeg 不存在 / 出错时静默返回空列表（与无字幕一致）。
/// 仅桌面端有意义（移动端无 ffmpeg），调用方门控。
Future<List<EmbeddedSubtitleTrack>> listEmbeddedSubtitleTracks(
  String videoPath,
) async {
  if (!File(videoPath).existsSync()) return const <EmbeddedSubtitleTrack>[];
  try {
    // 经统一 FfmpegBackend 跑 `-i`（CLI 后端 = 旧 Process 路径；捆绑后端可在移动端
    // 工作），解析合并的 stderr 输出。`-i` 无输出文件时退出码非 0，但 stderr 仍含
    // 完整流信息，故只看 output 不看退出码。
    final FfmpegRunResult result = await resolveFfmpegBackend().run(
      <String>['-hide_banner', '-i', videoPath],
      const Duration(seconds: 30),
    );
    return parseSubtitleStreamsFromFfmpegLog(result.output);
  } on ProcessException {
    // ffmpeg 未安装：优雅降级为无内嵌字幕。
    return const <EmbeddedSubtitleTrack>[];
  } catch (_) {
    return const <EmbeddedSubtitleTrack>[];
  }
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
Future<List<SubtitleSource>> listAllSubtitleSources(
  String videoPath, {
  required String langCode,
}) async {
  final List<SubtitleSource> sources = <SubtitleSource>[];

  // ① 内嵌轨。
  final List<EmbeddedSubtitleTrack> embedded =
      await listEmbeddedSubtitleTracks(videoPath);
  for (final EmbeddedSubtitleTrack track in embedded) {
    sources.add(SubtitleSource.embedded(
      streamIndex: track.streamIndex,
      language: track.language,
      codec: track.codec,
      label: _embeddedLabel(track),
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

  return sources;
}

/// 内嵌轨菜单标签：`内嵌 N: lang / codec`（lang 缺省省略）。
String _embeddedLabel(EmbeddedSubtitleTrack track) {
  final StringBuffer sb = StringBuffer('内嵌 ${track.streamIndex}: ');
  if ((track.language ?? '').isNotEmpty) {
    sb.write('${track.language} / ');
  }
  sb.write(track.codec);
  return sb.toString();
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

Future<List<AudioCue>> _loadEmbeddedCues(
  SubtitleSource source,
  String videoPath,
  String bookUid,
) async {
  final SubtitleFormat? format = subtitleFormatForCodec(source.codec ?? '');
  if (format == null) return const <AudioCue>[];

  final Directory tempDir =
      Directory.systemTemp.createTempSync('hibiki_video_sub_src');
  final String outputPath = p.join(tempDir.path, 'embedded${_ext(format)}');
  try {
    final String? extracted = await extractEmbeddedSubtitleViaFfmpeg(
      inputPath: videoPath,
      streamIndex: source.streamIndex!,
      outputPath: outputPath,
    );
    if (extracted == null) return const <AudioCue>[];
    final String text = await readTextWithEncoding(File(extracted));
    return parseSubtitleContent(format, content: text, bookUid: bookUid);
  } catch (_) {
    return const <AudioCue>[];
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  }
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
    return parseSubtitleContent(format, content: text, bookUid: bookUid);
  } catch (_) {
    return const <AudioCue>[];
  }
}

/// 临时抽字幕文件的扩展名（让 ffmpeg 按扩展名选输出 muxer）。
String _ext(SubtitleFormat format) {
  switch (format) {
    case SubtitleFormat.srt:
      return '.srt';
    case SubtitleFormat.ass:
      return '.ass';
    case SubtitleFormat.vtt:
      return '.vtt';
  }
}
