import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/misc/audio_mime.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/local_audio_db.dart'
    show LocalAudioUnavailableError, LocalAudioUnavailableReason;
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki/src/utils/misc/word_audio_resolver.dart';

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
    volume: ReaderHibikiSource.instance.lookupAudioVolumeGain,
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
  final WordAudioResolver resolver = WordAudioResolver(
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
  return resolver.resolveConfigured(
    expression: expression,
    reading: reading,
    sources: appModel.audioSourceConfigs,
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
  if (ref == null || ref.isEmpty) return false;

  if (playInWebView != null) {
    final String? url = await audioRefToWebViewUrl(ref);
    if (url != null && url.isNotEmpty) {
      if (await playInWebView(url)) return true;
      // The WebView reported a real failure (autoplay blocked / JS error /
      // bridge timeout). Record it — this exact silence used to be invisible
      // (zero logs) and cost a mis-rooted fix in BUG-1015 — then fall back.
      ErrorLogService.instance.logDiagnostic(
        'autoReadWordUnified',
        'WebView 播放失败（autoplay 拦截/未就绪/JS 异常），回落 Dart 播放器：'
            '$expression',
      );
    }
  }

  return await TtsChannel.instance.playAudioRef(
    ref,
    volume: ReaderHibikiSource.instance.lookupAudioVolumeGain,
  );
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
