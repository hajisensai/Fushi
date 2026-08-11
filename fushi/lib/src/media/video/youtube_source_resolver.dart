// TODO-1000：字幕必须从 youtube_explode 的内部 VideoController（@internal）取 ANDROID_VR
// player response（见下方注释与 resolveYoutubeSource）。dart format 会把多行 import 的
// `show VideoController` 换行，令行内 `// ignore` 锚点失效，故用 file 级抑制。
// ignore_for_file: invalid_use_of_internal_member
import 'package:flutter/foundation.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:http/http.dart' as http;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
// TODO-1000 根因：YouTube 已对 web 端 timedtext（字幕）URL 加 proof-of-origin
// 门槛，公开 API（closedCaptions.getManifest → web 观看页派生的 URL）实测**所有格式
// 都返回空体**，`.get()` 解析空 XML 抛 XmlParserException，进而**炸掉整个
// resolveYoutubeSource → 视频根本打不开（黑屏/报错）**。唯一仍可直取的是 ANDROID_VR
// innertube player response 内嵌的字幕 URL（移动端豁免该门槛）。公开 API 不暴露按
// client 取 player response 的入口，故此处必须触达内部符号；一旦 youtube_explode 升级
// 改了这些符号，守卫测试 test/media/video/youtube_resolver_impl_symbols_test.dart 会
// 大声失败。依赖锁定在 youtube_explode_dart 2.5.x。
// TODO-1307（A2）：androidVr getPlayerResponse **无需先取 WatchPage** 即返回全部
// closedCaptionTrack（含 ja）——实测 dQw4w9WgXcQ 不带 watchPage 396ms 拿到 6 轨、带
// watchPage 1674ms 拿到同 6 轨，WatchPage 是纯多余往返，故 [_resolveYoutubeCaptions]
// 只做一次 getPlayerResponse，不再 import/使用 WatchPage。
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/videos/video_controller.dart'
    show VideoController;
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/player/player_response.dart'
    show PlayerResponse, ClosedCaptionTrack;
import 'package:fushi/src/utils/net/app_http.dart';

/// BUG-1498：youtube_explode 自带的 `YoutubeHttpClient` 内部是裸 `http.Client()`
/// （`findProxy` 为 null，连 `HTTPS_PROXY` 都不读），而 youtube.com / googlevideo.com
/// 在多数用户所在网络需要代理。它的构造函数收一个 `http.Client`，于是这里把应用代理
/// 出口喂进去；除出口外行为（UA / cookie / 重试）一律沿用上游默认。
yt.YoutubeHttpClient _createYoutubeHttpClient() =>
    yt.YoutubeHttpClient(createAppHttpIoClient());

/// YouTube 解析结果：可播放流 URL + 字幕 cue + header + 标题。
///
/// [streamUrl] 是最高清 **video-only** 流（可达 4K，非 muxed 的 360p 上限）；
/// [audioStreamUrl] 是最高码率 **audio-only** 流，播放时经 `AudioTrack.uri` 外挂、制卡时
/// 音频段从它裁。仅当该视频没有分离流（罕见）才回落 muxed（[audioStreamUrl] 为 null，
/// 画质 ≤360p——这是 YouTube 侧的限制，非本实现选择）。
class YoutubeResolvedSource {
  const YoutubeResolvedSource({
    required this.streamUrl,
    required this.audioStreamUrl,
    required this.miningVideoUrl,
    required this.miningVideoHasAudio,
    required this.title,
    required this.httpHeaders,
    required this.cues,
  });

  final String streamUrl;
  final String? audioStreamUrl;

  /// TODO-1000（BUG-528）：**制卡 GIF/帧专用**的低分辨率视频流 URL（muxed 360p 或最低
  /// 码率 video-only）。播放用的 [streamUrl] 可达 4K，让 ffmpeg 从它按时间戳裁 GIF 会
  /// 因下载/解码 4K 帧而超时（实测 120s timeout）；制卡封面只需 ~320px，故另取一条小流。
  /// 音频段抽取源见 [miningVideoHasAudio]。null → 回落 [streamUrl]。
  final String? miningVideoUrl;

  /// TODO-1000（BUG-528）：[miningVideoUrl] 是否是 **muxed 流（自带音轨）**。muxed 时
  /// 制卡句子音频直接从 [miningVideoUrl] 抽（实测 2s 出 AAC）；YouTube 的 **audio-only
  /// DASH 流** ffmpeg 的 `-ss`(置于 `-i` 前) HTTP seek 会 stall→撞 120s 超时→无句子音频
  /// （实测：audio-only itag258 首个请求即超时，muxed itag18 抽音频 2s 成功）。故 muxed 时
  /// 播放页不把制卡音频指向 [audioStreamUrl]，让引擎回落 muxed 视频源抽音频。
  final bool miningVideoHasAudio;

  final String title;
  final Map<String, String> httpHeaders;
  final List<AudioCue> cues;

  /// 是否走了 muxed 兜底（无分离流，画质受限）。
  bool get isMuxedFallback => audioStreamUrl == null;
}

/// 一条可选 YouTube 画质档（video-only 流），供播放页画质选择器（用户报「YouTube 没法
/// 调画质」）列档 + 切档。[height]=分辨率高度（如 1080）、[label]=显示文案（如 `1080p`）、
/// [videoUrl]=该档 video-only 直链、[codec]=视频编码（挑档时 avc1>vp9>av01 优先）。
@immutable
class YoutubeVideoVariant {
  const YoutubeVideoVariant({
    required this.height,
    required this.label,
    required this.videoUrl,
    required this.codec,
  });

  final int height;
  final String label;
  final String videoUrl;
  final String codec;
}

/// YouTube 画质档集合：各档 video-only 流（[variants]，高→低、每高度一条编码最优）+ 共用
/// 的最高码率 audio-only 流（[audioStreamUrl]，切档保持同一音轨）+「自动/默认最佳」档下标
/// （[defaultIndex]，= [pickPlaybackVideoStream] 的选择，供画质菜单的「自动」项与初始高亮
/// 对齐）。视频无分离流（仅 muxed ≤360p）时 [variants] 为空。
///
/// 不带防盗链 header——切档回放的 UA 由播放页复用当前 [UrlStreamVideoClient.httpHeaderFields]
/// （初始解析已铸的同一 youtube replay UA），与这里现取的 video-only URL 一致。
@immutable
class YoutubeVariantSet {
  const YoutubeVariantSet({
    required this.variants,
    required this.audioStreamUrl,
    required this.defaultIndex,
  });

  final List<YoutubeVideoVariant> variants;
  final String? audioStreamUrl;
  final int defaultIndex;

  bool get isEmpty => variants.isEmpty;
}

/// 纯函数：识别 YouTube URL（watch / youtu.be / shorts / nocookie）。
bool isYoutubeUrl(String url) {
  final Uri? u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme) return false;
  final String host = u.host.toLowerCase();
  return host.endsWith('youtube.com') ||
      host == 'youtu.be' ||
      host.endsWith('youtube-nocookie.com');
}

