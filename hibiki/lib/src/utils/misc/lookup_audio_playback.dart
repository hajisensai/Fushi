import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki/src/utils/misc/word_audio_resolver.dart';

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
            .timeout(const Duration(milliseconds: 500));
      } on TimeoutException {
        return null;
      }
    },
    queryLocalAudioByDbIndex: (expression, reading, dbIndex) async {
      try {
        return await TtsChannel.instance
            .queryLocalAudio(expression, reading, dbIndex: dbIndex)
            .timeout(const Duration(milliseconds: 500));
      } on TimeoutException {
        return null;
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
/// player when no ready popup WebView is available, so auto-read never silently
/// drops (Never break userspace).
///
/// [playInWebView] plays an already-resolved WebView URL in the popup and
/// returns whether it actually did (false when the WebView is not ready); pass
/// null when this surface has no popup WebView (e.g. an inline full-page view),
/// which goes straight to the Dart fallback.
Future<void> autoReadWordUnified(
  AppModel appModel,
  String expression,
  String reading, {
  required Future<bool> Function(String url)? playInWebView,
}) async {
  if (playInWebView != null) {
    final String? url =
        await resolveWordAudioWebViewUrl(appModel, expression, reading);
    if (url != null && url.isNotEmpty && await playInWebView(url)) return;
  }
  await playLookupAudio(appModel, expression, reading);
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
/// extensions fall back to `audio/mpeg` (the dominant word-audio format).
String audioMimeForPath(String path) {
  final String ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'mp3':
      return 'audio/mpeg';
    case 'opus':
    case 'ogg':
    case 'oga':
      return 'audio/ogg';
    case 'm4a':
    case 'mp4':
    case 'aac':
      return 'audio/mp4';
    case 'wav':
      return 'audio/wav';
    case 'flac':
      return 'audio/flac';
    case 'webm':
      return 'audio/webm';
    default:
      return 'audio/mpeg';
  }
}
