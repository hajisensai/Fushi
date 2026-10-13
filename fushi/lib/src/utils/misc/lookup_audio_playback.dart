import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/audio_mime.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/local_audio_db.dart'
    show LocalAudioUnavailableError, LocalAudioUnavailableReason;
import 'package:fushi/src/utils/misc/tts_channel.dart';
import 'package:fushi/src/utils/misc/word_audio_resolver.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiDicts;
import 'package:fushi_engine/dictionary/dictionary_media_types.dart'
    show normalizeDictionaryMediaPath;

/// 单次本地音频库查询的**预算**上限：超过就不再等，把控制权还给 UI
/// （自动发音不能为了一个库把查词卡住）。
///
/// ⚠️ 这个值比 [LocalAudioDb] 只读连接自己的 `busy_timeout = 3000` **短**，
/// 所以库一旦真被占用，永远是这里先到点——[LocalAudioDb] 的 BUSY 分类根本
/// 来不及触发。因此预算耗尽必须**也**归成 [LocalAudioUnavailableError]
/// （BUG-1413）：旧实现 `return null` 与「库里真没这个词」同形，而且连一条
/// 日志都没有，是整条链上最静默的一个 fail-open 出口。
///
/// 预算本身不改（保持既有 500ms 手感）——改的是「预算耗尽」的**含义**：
/// 它是「没查出来」，不是「查出来没有」。
const Duration kLocalAudioQueryBudget = Duration(milliseconds: 500);

/// Resolves and plays the audio for [expression] / [reading] exactly like Hoshi:
/// enabled sources only, no TTS fallback.
///
/// 单一真相：收口自 base_source_page._playAutoReadWord 与
/// dictionary_page_mixin._playAutoReadWord 两份逐行相同的实现。两者唯一差异是
/// AppModel 的取法（[appModel] 现作参数），装配/超时/解析/播放完全一致。
Future<void> playLookupAudio(
  AppModel appModel,
  String expression,
  String reading,
) async {
  final String? url =
      await resolveLookupAudioUrl(appModel, expression, reading);
  if (url == null || url.isEmpty) return;

  // Plays remote URLs and local file paths uniformly, including Windows
  // drive-letter paths (BUG-046).
  await TtsChannel.instance.playAudioRef(
    url,
    volume: ReaderFushiSource.instance.lookupAudioVolumeGain,
  );
}

/// Resolves (but does not play) the configured-source audio URL/path for
/// [expression] / [reading] — enabled sources only, no TTS fallback. Single
/// source of truth shared by [playLookupAudio] and the global-lookup overlay's
/// two-step bridge (resolveWordAudio -> url, then playWordAudio -> play).
Future<String?> resolveLookupAudioUrl(
  AppModel appModel,
  String expression,
  String reading,
) async {
  return _buildLookupAudioResolver(appModel).resolveConfigured(
    expression: expression,
    reading: reading,
    sources: appModel.audioSourceConfigs,
  );
}

/// 「选择音频源」菜单的数据源：每个启用源各自解析出的全部候选（按配置顺序，
/// 远端列表型源展开成多个变体）。与 [resolveLookupAudioUrl] 共用同一个装配好的
/// [WordAudioResolver]（同样的本地库预算、远端冷却、互联查询），所以首项就是
/// 单击 ♪ 会播的那条。
Future<List<WordAudioCandidate>> listLookupAudioCandidates(
  AppModel appModel,
  String expression,
  String reading,
) {
  return _buildLookupAudioResolver(appModel).listConfigured(
    expression: expression,
    reading: reading,
    sources: appModel.audioSourceConfigs,
  );
}