/// 纯函数：从任意 YouTube URL 写法解出 canonical 11 位 videoId；无法解析返回 null。
///
/// TODO-1304：复用 youtube_explode 的 [yt.VideoId] 解析器（与 [resolveYoutubeSource]
/// 取流用的是同一份），覆盖 `watch?v=<id>` / `youtu.be/<id>` / `embed/<id>` /
/// `shorts/<id>`，并**天然剥掉 `&t=` / `&list=` / `&si=` / `&feature=` 等追踪参数**
/// （正则捕获停在首个 `&` / `?` / `/`）——令同一视频的任意 URL 写法收敛到同一 id，
/// 供 [streamVideoBookUid] 派生稳定去重身份。解析失败（非 YouTube、带 query 的 shorts、
/// 畸形 URL）抛 [ArgumentError]，此处吞掉返回 null，让调用方回退 sha1（不阻断导入）。
/// 纯字符串解析，不联网。
String? youtubeVideoIdOrNull(String url) {
  try {
    return yt.VideoId(url.trim()).value;
  } catch (_) {
    return null;
  }
}

/// 纯函数：由 YouTube [videoId] 拼缩略图 URL（TODO-1281 导入封面用）。
///
/// 用 `hqdefault.jpg`——它对**所有**视频都存在（480x360，YouTube 保证生成），不像
/// `maxresdefault.jpg` 对未上传高清源的视频会 404。导入时据此下载书架封面（流媒体书
/// videoPath 是 watch URL、ffmpeg 抽帧不适用，故走缩略图 URL）。
String youtubeThumbnailUrl(String videoId) =>
    'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';

/// TODO-1314（C7，借鉴 yt-dlp 多缩略图回退）：由 [videoId] 拼**降序分辨率候选**缩略图 URL，
/// 高清优先、末位恒是 [youtubeThumbnailUrl]（hqdefault，YouTube 对所有视频保证生成）。
///
/// - `maxresdefault.jpg`（1280x720，源级、无 4:3 黑边）——**对未上传高清源的视频会 404**；
/// - `sddefault.jpg`（640x480）——多数视频有；
/// - `hqdefault.jpg`（480x360）——**恒存在**的最终兜底。
///
/// 配合 [resolveBestThumbnailUrl] 逐个探测存在性、取首个可用者：高清缺失自动退次高，
/// 收益是导入封面尽量取到无黑边的高清图，且绝不因 maxres 404 落到无封面。纯函数，便于单测。
List<String> youtubeThumbnailCandidates(String videoId) => <String>[
      'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg',
      'https://i.ytimg.com/vi/$videoId/sddefault.jpg',
      youtubeThumbnailUrl(videoId),
    ];

/// TODO-1314（C7）：按 [youtubeThumbnailCandidates] 降序探测缩略图存在性，返回**首个可用**的
/// URL；全部探测失败仍返回 [youtubeThumbnailUrl]（hqdefault 恒存在，= 旧行为，绝不无封面）。
///
/// [probe] 注入「某 URL 是否存在」的判定（生产走 HTTP HEAD，测试注入假件），把纯回退逻辑与
/// 网络 IO 解耦，便于离线单测。单个 [probe] 抛异常视为「不存在」继续下一候选（best-effort）。
Future<String> resolveBestThumbnailUrl(
  String videoId, {
  required Future<bool> Function(String url) probe,
}) async {
  for (final String candidate in youtubeThumbnailCandidates(videoId)) {
    try {
      if (await probe(candidate)) return candidate;
    } catch (_) {
      // 单个候选探测失败：退下一个更低分辨率候选（不阻断）。
    }
  }
  return youtubeThumbnailUrl(videoId);
}

/// IO：HTTP HEAD 探测 [url] 是否存在（2xx）。任何异常/超时视为不存在（false，best-effort）。
/// i.ytimg.com 对不存在的 `maxresdefault` 返回 404、存在则 200，故 HEAD 状态码即可判定。
Future<bool> _thumbnailExistsViaHead(http.Client client, String url) async {
  try {
    final http.Response res =
        await client.head(Uri.parse(url)).timeout(const Duration(seconds: 6));
    return res.statusCode >= 200 && res.statusCode < 300;
  } catch (_) {
    return false;
  }
}

/// YouTube **导入元数据**：视频标题 + 缩略图 URL（TODO-1281）。
///
/// 与 [YoutubeResolvedSource]（含流/字幕，播放/制卡用）区分：导入只需标题 + 封面，
/// 不需要昂贵的 `getManifest`（流）/字幕解析，故单独一个轻量结果对象。
class YoutubeMetadata {
  const YoutubeMetadata({required this.title, required this.thumbnailUrl});

  /// 视频真实标题（`videoDetails.title`，经 youtube_explode）。
  final String title;

  /// 缩略图 URL（[youtubeThumbnailUrl]，hqdefault）。
  final String thumbnailUrl;
}

/// IO：**只**取 YouTube 视频标题 + 缩略图 URL（TODO-1281 导入用）。
///
/// 只调 `videos.get`（拿 title + videoId），**跳过** [resolveYoutubeSource] 里的
/// `getManifest`（流解析）与字幕解析（各 ~9~19s）——导入不需要可播流/cue，只要把
/// 真实视频名 + 封面落库，故这条轻量路径快得多。临时流 URL 会过期、不在此缓存，重开仍由
/// [resolveYoutubeSource] 重解析。超时/失败由调用方兜底（保留 URL 派生标题 + 无封面，
/// 导入不因元数据抓取失败中止）。
Future<YoutubeMetadata> resolveYoutubeMetadata(
  String url, {
  Duration timeout = const Duration(seconds: 20),
  // TODO-1314（C7）：仅供测试注入缩略图存在性 HEAD 探测用的 http client。生产传 null → 自建、
  // 用完关闭。把「videos.get 拿标题」（需真网络、外部契约）与「缩略图探测」（可离线注入）解耦。
  http.Client? thumbnailProbeClient,
}) async {
  final yt.YoutubeExplode client =
      yt.YoutubeExplode(_createYoutubeHttpClient());
  try {
    final yt.Video video = await client.videos.get(url).timeout(timeout);
    // TODO-1314（C7）：多分辨率缩略图回退——HEAD 探测 maxres→sd→hq，取首个可用者作导入封面
    // 源（高清缺失自动退次高，绝不因 maxres 404 落到无封面）。best-effort：探测失败退 hqdefault
    // （恒存在，= 旧行为）。探测在导入路径、一次性、有界（每候选 6s），换更清晰的书架封面。
    final http.Client probeClient =
        thumbnailProbeClient ?? createAppHttpIoClient();
    try {
      final String bestThumbnail = await resolveBestThumbnailUrl(
        video.id.value,
        probe: (String u) => _thumbnailExistsViaHead(probeClient, u),
      );
      return YoutubeMetadata(title: video.title, thumbnailUrl: bestThumbnail);
    } finally {
      if (thumbnailProbeClient == null) probeClient.close();
    }
  } finally {
    client.close();
  }
}

final HtmlUnescape _unescape = HtmlUnescape();

AudioCue _cue(String bookKey, int index, String text, int startMs, int endMs) =>
    AudioCue()
      ..bookKey = bookKey
      ..chapterHref = 'youtube://$bookKey'
      ..sentenceIndex = index
      ..textFragmentId = 'yt-$index'
      ..text = text
      ..startMs = startMs
      ..endMs = endMs
      ..audioFileIndex = 0;