/// 菜单里一项的源显示名：用户起的名字优先；互联源用 i18n 名；没起名的远端源
/// 用 host（整条模板 URL 带 `{term}` 占位，塞进菜单既长又看不懂）。
String lookupAudioSourceDisplayName(AudioSourceConfig source) {
  final String label = source.label?.trim() ?? '';
  if (label.isNotEmpty) return label;
  switch (source.kind) {
    case AudioSourceKind.fushiRemote:
      return t.audio_source_fushi_interconnect;
    case AudioSourceKind.localAudio:
      return source.displayLabel;
    case AudioSourceKind.remoteAudio:
      final String url = source.url ?? '';
      final String host = Uri.tryParse(
                  url.replaceAll('{term}', 'x').replaceAll('{reading}', 'x'))
              ?.host ??
          '';
      return host.isNotEmpty ? host : url;
  }
}

/// 「选择音频源」菜单的弹窗桥返回值（`listWordAudioSources`）：每项
/// `{name, variant, url}`，`url` 已经过 [audioRefToWebViewUrl]，弹窗 `<audio>`
/// 可直接播放。转不出可播 URL 的候选（本地文件已不在）直接跳过。
Future<List<Map<String, String>>> listWordAudioWebViewChoices(
  AppModel appModel,
  String expression,
  String reading,
) async {
  final List<WordAudioCandidate> candidates =
      await listLookupAudioCandidates(appModel, expression, reading);
  final List<String?> urls = await Future.wait(<Future<String?>>[
    for (final WordAudioCandidate c in candidates) audioRefToWebViewUrl(c.ref),
  ]);
  return <Map<String, String>>[
    for (int i = 0; i < candidates.length; i++)
      if (urls[i] != null && urls[i]!.isNotEmpty)
        <String, String>{
          'name': lookupAudioSourceDisplayName(candidates[i].source),
          'variant': candidates[i].variant,
          'url': urls[i]!,
        },
  ];
}

WordAudioResolver _buildLookupAudioResolver(AppModel appModel) {
  return WordAudioResolver(
    queryLocalAudio: (expression, reading) async {
      try {
        return await TtsChannel.instance
            .queryLocalAudio(expression, reading)
            .timeout(kLocalAudioQueryBudget);
      } on TimeoutException {
        throw const LocalAudioUnavailableError(
          reason: LocalAudioUnavailableReason.timedOut,
        );
      }
    },
    queryLocalAudioByDbIndex: (expression, reading, dbIndex) async {
      try {
        return await TtsChannel.instance
            .queryLocalAudio(expression, reading, dbIndex: dbIndex)
            .timeout(kLocalAudioQueryBudget);
      } on TimeoutException {
        throw const LocalAudioUnavailableError(
          reason: LocalAudioUnavailableReason.timedOut,
        );
      }
    },
    extractLocalAudio: TtsChannel.instance.extractLocalAudio,
    queryRemoteAudio: (expression, reading) => appModel.lookupRemoteAudio(
      expression,
      reading,
    ),
  );
}

/// Auto-read a word, preferring the popup's own HTML5 `<audio>` element (the
/// unified fast path — no native/libmpv round-trip) and falling back to the Dart
/// player when the WebView is not ready or its `audio.play()` actually failed
/// (e.g. the platform autoplay policy blocked a document with no user
/// activation, BUG-1093), so auto-read never silently drops (Never break
/// userspace).
///
/// [playInWebView] plays an already-resolved WebView URL in the popup and
/// returns whether playback truly started (the popup reports the real
/// `audio.play()` outcome back over the `wordAudioPlayed` bridge); pass null
/// when this surface has no popup WebView (e.g. an inline full-page view),
/// which goes straight to the Dart fallback.
///
/// The audio ref is resolved exactly once and shared by both play paths — the
/// fallback must never re-resolve (a second resolve re-opens local DBs and
/// re-fires remote requests, and a transient remote failure would put the
/// source into cooldown twice).
///
/// Returns whether playback ACTUALLY started on either path (BUG-1127: the
/// caller-side dedupe window must not stay occupied by a silent failure).
Future<bool> autoReadWordUnified(
  AppModel appModel,
  String expression,
  String reading, {
  required Future<bool> Function(String url)? playInWebView,
}) async {
  final String? ref =
      await resolveLookupAudioUrl(appModel, expression, reading);
  return playResolvedLookupAudio(
    ref,
    label: expression,
    playInWebView: playInWebView,
  );
}