/// 纯函数：YouTube timedtext XML → List<AudioCue>。两种格式**按内容自适应**（BUG-783）：
/// - **srv1/legacy**：`<text start="秒" dur="秒">文本</text>`（旧路径，保留）。
/// - **timedtext format="3"**：`<p t="毫秒" d="毫秒">文本</p>`，ASR 轨文本拆进内嵌
///   `<s>` 词级片段（需拼接）；含 `a="1"` 的空白滚动占位 `<p>` 与 `<w>` 元素跳过。
///   YouTube androidVr 现在一律回 format 3（`fmt=srv1` 被无视），旧 srv1-only 正则对它
///   解析出 0 cue → 字幕静默消失。
///
/// 策略：先跑 srv1；有结果即返回（旧行为不变）。无 srv1 `<text>` 命中才按 format 3 解析
/// `<p>`（两格式互斥，不会共存）。
List<AudioCue> parseYoutubeTimedTextToCues({
  required String content,
  required String bookKey,
}) {
  final List<AudioCue> srv1 = _parseSrv1TimedText(content, bookKey);
  if (srv1.isNotEmpty) return srv1;
  return _parseFormat3TimedText(content, bookKey);
}

/// srv1/legacy：`<text start="秒" dur="秒">…</text>`，秒 → 毫秒。
List<AudioCue> _parseSrv1TimedText(String content, String bookKey) {
  final List<AudioCue> cues = <AudioCue>[];
  final RegExp re = RegExp(
    r'<text start="([\d.]+)"(?: dur="([\d.]+)")?[^>]*>(.*?)</text>',
    dotAll: true,
  );
  int index = 0;
  for (final RegExpMatch m in re.allMatches(content)) {
    final double start = double.tryParse(m.group(1) ?? '') ?? 0;
    final double dur = double.tryParse(m.group(2) ?? '') ?? 0;
    final String raw = _unescape
        .convert((m.group(3) ?? '').replaceAll(RegExp(r'<[^>]+>'), ''))
        .trim();
    if (raw.isEmpty) continue;
    cues.add(_cue(bookKey, index, raw, (start * 1000).round(),
        ((start + dur) * 1000).round()));
    index++;
  }
  return cues;
}

/// timedtext format="3"：`<p t="毫秒" (d="毫秒")? …>…</p>`。t/d 已是毫秒直用；内嵌
/// `<s>` 词级片段经 `<[^>]+>` 剥标签后自然拼接；空白/无 t 的 `<p>` 跳过。
List<AudioCue> _parseFormat3TimedText(String content, String bookKey) {
  final List<AudioCue> cues = <AudioCue>[];
  final RegExp pRe = RegExp(r'<p\b([^>]*)>(.*?)</p>', dotAll: true);
  final RegExp tRe = RegExp(r'\bt="(\d+)"');
  final RegExp dRe = RegExp(r'\bd="(\d+)"');
  int index = 0;
  for (final RegExpMatch m in pRe.allMatches(content)) {
    final String attrs = m.group(1) ?? '';
    final RegExpMatch? tm = tRe.firstMatch(attrs);
    if (tm == null) continue; // 无起始时间的 <p> 跳过
    final int start = int.tryParse(tm.group(1) ?? '') ?? 0;
    final int dur = int.tryParse(dRe.firstMatch(attrs)?.group(1) ?? '') ?? 0;
    final String raw = _unescape
        .convert((m.group(2) ?? '').replaceAll(RegExp(r'<[^>]+>'), ''))
        .trim();
    if (raw.isEmpty) continue; // 空白滚动占位 <p a="1"> </p> 天然跳过
    cues.add(_cue(bookKey, index, raw, start, start + dur));
    index++;
  }
  return cues;
}

/// 纯函数：把抓到的字幕轨 + 各轨 cue 序列化成扩展可消费的 JSON（A：浏览器扩展→server 桥）。
/// [cuesPerTrack] 与 [tracks] 一一对应。cue 为空的轨剔除（下载失败不占面板一格）。cue 只
/// 露 `text/startMs/endMs`（与扩展面板 cue 形状对齐）；轨露语言/显示名/ASR/翻译标志，
/// 显示标签与 panel key 由扩展侧组装。
Map<String, dynamic> serializeYoutubeCaptionTracks(
  List<YoutubeCaptionTrack> tracks,
  List<List<AudioCue>> cuesPerTrack,
) {
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  for (int i = 0; i < tracks.length; i++) {
    final List<AudioCue> cues =
        i < cuesPerTrack.length ? cuesPerTrack[i] : const <AudioCue>[];
    if (cues.isEmpty) continue;
    final YoutubeCaptionTrack t = tracks[i];
    out.add(<String, dynamic>{
      'languageCode': t.languageCode,
      'languageName': t.languageName,
      'isAutoGenerated': t.isAutoGenerated,
      'isTranslated': t.isTranslated,
      'cues': <Map<String, dynamic>>[
        for (final AudioCue c in cues)
          <String, dynamic>{
            'text': c.text,
            'startMs': c.startMs,
            'endMs': c.endMs,
          },
      ],
    });
  }
  return <String, dynamic>{'tracks': out};
}

/// IO：抓某 YouTube 视频的全部字幕轨 + 各轨 cue，序列化成扩展桥 JSON（A）。track-list-first
/// 拿元数据后**并发**下载各轨 cue（timedtext 文件小，`Future.wait` 省往返）。best-effort：
/// 整体失败或无轨返回 `{tracks:[]}`。[maxTracks] 上限防极端多轨视频拖垮请求。
Future<Map<String, dynamic>> resolveYoutubeCaptionsForExtension(
  String url, {
  String preferLang = 'ja',
  int maxTracks = 8,
}) async {
  final List<YoutubeCaptionTrack> all =
      await resolveYoutubeCaptionTracks(url, preferLang: preferLang);
  final List<YoutubeCaptionTrack> tracks =
      all.length > maxTracks ? all.sublist(0, maxTracks) : all;
  if (tracks.isEmpty) return <String, dynamic>{'tracks': <dynamic>[]};
  final List<List<AudioCue>> cues = await Future.wait(
    tracks.map((YoutubeCaptionTrack t) =>
        resolveYoutubeCaptionCues(t, bookKey: 'yt:ext')),
  );
  return serializeYoutubeCaptionTracks(tracks, cues);
}

/// A1 多 client 兜底顺序（TODO-1307，借鉴 yt-dlp 多 client 抽流）：**androidVr 首选**——它
/// 签发的直链无需签名解密、libmpv/ffmpeg 用普通浏览器 UA 即可拉取（默认 android/ios 直链
/// 实测被 403）；仅 androidVr 取流失败/空流时才回落 ios、tv（覆盖部分地区限制/年龄门视频）。
/// [ios] 是 `static final` 非 const，故整表用 `final` 而非 `const`。
final List<yt.YoutubeApiClient> kYoutubeManifestClientFallback =
    <yt.YoutubeApiClient>[
  yt.YoutubeApiClient.androidVr,
  yt.YoutubeApiClient.ios,
  yt.YoutubeApiClient.tv,
];

/// TODO-1365（BUG-678）：YouTube 分离流的**回放 User-Agent 必须与 youtube_explode 铸造 +
/// 校验该流所用的 UA 完全一致**。[yt.YoutubeApiClient.androidVr] 的 innertube context 不带
/// `userAgent`，故 youtube_explode 全程用 [yt.YoutubeHttpClient.defaultHeaders] 的**完整
/// Chrome UA** 发 innertube player 请求铸出 googlevideo 直链、并对首流做 HEAD 403 探测
/// （youtube_explode `stream_client.getManifest`）。旧代码把回放 UA 硬编码成**残缺**的裸
/// `Mozilla/5.0`（不是任何真实浏览器会发的完整 UA）——googlevideo 的 svpuc 服务端校验对残缺/
/// 可疑 UA 往往不是干脆 403，而是**吊住连接（tarpit）**：libmpv/ffmpeg 的 curl 请求一路挂到
/// `network-timeout`(30s) 超时（video 主流 + audio-add 副音轨都超时打不开，即 TODO-1365 报告的
/// 现象）。改为复用 youtube_explode 的同一完整 UA，令回放请求与铸流会话 UA 一致（yt-dlp 同
/// 原则：以铸流 client 的 UA 回放）。youtube_explode 升级改了默认 UA 时本值**自动跟随**
/// （非 const，运行时取）；守卫见 `test/media/video/youtube_stream_replay_ua_test.dart`。
/// null 兜底：极端情况下 youtube_explode 默认头缺 `user-agent` 时退到内联完整 Chrome UA。
final String kYoutubeStreamReplayUserAgent =
    yt.YoutubeHttpClient.defaultHeaders['user-agent'] ??
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/96.0.4664.18 Safari/537.36';

/// 纯函数：YouTube 分离流的回放 header（TODO-1365）。回放 UA 必须与 youtube_explode 铸流 UA
/// 一致，见 [kYoutubeStreamReplayUserAgent]。播放页据此设 libmpv `http-header-fields`
/// （video 主流经 `Media.httpHeaders`、audio-add 副音轨经全局属性继承）；制卡 ffmpeg 经
/// `-user_agent` 复用同一常量（desktop_audio_clipper）。
Map<String, String> youtubeStreamReplayHeaders() =>
    <String, String>{'User-Agent': kYoutubeStreamReplayUserAgent};

/// A1（TODO-1307）：按 [ytClients] 顺序**逐个**取 manifest，首个拿到非空流的 client 即
/// 返回。**不合并多 client 流**——youtube_explode 的 [StreamClient.getManifest] 传多个
/// client 时会把各 client 的流全并进一个 manifest（androidVr 流与 ios/tv 直链混在一起），
/// 而 [_pickPlaybackVideoUrl] 只按编码/分辨率挑、不看来源，可能选中 ios/tv 的 403 直链 →
/// 回归。故此处对**单一** client 调 getManifest（其内部已做首流 HEAD 403 探测：403 抛异常
/// = 该 client 失败），androidVr 成功即零回归返回，只有它失败才试下一个。全部失败抛最后异常。
///
/// 提速（用户报「YouTube 加载巨慢」）：每个 client 的 getManifest 加 [perClientTimeout]
/// 上限。googlevideo/innertube 偶发 tarpit（限流时连接不完成），旧代码只有外层 40s 总超时
/// 兜底——首选 androidVr 一旦 tarpit，要等满 40s 才轮到 ios/tv，用户干等到近乎放弃。加
/// 每 client 超时后，某 client 挂住 [perClientTimeout] 即判失败、立刻试下一个兜底 client，
/// 常见「androidVr 慢」场景从「等 40s」降到「等 ~perClientTimeout 就换」。取值需保证
/// 三 client 累计（[perClientTimeout] × 3）不超外层 40s 兜底（13s × 3 = 39s）。超时按普通
/// client 失败处理（记异常、试下一个），与 403/无流同路径。
Future<yt.StreamManifest> _getManifestWithClientFallback(
  yt.YoutubeExplode client,
  yt.VideoId videoId,
  List<yt.YoutubeApiClient> ytClients, {
  Duration perClientTimeout = const Duration(seconds: 13),
}) async {
  Object? lastError;
  for (final yt.YoutubeApiClient api in ytClients) {
    try {
      final yt.StreamManifest manifest =
          await client.videos.streamsClient.getManifest(
        videoId,
        ytClients: <yt.YoutubeApiClient>[api],
      ).timeout(perClientTimeout);
      if (manifest.streams.isNotEmpty) return manifest;
    } catch (e) {
      // 单 client 失败（403 / 无流 / 限流 / 本 client 超时）：记异常、试下一个兜底
      // client（非致命）。超时（[TimeoutException]）与其它失败同路径，快速切下一个。
      lastError = e;
    }
  }
  if (lastError != null) {
    throw StateError(
      'youtube manifest failed for all clients '
      '(${ytClients.map((yt.YoutubeApiClient c) => c.apiUrl).toList()}): '
      '$lastError',
    );
  }
  throw StateError('youtube manifest: empty client fallback list');
}

/// IO：用 youtube_explode 解析可播放流 URL + 日文字幕（无则空）+ 标题。
///
/// 流用 **ANDROID_VR** client 取：它签发的直链无需签名解密、且 libmpv/ffmpeg 用普通
/// 浏览器 UA 即可拉取（默认 android/ios client 签发的直链实测被 403），取**最高清
/// video-only + 最高码率 audio-only** 分离流（可达 4K），播放时视频流经 libmpv、音频流经
/// `AudioTrack.uri` 外挂；制卡时 GIF/帧从视频流、音频段从音频流各自 ffmpeg 裁。仅当该视频
/// 无分离流才回落 muxed（≤360p，YouTube 侧限制）。字幕见 [_resolveBestCaptionCues]。
Future<YoutubeResolvedSource> resolveYoutubeSource(
  String url, {
  String preferSubtitleLang = 'ja',
  // 慢网下每个 youtube_explode 请求可达 7~9s。TODO-1307 后播放页走「快解析 gate」
  // （withCaptions=false）：只 getManifest 取流即起播、跳过 videos.get（title 用 book.title）
  // 与字幕（后置异步解析灌 1302 字幕轨），解析从 >25s 降到 ~getManifest。40s 仅作 tarpit 兜底。
  Duration timeout = const Duration(seconds: 40),
  // 制卡 / 快解析 gate 只需流 URL，不需字幕 cue → 传 false 跳过 videos.get + 昂贵的字幕解析，
  // 解析降到 ~getManifest。仅遗留「一次性同步取字幕」的调用方用默认 true。
  bool withCaptions = true,
  // A1 多 client 兜底顺序（默认 [kYoutubeManifestClientFallback]=androidVr→ios→tv）。
  List<yt.YoutubeApiClient>? ytClients,
}) async {
  final yt.YoutubeExplode client =
      yt.YoutubeExplode(_createYoutubeHttpClient());
  try {
    // 加超时：YouTube 的 innertube/googlevideo 偶发 tarpit（高频请求被限流时连接不完成），
    // youtube_explode 内部无超时 → 会永久挂住，UI 表现为「点了没反应也没报错」。超时后
    // finally 关 client 取消挂起请求、抛 TimeoutException，让调用方给出明确「解析失败」反馈。
    return await _resolveYoutubeSourceInner(
      client,
      url,
      preferSubtitleLang,
      withCaptions,
      ytClients ?? kYoutubeManifestClientFallback,
    ).timeout(timeout);
  } finally {
    client.close();
  }
}