/// [autoReadWordUnified] 的播放半段：[ref] 已解析好（本机音频源，或别的设备给的
/// 发音——手机字幕遥控器查电脑的词典时，发音来自那台电脑），先交给弹窗 WebView 自己
/// 的 `<audio>` 播，失败再回落 Dart 播放器。[label] 只用于诊断留痕。
Future<bool> playResolvedLookupAudio(
  String? ref, {
  required String label,
  required Future<bool> Function(String url)? playInWebView,
}) async {
  if (ref == null || ref.isEmpty) return false;

  // BUG-3311：Android 主引擎上单词音频一律交原生播放器（不申请音频焦点），
  // 不再经弹窗 <audio>——见 [lookupWordAudioPlaysNatively]。
  if (playInWebView != null && !lookupWordAudioPlaysNatively) {
    final String? url = await audioRefToWebViewUrl(ref);
    if (url != null && url.isNotEmpty) {
      if (await playInWebView(url)) return true;
      // The WebView reported a real failure (autoplay blocked / JS error /
      // bridge timeout). Record it — this exact silence used to be invisible
      // (zero logs) and cost a mis-rooted fix in BUG-1015 — then fall back.
      ErrorLogService.instance.logDiagnostic(
        'autoReadWordUnified',
        'WebView 播放失败（autoplay 拦截/未就绪/JS 异常），回落 Dart 播放器：'
            '$label',
      );
    }
  }

  return await TtsChannel.instance.playAudioRef(
    ref,
    volume: ReaderFushiSource.instance.lookupAudioVolumeGain,
  );
}

/// 单词音频是否改走宿主原生播放器而不是弹窗 WebView 的 `<audio>`（BUG-3311）。
///
/// Android WebView 的 `<audio>` 一出声，Chromium 的 `AudioFocusDelegate` 就以
/// `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` 向系统申请音频焦点（`dumpsys audio` 实测
/// `req=3`），宿主没有任何开关能关掉它；部分 ROM（联想 ZUI，反馈 #D5hTCEYMmT）据此
/// 把 app 自己正在播的视频一起压低数秒。原生 `TtsChannelHandler` 的 MediaPlayer
/// 不申请焦点，读一个一秒的词不该去抢系统焦点。
///
/// 只在 Android **主引擎**为真：原生播放器只注册在主 Activity 的引擎上，弹窗词典 /
/// 悬浮词典的副引擎仍走 WebView `<audio>`（见 [TtsChannel.hostPlaybackRegistered]）。
bool get lookupWordAudioPlaysNatively => TtsChannel.hostPlaybackRegistered;

/// 弹窗 `playWordAudioNative` 桥的落地：把 popup.js 手里的可播 URL（远端
/// `http(s)://`、本地文件转成的 `data:` URL，见 [audioRefToWebViewUrl]；或词典
/// 释义里 `sound://` 链接改写成的 `image://?dictionary=&path=` 词典媒体 URL）交原生
/// 播放器播放。返回是否真的开始播放（远端源要等原生 prepare 完、start 成功才回
/// true）；false 时 popup.js 回落 `<audio>`。
Future<bool> playWordAudioUrlNatively(String url) async {
  final String? ref = await webViewWordAudioUrlToPlayableRef(url);
  if (ref == null) return false;
  return TtsChannel.instance.playAudioRef(
    ref,
    volume: ReaderFushiSource.instance.lookupAudioVolumeGain,
  );
}

/// 读一条词典媒体的字节（与弹窗 `image://` scheme 拦截器同一字节源）。
typedef DictionaryMediaBytesLoader = Uint8List? Function(
  String dictionary,
  String path,
);

Uint8List? _loadDictionaryMediaBytes(String dictionary, String path) {
  if (!FushiDicts.isInitialized) return null;
  return FushiDicts.instance.getMediaFile(dictionary, path);
}

/// 单词音频落盘缓存目录（`systemTemp/fushi_word_audio`）最多保留的文件数；超出按
/// mtime 淘汰最旧的。每段都是一两秒的词音频，几十个足够覆盖「反复点同一批词」。
const int kWordAudioCacheMaxFiles = 64;