Future<YoutubeResolvedSource> _resolveYoutubeSourceInner(
  yt.YoutubeExplode client,
  String url,
  String preferSubtitleLang,
  bool withCaptions,
  List<yt.YoutubeApiClient> ytClients,
) async {
  // 制卡路径（withCaptions=false）直接从 URL 取 VideoId，**跳过 videos.get**（慢网下这一步就
  // ~9s）——制卡不需要标题/元数据，只要 getManifest 的流 URL。播放器路径仍取完整 Video（要标题）。
  final yt.VideoId videoId;
  final String title;
  if (withCaptions) {
    final yt.Video video = await client.videos.get(url);
    videoId = video.id;
    title = video.title;
  } else {
    videoId = yt.VideoId(url);
    title = '';
  }
  // A1（TODO-1307）：androidVr 首选、失败才回落 ios/tv（[_getManifestWithClientFallback]）。
  final yt.StreamManifest manifest =
      await _getManifestWithClientFallback(client, videoId, ytClients);
  // 优先「video-only（编码优先 avc1>vp9>av01，≤1080p 最高清）+ 最高码率 audio-only」分离流；两者齐备才用，
  // 否则回落 muxed（YouTube 把 muxed 限 ≤360p，故仅作最后兜底）。
  String streamUrl;
  String? audioStreamUrl;
  if (manifest.videoOnly.isNotEmpty && manifest.audioOnly.isNotEmpty) {
    streamUrl = _pickPlaybackVideoUrl(manifest);
    audioStreamUrl = manifest.audioOnly.withHighestBitrate().url.toString();
  } else {
    streamUrl = manifest.muxed.withHighestBitrate().url.toString();
    audioStreamUrl = null;
  }
  // 制卡 GIF/帧的低分辨率源：muxed（360p，含音视频、抽 GIF 快）优先，否则最低码率
  // video-only（都远小于 4K 播放流，避免网络抽取超时）。见 [YoutubeResolvedSource.miningVideoUrl]。
  final String? miningVideoUrl = _pickMiningVideoUrl(manifest);
  // muxed 挖矿流自带音轨 → 制卡音频从它抽（audio-only DASH 流 ffmpeg seek 会超时）。
  final bool miningVideoHasAudio = manifest.muxed.isNotEmpty;
  final String bookKey = 'yt:${videoId.value}';
  // 制卡路径 withCaptions=false → 跳过字幕解析（省 ~19s，避免超时）；播放器路径仍取字幕
  // （A3：人工>ASR·精确语言选轨，[_resolveBestCaptionCues]）。
  final List<AudioCue> cues = withCaptions
      ? await _resolveBestCaptionCues(videoId, bookKey, preferSubtitleLang)
      : const <AudioCue>[];

  return YoutubeResolvedSource(
    streamUrl: streamUrl,
    audioStreamUrl: audioStreamUrl,
    miningVideoUrl: miningVideoUrl,
    miningVideoHasAudio: miningVideoHasAudio,
    title: title,
    httpHeaders: youtubeStreamReplayHeaders(),
    cues: cues,
  );
}

/// 编码优先级（数字越小越优先）：avc1/H.264=0 > vp9=1 > av01=2 > 其它=3。
///
/// TODO-1159：H.264（avc1）几乎所有移动/桌面 GPU 都有硬件解码；VP9 次之；AV1（av01）
/// 硬解支持最差，老机/无硬解设备走软解 → libmpv 掉帧抖动（用户原报「YouTube 播放卡顿」）。
/// 同 1080p 下 YouTube 常同时给 avc1/vp9/av01，之前按分辨率取 `.first`（`List.sort` 非稳定）
/// 常落到 vp9/av01 → 软解抖。故显式按编码优先挑。前缀匹配（avc1.640028 / vp09 / av01.0.08M）。
int youtubeVideoCodecPriority(String videoCodec) {
  final String c = videoCodec.toLowerCase();
  if (c.startsWith('avc1') || c.startsWith('avc3') || c.startsWith('h264')) {
    return 0;
  }
  if (c.startsWith('vp9') || c.startsWith('vp09')) return 1;
  if (c.startsWith('av01') || c.startsWith('av1')) return 2;
  return 3;
}

/// 纯函数：从 video-only 候选里挑「最适合流畅播放」的一条（TODO-1159 修卡顿）。
///
/// 选流优先级：
/// 1. **编码优先** avc1(H.264) > vp9 > av01（[youtubeVideoCodecPriority]）——修软解抖的核心；
/// 2. 先按 [maxHeight] cap（默认 1080，保画质不顺带降到 720），再在最优编码里取**分辨率最高**
///    的一条（同编码就近上限）；
/// 3. 同编码同分辨率再优先 **非 throttled**（`isThrottled==false`，正常 ANDROID_VR 都不
///    throttled，纯保险 tiebreak）。
/// 全部 >maxHeight（罕见）时退**最低清**（宁流畅勿卡死）。
///
/// 注意：注入泛型 + 访问器，核心只依赖每条流的 height/codec/throttled 三属性，便于纯函数
/// 单测（免构造重量级 youtube_explode 对象）。返回被选中的原始元素；空列表抛 [StateError]。
T pickPlaybackVideoStream<T>(
  List<T> streams, {
  required int Function(T stream) heightOf,
  required String Function(T stream) codecOf,
  required bool Function(T stream) throttledOf,
  int maxHeight = 1080,
}) {
  if (streams.isEmpty) {
    throw StateError('pickPlaybackVideoStream: empty stream list');
  }
  final List<T> capped =
      streams.where((T s) => heightOf(s) <= maxHeight).toList();
  if (capped.isEmpty) {
    // 全部 >maxHeight：退最低清（宁流畅勿卡死）。
    return (streams.toList()
          ..sort((T a, T b) => heightOf(a).compareTo(heightOf(b))))
        .first;
  }
  capped.sort((T a, T b) {
    final int byCodec = youtubeVideoCodecPriority(codecOf(a))
        .compareTo(youtubeVideoCodecPriority(codecOf(b)));
    if (byCodec != 0) return byCodec;
    final int byHeight = heightOf(b).compareTo(heightOf(a)); // 分辨率降序
    if (byHeight != 0) return byHeight;
    // 非 throttled 优先（throttled=true 排后）。
    return (throttledOf(a) ? 1 : 0).compareTo(throttledOf(b) ? 1 : 0);
  });
  return capped.first;
}

/// 选播放用 video-only 流：编码优先（avc1>vp9>av01）→ ≤1080p 最高清 → 非 throttled
/// （[pickPlaybackVideoStream]）。命中 throttled（异常，ANDROID_VR 正常不 throttled）时告警。
String _pickPlaybackVideoUrl(yt.StreamManifest manifest) {
  final yt.VideoOnlyStreamInfo chosen =
      pickPlaybackVideoStream<yt.VideoOnlyStreamInfo>(
    manifest.videoOnly.toList(),
    heightOf: (yt.VideoOnlyStreamInfo s) => s.videoResolution.height,
    codecOf: (yt.VideoOnlyStreamInfo s) => s.videoCodec,
    throttledOf: (yt.VideoOnlyStreamInfo s) => s.isThrottled,
  );
  if (chosen.isThrottled) {
    debugPrint(
      '[hibiki][youtube] 选中的播放流 isThrottled=true（异常，缓冲可能慢）：'
      'codec=${chosen.videoCodec} res=${chosen.videoResolution}',
    );
  }
  return chosen.url.toString();
}

/// 纯函数（泛型，可单测）：把 video-only 候选**去重成每个高度一条**（编码最优：avc1>vp9>
/// av01，同编码非 throttled 优先），按高度**降序**返回被选中的原始元素。供 YouTube 画质
/// 选择器列档——同一分辨率 YouTube 常同时给 avc1/vp9/av01 多条，画质菜单只需一条/档。
/// 注入 height/codec/throttled 访问器，核心只依赖三属性，免构造重量级 youtube_explode 对象。
List<T> dedupeVideoStreamsByHeight<T>(
  List<T> streams, {
  required int Function(T stream) heightOf,
  required String Function(T stream) codecOf,
  required bool Function(T stream) throttledOf,
}) {
  final Map<int, T> best = <int, T>{};
  for (final T s in streams) {
    final int h = heightOf(s);
    final T? cur = best[h];
    if (cur == null) {
      best[h] = s;
      continue;
    }
    final int byCodec = youtubeVideoCodecPriority(codecOf(s))
        .compareTo(youtubeVideoCodecPriority(codecOf(cur)));
    if (byCodec < 0) {
      best[h] = s; // 更优编码。
    } else if (byCodec == 0 && !throttledOf(s) && throttledOf(cur)) {
      best[h] = s; // 同编码：非 throttled 胜出。
    }
  }
  final List<int> heights = best.keys.toList()
    ..sort((int a, int b) => b.compareTo(a)); // 高→低。
  return <T>[for (final int h in heights) best[h] as T];
}