/// [audioRefToWebViewUrl] 的逆向：`http(s)://` 原样返回；`data:` URL 解码、
/// `image://?dictionary=&path=` 词典媒体 URL 取出字节，落到缓存目录下按内容寻址的
/// 文件（同一段音频复用同一文件，播放中的文件不会被下一次播放覆写），返回其路径。
/// 目录最多留 [maxCacheFiles] 个文件，按 mtime 淘汰最旧（复用时刷新 mtime）。
/// 其它形态、取不到字节或解码失败返回 null。
Future<String?> webViewWordAudioUrlToPlayableRef(
  String url, {
  Directory? cacheDir,
  DictionaryMediaBytesLoader loadDictionaryMedia = _loadDictionaryMediaBytes,
  int maxCacheFiles = kWordAudioCacheMaxFiles,
}) async {
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  final (Uint8List, String)? payload =
      _decodeWordAudioPayload(url, loadDictionaryMedia);
  if (payload == null) return null;
  final (Uint8List bytes, String fileExt) = payload;
  final Directory dir = cacheDir ??
      Directory('${Directory.systemTemp.path}${Platform.pathSeparator}'
          'fushi_word_audio');
  await dir.create(recursive: true);
  final String name = '${md5.convert(bytes)}.$fileExt';
  final File file = File('${dir.path}${Platform.pathSeparator}$name');
  if (!await file.exists() || await file.length() != bytes.length) {
    await file.writeAsBytes(bytes, flush: true);
  } else {
    // 复用即续命：淘汰按 mtime，刚要播的这段不能被当成最旧的删掉。
    await file.setLastModified(DateTime.now());
  }
  _pruneWordAudioCache(dir, keep: file.path, maxFiles: maxCacheFiles);
  return file.path;
}

/// 把 popup 交来的非 http URL 解成「字节 + 落盘扩展名」；认不出 / 空载荷回 null。
(Uint8List, String)? _decodeWordAudioPayload(
  String url,
  DictionaryMediaBytesLoader loadDictionaryMedia,
) {
  if (url.startsWith('data:')) {
    final UriData data;
    try {
      data = UriData.parse(url);
    } on FormatException {
      return null;
    }
    final Uint8List bytes = data.contentAsBytes();
    if (bytes.isEmpty) return null;
    return (bytes, _audioExtensionForMime(data.mimeType));
  }
  if (url.startsWith('image:')) {
    // popup.js rewriteDictionaryMediaPath 的产物：
    // `image://?dictionary=<enc>&path=<enc>`，与 scheme 拦截器同一解析口径。
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return null;
    final String dictionary = uri.queryParameters['dictionary'] ?? '';
    final String path =
        normalizeDictionaryMediaPath(uri.queryParameters['path'] ?? '');
    if (dictionary.isEmpty || path.isEmpty) return null;
    final Uint8List? bytes = loadDictionaryMedia(dictionary, path);
    if (bytes == null || bytes.isEmpty) return null;
    return (bytes, _audioExtensionForMediaPath(path));
  }
  return null;
}

/// 把 [dir] 收到至多 [maxFiles] 个文件：按 mtime 从旧到新删，[keep] 永不删。
/// 用 listSync（目录很小；异步 list 在 widget 测试的 fake-async 里永不完成）。
/// 单个文件删不掉（已被并发删除等）只跳过它——下一次播放会再收一次。
void _pruneWordAudioCache(
  Directory dir, {
  required String keep,
  required int maxFiles,
}) {
  final List<File> files = dir.listSync().whereType<File>().toList();
  if (files.length <= maxFiles) return;
  final List<(File, DateTime)> aged = <(File, DateTime)>[];
  for (final File f in files) {
    if (f.path == keep) continue;
    try {
      aged.add((f, f.lastModifiedSync()));
    } on FileSystemException {
      continue;
    }
  }
  aged.sort(
    ((File, DateTime) a, (File, DateTime) b) => a.$2.compareTo(b.$2),
  );
  final int excess = files.length - maxFiles;
  for (final (File f, DateTime _) in aged.take(excess)) {
    try {
      f.deleteSync();
    } on FileSystemException {
      continue;
    }
  }
}