/// IO：为播放页画质选择器**懒解析** YouTube 各档 video-only 流（用户报「YouTube 没法调
/// 画质」）。用户点开画质菜单时才调（一次 getManifest），返回 [YoutubeVariantSet]：各档
/// video-only 流（去重按高度降序）+ 共用 audio-only 流（切档保持同一音轨）+ 防盗链 header
/// + 「自动/默认最佳」档下标（与 [resolveYoutubeSource] 初始选择同逻辑）。无分离流（仅
/// muxed）返回空集（播放页据此不显 YouTube 画质档，仍可播）。client 兜底与超时同
/// [resolveYoutubeSource]（androidVr→ios→tv、每 client 有超时）。
Future<YoutubeVariantSet> resolveYoutubeVideoVariants(
  String url, {
  Duration timeout = const Duration(seconds: 20),
  List<yt.YoutubeApiClient>? ytClients,
}) async {
  final yt.YoutubeExplode client =
      yt.YoutubeExplode(_createYoutubeHttpClient());
  try {
    return await _resolveYoutubeVideoVariantsInner(
      client,
      url,
      ytClients ?? kYoutubeManifestClientFallback,
    ).timeout(timeout);
  } finally {
    client.close();
  }
}

Future<YoutubeVariantSet> _resolveYoutubeVideoVariantsInner(
  yt.YoutubeExplode client,
  String url,
  List<yt.YoutubeApiClient> ytClients,
) async {
  final yt.VideoId videoId = yt.VideoId(url);
  final yt.StreamManifest manifest =
      await _getManifestWithClientFallback(client, videoId, ytClients);
  // 无分离流（仅 muxed ≤360p）：无多档可选，返回空集（播放页回退无 YouTube 画质菜单）。
  if (manifest.videoOnly.isEmpty || manifest.audioOnly.isEmpty) {
    return const YoutubeVariantSet(
      variants: <YoutubeVideoVariant>[],
      audioStreamUrl: null,
      defaultIndex: -1,
    );
  }
  final List<yt.VideoOnlyStreamInfo> deduped =
      dedupeVideoStreamsByHeight<yt.VideoOnlyStreamInfo>(
    manifest.videoOnly.toList(),
    heightOf: (yt.VideoOnlyStreamInfo s) => s.videoResolution.height,
    codecOf: (yt.VideoOnlyStreamInfo s) => s.videoCodec,
    throttledOf: (yt.VideoOnlyStreamInfo s) => s.isThrottled,
  );
  final List<YoutubeVideoVariant> variants = <YoutubeVideoVariant>[
    for (final yt.VideoOnlyStreamInfo s in deduped)
      YoutubeVideoVariant(
        height: s.videoResolution.height,
        label: '${s.videoResolution.height}p',
        videoUrl: s.url.toString(),
        codec: s.videoCodec,
      ),
  ];
  // 「自动」档 = 初始播放选择（[pickPlaybackVideoStream]：avc1 优先、≤1080p 最高清），
  // 按高度回找它在去重表里的下标，供画质菜单「自动」项与初始高亮对齐。
  final yt.VideoOnlyStreamInfo chosen =
      pickPlaybackVideoStream<yt.VideoOnlyStreamInfo>(
    manifest.videoOnly.toList(),
    heightOf: (yt.VideoOnlyStreamInfo s) => s.videoResolution.height,
    codecOf: (yt.VideoOnlyStreamInfo s) => s.videoCodec,
    throttledOf: (yt.VideoOnlyStreamInfo s) => s.isThrottled,
  );
  int defaultIndex = variants.indexWhere(
      (YoutubeVideoVariant v) => v.height == chosen.videoResolution.height);
  if (defaultIndex < 0) defaultIndex = 0;
  return YoutubeVariantSet(
    variants: variants,
    audioStreamUrl: manifest.audioOnly.withHighestBitrate().url.toString(),
    defaultIndex: defaultIndex,
  );
}

/// 选制卡 GIF/帧的低分辨率视频源：优先 muxed（360p，抽 GIF 实测 ~1.4s），否则最低码率
/// video-only（144p 级，实测 ~1.3s）。都远小于 4K 播放流，避免 ffmpeg 网络抽取超时。
/// 无任何流时返回 null（引擎回落到播放流→当前解码帧截图）。
String? _pickMiningVideoUrl(yt.StreamManifest manifest) {
  if (manifest.muxed.isNotEmpty) {
    return manifest.muxed.withHighestBitrate().url.toString();
  }
  if (manifest.videoOnly.isNotEmpty) {
    final List<yt.VideoOnlyStreamInfo> sorted = manifest.videoOnly.toList()
      ..sort((yt.VideoOnlyStreamInfo a, yt.VideoOnlyStreamInfo b) =>
          a.bitrate.compareTo(b.bitrate));
    return sorted.first.url.toString();
  }
  return null;
}

/// 一条 YouTube 字幕轨的**元数据**（不含 cue 正文），TODO-1302 track-list-first 模型的核心
/// 数据结构：起播后一次 [resolveYoutubeCaptionTracks]（单次 getPlayerResponse）即拿到全部轨
/// 的语言/名称/是否 ASR + timedtext [baseUrl]，立刻填字幕轨选择器；用户选中某轨才
/// [resolveYoutubeCaptionCues] 懒下载那一轨的 cue → overlay。**列表出现不再取决于一次 cue
/// 解析成败**（修「快加载 withCaptions:false 后字幕整个消失」的回归）。
///
/// [translateToCode] 非空 = autoTranslate 变体（TODO-1314 A3）：以本轨 [baseUrl] 为源、经
/// YouTube timedtext `&tlang=` 机翻成 [translateToCode]（母语对照）。原始轨该字段为 null。
@immutable
class YoutubeCaptionTrack {
  const YoutubeCaptionTrack({
    required this.baseUrl,
    required this.languageCode,
    required this.languageName,
    required this.isAutoGenerated,
    this.translateToCode,
  });

  /// timedtext baseUrl（不含 fmt/tlang 查询参数——下载时才补 `fmt=srv1` [+ `tlang=`]）。
  final String baseUrl;

  /// 轨语言码（YouTube 原样：`ja` / `en` / `en-US` / `zh-Hans` 等）。
  final String languageCode;

  /// 轨显示名（YouTube 侧本地化的 `name.simpleText`，ASR 轨常已含「(auto-generated)」等标注）。
  final String languageName;

  /// 是否自动生成（ASR）。A3：默认选轨与排序时人工轨优先于 ASR。
  final bool isAutoGenerated;

  /// 非 null = 机翻目标语言码（autoTranslate 变体，母语对照）。
  final String? translateToCode;

  bool get isTranslated => translateToCode != null;

  /// 稳定 key：字幕轨选择器高亮判定 + `_currentSubtitleSource` 编码 + per-track cue 缓存键。
  /// 形如 `youtube:captions:ja:human` / `youtube:captions:ja:asr` /
  /// `youtube:captions:ja:human:tl=zh`。同一视频内唯一（源语言+人工/ASR+翻译目标共同区分）。
  String get trackKey => 'youtube:captions:$languageCode:'
      '${isAutoGenerated ? 'asr' : 'human'}'
      '${translateToCode != null ? ':tl=$translateToCode' : ''}';

  /// timedtext 下载 URL：补 `fmt=srv1`（= [parseYoutubeTimedTextToCues] 认得的 XML）+
  /// 翻译变体再补 `tlang=`（YouTube 机翻）。
  String get cueDownloadUrl {
    final Uri raw = Uri.parse(baseUrl);
    return raw.replace(queryParameters: <String, String>{
      ...raw.queryParameters,
      'fmt': 'srv1',
      if (translateToCode != null) 'tlang': translateToCode!,
    }).toString();
  }

  /// 派生一条以本轨为源、翻成 [code] 的 autoTranslate 变体。
  YoutubeCaptionTrack translatedTo(String code) => YoutubeCaptionTrack(
        baseUrl: baseUrl,
        languageCode: languageCode,
        languageName: languageName,
        isAutoGenerated: isAutoGenerated,
        translateToCode: code,
      );
}

/// 语言主码 → 母语写法显示名（BUG-1289）。表外回退原码大写，见 [youtubeCaptionLanguageLabel]。
///
/// 各语言用其母语写法（`日本語` / `English` / `Español`），与 app 界面语言无关，故不走
/// i18n——与 jimaku_client.dart 的 `jimakuLanguageLabel` 同款取舍，但覆盖面按 YouTube 字幕轨的真实语言分布铺开
/// （jimaku 只需 ja/zh/en/ko 四种，那张表不够用，且分属不同域，不跨域复用）。
const Map<String, String> _kYoutubeCaptionLanguageNames = <String, String>{
  'ja': '日本語',
  'en': 'English',
  'zh': '中文',
  'ko': '한국어',
  'es': 'Español',
  'pt': 'Português',
  'fr': 'Français',
  'de': 'Deutsch',
  'it': 'Italiano',
  'ru': 'Русский',
  'ar': 'العربية',
  'hi': 'हिन्दी',
  'th': 'ไทย',
  'vi': 'Tiếng Việt',
  'id': 'Bahasa Indonesia',
  'ms': 'Bahasa Melayu',
  'tr': 'Türkçe',
  'nl': 'Nederlands',
  'pl': 'Polski',
  'uk': 'Українська',
  'sv': 'Svenska',
  'fil': 'Filipino',
};

/// 纯函数：一条字幕轨的**语言显示名**（BUG-1289）。
///
/// 根因背景：app 的字幕轨表走 ANDROID_VR innertube player response（见 [_fetchCaptionTracks]，
/// web 端 timedtext 已被 proof-of-origin 拦死，只剩这条路）。**该 client 的 player response
/// 不带 `name.simpleText`**——实测 `dQw4w9WgXcQ` 6 条轨的 `languageName` 全是 null，于是
/// [YoutubeCaptionTrack.languageName] 一律退化成裸语言码，字幕轨选择器列出的是
/// `en` / `ja` / `es-419` 这种机器码而非人话。故显示名不能直接读 [YoutubeCaptionTrack.languageName]。
///
/// 策略（保留未来自愈）：YouTube **真给了**本地化名（非空且不等于语言码）就优先用它——哪天
/// androidVr 开始回 `name.simpleText`，或换了带名字的 client，本函数自动受益、无需再改；
/// 否则按语言主码查 [_kYoutubeCaptionLanguageNames]，地区子码原样括注（`pt-BR` →
/// `Português (BR)`，`es-419` → `Español (419)`），表外回退原码大写（`gsw-CH` → `GSW (CH)`）。
String youtubeCaptionLanguageLabel(YoutubeCaptionTrack track) {
  final String name = track.languageName.trim();
  final String code = track.languageCode.trim();
  if (name.isNotEmpty && name.toLowerCase() != code.toLowerCase()) return name;
  if (code.isEmpty) return '';
  final int dash = code.indexOf('-');
  final String primary = (dash < 0 ? code : code.substring(0, dash));
  final String region = dash < 0 ? '' : code.substring(dash + 1);
  final String base = _kYoutubeCaptionLanguageNames[primary.toLowerCase()] ??
      primary.toUpperCase();
  return region.isEmpty ? base : '$base (${region.toUpperCase()})';
}

/// 纯函数：一条字幕轨在**字幕轨选择器里的最终显示标签**（BUG-1289）。
///
/// 不变式：**同一视频内 trackKey 不同的两条轨，标签必须不同**——否则用户在列表里看到两行
/// 一模一样的文字，无从选择（原 bug 正是同语言的人工轨与 ASR 轨都显示成裸 `en`）。轨的身份
/// 由「语言 + 人工/ASR + 翻译目标」三者共同决定（见 [YoutubeCaptionTrack.trackKey]），故标签
/// 也必须把这三者都体现出来。
///
/// i18n 文案由调用方注入（[translated] / [autoGenerated] 各接收已算好的语言名），使本函数
/// 保持纯函数、可离线单测，同时数据层不反向依赖 UI 的 i18n。
String youtubeCaptionTrackLabel(
  YoutubeCaptionTrack track, {
  required String Function(String lang) translated,
  required String Function(String lang) autoGenerated,
}) {
  final String lang = youtubeCaptionLanguageLabel(track);
  if (track.isTranslated) return translated(lang);
  if (track.isAutoGenerated) return autoGenerated(lang);
  return lang;
}

/// 纯函数：语言码是否匹配 [prefer]（精确或带地区后缀，`ja` 匹配 `ja` / `ja-JP`）。A3 精确语言。
bool captionLanguageMatches(String code, String prefer) {
  final String c = code.toLowerCase();
  final String p = prefer.toLowerCase();
  return c == p || c.startsWith('$p-');
}

/// 纯函数（可单测）：字幕轨排序——A3 精确目标语言优先、同权重人工优先于 ASR、翻译变体排末。
/// 稳定排序（同权重保持输入相对顺序，靠下标 tiebreak——`List.sort` 本身非稳定）。
/// 权重（越小越前）：精确语言人工=0 / 精确语言 ASR=1 / 其它语言人工=2 / 其它语言 ASR=3 /
/// 任何翻译变体=4。
List<YoutubeCaptionTrack> orderYoutubeCaptionTracks(
  List<YoutubeCaptionTrack> tracks, {
  required String preferLang,
}) {
  int rankOf(YoutubeCaptionTrack t) {
    if (t.isTranslated) return 4;
    final bool exact = captionLanguageMatches(t.languageCode, preferLang);
    if (exact) return t.isAutoGenerated ? 1 : 0;
    return t.isAutoGenerated ? 3 : 2;
  }

  final List<({YoutubeCaptionTrack track, int rank, int index})> decorated =
      <({YoutubeCaptionTrack track, int rank, int index})>[
    for (int i = 0; i < tracks.length; i++)
      (track: tracks[i], rank: rankOf(tracks[i]), index: i),
  ];
  decorated.sort((a, b) {
    final int byRank = a.rank.compareTo(b.rank);
    return byRank != 0 ? byRank : a.index.compareTo(b.index);
  });
  return <YoutubeCaptionTrack>[for (final d in decorated) d.track];
}