/// 词典媒体路径的扩展名（MDX 的 `.spx` / `.wav` 等原样保留，只是给人看的提示；
/// 原生 MediaPlayer 按内容嗅探）。没有或不像扩展名时用 `mp3`。
String _audioExtensionForMediaPath(String path) {
  final String name = path.substring(path.lastIndexOf('/') + 1);
  final int dot = name.lastIndexOf('.');
  final String ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : 'mp3';
}

/// `data:` URL 的 MIME → 落盘扩展名（[kAudioMimeByExtension] 的反查，取首个命中；
/// 原生 MediaPlayer 按内容嗅探，扩展名只是给人看的提示）。
String _audioExtensionForMime(String mime) {
  for (final MapEntry<String, String> e in kAudioMimeByExtension.entries) {
    if (e.value == mime) return e.key;
  }
  return 'mp3';
}

/// Resolves word audio for [expression] / [reading] into a URL that an HTML5
/// `<audio>` element inside the popup WebView can play directly on **every**
/// surface — the in-app InAppWebView, the app-external overlay WebView2, and the
/// browser extension. This is the single unified word-audio play path: instead
/// of handing the ref back to a native player (Android `MediaPlayer`) or libmpv
/// (desktop `just_audio`), the popup plays it itself, exactly like the browser
/// extension already does (`assets/browser_extension/bridge-shim.js`).
///
/// See [audioRefToWebViewUrl] for the ref → URL conversion. Returns null when no
/// enabled source resolves.
Future<String?> resolveWordAudioWebViewUrl(
  AppModel appModel,
  String expression,
  String reading,
) async =>
    audioRefToWebViewUrl(
        await resolveLookupAudioUrl(appModel, expression, reading));

/// Converts a resolved audio ref (from [resolveLookupAudioUrl] /
/// [WordAudioResolver], i.e. a remote `http(s)://` URL **or** a local file path)
/// into a URL an HTML5 `<audio>` element can load with no per-WebView custom
/// scheme or native file handler:
///  - remote `http(s)://` refs pass through so `<audio>` streams them directly;
///  - a local file becomes a base64 `data:<mime>;base64,…` URL.
///
/// A `data:` URL is used (rather than a custom `audio://` scheme) precisely so
/// the app-external overlay's **native** WebView2 window needs zero native
/// changes — every WebView host can already play a `data:` URL. Word-audio clips
/// are small (tens of KB), so the one-time base64 is negligible and popup.js
/// caches the result per entry.
///
/// Returns null when [ref] is empty or the local file is missing.
Future<String?> audioRefToWebViewUrl(String? ref) async {
  if (ref == null || ref.isEmpty) return null;
  if (ref.startsWith('http')) return ref;
  final String path =
      ref.startsWith('file://') ? Uri.parse(ref).toFilePath() : ref;
  final File file = File(path);
  if (!await file.exists()) return null;
  final Uint8List bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  final String mime = audioMimeForPath(path);
  return 'data:$mime;base64,${base64Encode(bytes)}';
}

/// Audio Content-Type by file extension for `data:` URLs, so the WebView picks
/// the right decoder. Covers the formats the local-audio libraries emit
/// (Yomitan local audio server: mp3 / opus; plus common fallbacks). Unknown
/// extensions fall back to `audio/mpeg` — a `data:` URL is never
/// content-sniffed, so a definite audio/* type is required, and the Anki side
/// derives the media file extension back from this MIME (mp3 is the dominant
/// word-audio format). The extension → MIME mapping itself is the shared
/// [kAudioMimeByExtension] table (audio_mime.dart), also consumed by the sync
/// server's `remoteAudioContentTypeForPath` with its own octet-stream fallback.
String audioMimeForPath(String path) =>
    audioMimeForPathWithFallback(path, fallback: 'audio/mpeg');