/// 纯函数（可单测）：默认选轨（A3 人工>ASR·精确语言）。= [orderYoutubeCaptionTracks] 后
/// **首个非翻译轨**（翻译变体仅作可选母语对照，不做默认自动应用）。空表返回 null。
YoutubeCaptionTrack? pickBestYoutubeCaptionTrack(
  List<YoutubeCaptionTrack> tracks, {
  required String preferLang,
}) {
  if (tracks.isEmpty) return null;
  final List<YoutubeCaptionTrack> ordered =
      orderYoutubeCaptionTracks(tracks, preferLang: preferLang);
  for (final YoutubeCaptionTrack t in ordered) {
    if (!t.isTranslated) return t;
  }
  return ordered.first;
}

/// 纯函数：给已排序轨表按需追加**一条** autoTranslate（母语对照）变体（TODO-1314 A3）。
/// 源 = 首个非翻译轨（通常目标学习语言人工轨）。以下情形不追加（无意义）：无 [translateTo]、
/// 空表、源轨语言即母语、或已存在母语原始轨。
List<YoutubeCaptionTrack> withAutoTranslateVariant(
  List<YoutubeCaptionTrack> ordered, {
  required String? translateTo,
}) {
  if (translateTo == null || translateTo.isEmpty || ordered.isEmpty) {
    return ordered;
  }
  YoutubeCaptionTrack? source;
  for (final YoutubeCaptionTrack t in ordered) {
    if (!t.isTranslated) {
      source = t;
      break;
    }
  }
  if (source == null) return ordered;
  if (captionLanguageMatches(source.languageCode, translateTo)) return ordered;
  final bool hasNativeOriginal = ordered.any((YoutubeCaptionTrack t) =>
      !t.isTranslated && captionLanguageMatches(t.languageCode, translateTo));
  if (hasNativeOriginal) return ordered;
  return <YoutubeCaptionTrack>[...ordered, source.translatedTo(translateTo)];
}

/// IO：一次 getPlayerResponse(androidVr) 取全部字幕轨元数据（track-list-first，TODO-1302）。
/// 不下载 cue 正文——[YoutubeCaptionTrack.baseUrl] 已在 player response 里，选中轨才
/// [resolveYoutubeCaptionCues] 懒下载。best-effort：任何失败（含 URL 解析不出 videoId）返回空
/// 表（字幕轨选择器无 YouTube 行，视频照播）。
///
/// [preferLang]：目标学习语言（排序 + 默认选轨用）。[autoTranslateTo] 非空且与已有轨语言不同
/// → 追加一条 autoTranslate（母语对照）变体（[withAutoTranslateVariant]）。
Future<List<YoutubeCaptionTrack>> resolveYoutubeCaptionTracks(
  String url, {
  String preferLang = 'ja',
  String? autoTranslateTo,
}) async {
  final yt.VideoId videoId;
  try {
    videoId = yt.VideoId(url);
  } catch (_) {
    return const <YoutubeCaptionTrack>[];
  }
  final List<YoutubeCaptionTrack> raw = await _fetchCaptionTracks(videoId);
  final List<YoutubeCaptionTrack> ordered =
      orderYoutubeCaptionTracks(raw, preferLang: preferLang);
  return withAutoTranslateVariant(ordered, translateTo: autoTranslateTo);
}

/// IO：懒下载**单条**字幕轨的 cue（track-list-first 的 on-select，TODO-1302）。选中轨才调，
/// 下载 [YoutubeCaptionTrack.cueDownloadUrl]（fmt=srv1 [+ tlang]）→ [parseYoutubeTimedTextToCues]。
/// best-effort：失败返回空 cue（视频照播、字幕轨行仍在可重试）。
Future<List<AudioCue>> resolveYoutubeCaptionCues(
  YoutubeCaptionTrack track, {
  required String bookKey,
}) async {
  final yt.YoutubeHttpClient http = _createYoutubeHttpClient();
  try {
    final String body = await http.getString(track.cueDownloadUrl);
    return parseYoutubeTimedTextToCues(content: body, bookKey: bookKey);
  } catch (_) {
    return const <AudioCue>[];
  } finally {
    http.close();
  }
}

/// IO：从 ANDROID_VR innertube player response 取字幕轨元数据表（公开 API 的 web 字幕 URL 已
/// 失效，见文件头注释）。best-effort：整体失败返回空表；**单轨字段缺失（vssId/name null）跳过
/// 该轨、不连坐整表**（防一条坏轨令字幕轨选择器全空 = 回归）。
///
/// TODO-1307（A2）：只做**一次** getPlayerResponse（androidVr），不再先取 WatchPage——实测
/// androidVr 不带 watchPage 即返回全部字幕轨（含 ja）且省一次往返（见文件头）。
Future<List<YoutubeCaptionTrack>> _fetchCaptionTracks(yt.VideoId id) async {
  final yt.YoutubeHttpClient http = _createYoutubeHttpClient();
  try {
    final PlayerResponse response = await VideoController(http)
        .getPlayerResponse(id, yt.YoutubeApiClient.androidVr);
    final List<YoutubeCaptionTrack> out = <YoutubeCaptionTrack>[];
    for (final ClosedCaptionTrack t in response.closedCaptionTrack) {
      try {
        out.add(YoutubeCaptionTrack(
          baseUrl: t.url,
          languageCode: t.languageCode,
          languageName: t.languageName ?? t.languageCode,
          isAutoGenerated: t.autoGenerated,
        ));
      } catch (_) {
        // 单轨字段缺失：跳过（不让一条坏轨令整个字幕轨选择器落空）。
      }
    }
    return out;
  } catch (_) {
    // 字幕是可选增强：其失败绝不能冒泡到 resolveYoutubeSource 阻断播放。
    return const <YoutubeCaptionTrack>[];
  } finally {
    http.close();
  }
}

/// IO：一次性同步取「最佳单轨」cue（A3 人工>ASR·精确语言选轨；遗留 `withCaptions:true` 同步
/// 路径用）。track-list-first 的应用内播放器改走 [resolveYoutubeCaptionTracks] +
/// [resolveYoutubeCaptionCues] 懒加载，不再走此入口。best-effort：任何失败返回空 cue。
Future<List<AudioCue>> resolveYoutubeCaptions(
  String url, {
  String preferSubtitleLang = 'ja',
}) async {
  final yt.VideoId videoId;
  try {
    videoId = yt.VideoId(url);
  } catch (_) {
    return const <AudioCue>[];
  }
  return _resolveBestCaptionCues(
    videoId,
    'yt:${videoId.value}',
    preferSubtitleLang,
  );
}

/// IO：取「最佳单轨」cue（A3 人工>ASR·精确语言，[pickBestYoutubeCaptionTrack]）：
/// [_fetchCaptionTracks] → 选最佳 → [resolveYoutubeCaptionCues] 懒下载那一轨。无字幕轨返回
/// 空 cue。供 `withCaptions:true` 同步路径与 [resolveYoutubeCaptions] 复用。
Future<List<AudioCue>> _resolveBestCaptionCues(
  yt.VideoId id,
  String bookKey,
  String preferLang,
) async {
  final List<YoutubeCaptionTrack> tracks = await _fetchCaptionTracks(id);
  final YoutubeCaptionTrack? best =
      pickBestYoutubeCaptionTrack(tracks, preferLang: preferLang);
  if (best == null) return const <AudioCue>[];
  return resolveYoutubeCaptionCues(best, bookKey: bookKey);
}
