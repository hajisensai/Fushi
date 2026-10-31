/// 翻译网站的朗读接口（免费、无需密钥、**非官方**）：
/// - 微软翻译：`bing.com/translator` 页面里取 IG / IID / 防滥用 key+token，再 POST
///   `tfettts`（SSML，神经声音名与 Edge / Azure 同一套），返回 MP3；
/// - 谷歌翻译：`translate.google.com/translate_tts?client=tw-ob`，按语言选声音（每种
///   语言一个声音），单次约 200 字，返回 MP3。
///
/// 两者都可能随网站改版失效或被限流，设置页标注「非官方」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

const String _browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0';

class MicrosoftTranslatorTtsDescriptor extends TtsProviderDescriptor {
  const MicrosoftTranslatorTtsDescriptor();

  static const String providerId = 'ms_translator';
  static const String voiceKey = 'voice';
  static const String defaultVoice = 'ja-JP-NanamiNeural';

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: true,
    needsCredential: false,
    maxConcurrency: 1,
    maxInputLength: 300,
  );

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[
    TtsParamSpec(
      key: voiceKey,
      kind: TtsParamKind.voice,
      required: true,
      defaultValue: defaultVoice,
    ),
  ];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      MicrosoftTranslatorTtsProvider(
        voice: preset.param(voiceKey, fallback: defaultVoice),
        host: host,
      );
}

/// 微软翻译页面的会话凭据（约一小时有效）。
class _TranslatorSession {
  const _TranslatorSession({
    required this.host,
    required this.ig,
    required this.iid,
    required this.key,
    required this.token,
    required this.cookies,
    required this.expiresAt,
  });

  final String host;
  final String ig;
  final String iid;
  final String key;
  final String token;
  final List<Cookie> cookies;
  final DateTime expiresAt;
}

class MicrosoftTranslatorTtsProvider extends TtsProvider {
  MicrosoftTranslatorTtsProvider({required this.voice, required TtsHost host})
    : _host = host;

  final String voice;
  final TtsHost _host;

  /// 全进程共用一份会话：每句都去抓一次页面会被当成滥用。
  static _TranslatorSession? _session;
  static int _requestCount = 0;

  @override
  TtsCapabilities get capabilities =>
      const MicrosoftTranslatorTtsDescriptor().capabilities;

  /// 从翻译页 HTML 里取会话参数；页面改版取不到返回 null。
  static ({String ig, String iid, String key, String token, int ttlMs})?
  parseTranslatorPage(String html) {
    final RegExpMatch? ig = RegExp(r'IG:"([^"]+)"').firstMatch(html);
    final RegExpMatch? iid = RegExp(r'data-iid="([^"]+)"').firstMatch(html);
    final RegExpMatch? ap = RegExp(
      r'params_AbusePreventionHelper\s*=\s*\[(\d+),"([^"]+)",(\d+)',
    ).firstMatch(html);
    if (ig == null || iid == null || ap == null) return null;
    return (
      ig: ig.group(1)!,
      iid: iid.group(1)!,
      key: ap.group(1)!,
      token: ap.group(2)!,
      ttlMs: int.tryParse(ap.group(3)!) ?? 3600000,
    );
  }

  Future<_TranslatorSession> _obtainSession({bool refresh = false}) async {
    final _TranslatorSession? cached = _session;
    if (!refresh &&
        cached != null &&
        DateTime.now().isBefore(cached.expiresAt)) {
      return cached;
    }
    final HttpClient client = _host.httpClientFactory()
      ..userAgent = _browserUserAgent;
    try {
      final HttpClientRequest req = await client
          .getUrl(Uri.parse('https://www.bing.com/translator'))
          .timeout(const Duration(seconds: 20));
      final HttpClientResponse res = await req.close().timeout(
        const Duration(seconds: 20),
      );
      if (res.statusCode != 200) {
        await res.drain<void>().catchError((Object _) {});
        throw ttsFailureForStatus(res.statusCode);
      }
      final String html = await res.transform(utf8.decoder).join();
      final ({String ig, String iid, String key, String token, int ttlMs})?
      parsed = parseTranslatorPage(html);
      if (parsed == null) {
        throw const TtsFailure(TtsFailureCode.badResponse, 'translator page');
      }
      // 重定向到 cn.bing.com 等区域站点时，tfettts 也要发到同一个主机。
      final String host = res.redirects.isEmpty
          ? 'www.bing.com'
          : res.redirects.last.location.host.isEmpty
          ? 'www.bing.com'
          : res.redirects.last.location.host;
      // 提前一分钟过期，避免临界时刻失效。
      final Duration ttl =
          Duration(milliseconds: parsed.ttlMs) - const Duration(minutes: 1);
      return _session = _TranslatorSession(
        host: host,
        ig: parsed.ig,
        iid: parsed.iid,
        key: parsed.key,
        token: parsed.token,
        cookies: res.cookies,
        expiresAt: DateTime.now().add(ttl),
      );
    } on TimeoutException {
      throw const TtsFailure(TtsFailureCode.timeout);
    } on SocketException {
      throw const TtsFailure(TtsFailureCode.network);
    } on HttpException {
      throw const TtsFailure(TtsFailureCode.network);
    } on HandshakeException {
      throw const TtsFailure(TtsFailureCode.network, 'tls');
    } finally {
      client.close(force: true);
    }
  }

  static String _ssml(String voice, String text) {
    final String lang = voice.length >= 5 ? voice.substring(0, 5) : 'ja-JP';
    return "<speak version='1.0' xml:lang='${ttsEscapeXml(lang)}'>"
        "<voice xml:lang='${ttsEscapeXml(lang)}' "
        "name='${ttsEscapeXml(voice)}'><prosody rate='0%'>"
        '${ttsEscapeXml(text)}</prosody></voice></speak>';
  }

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    try {
      await _synthesizeWith(await _obtainSession(), text, outputPath, cancel);
    } on TtsFailure catch (failure) {
      // 会话令牌提前作废（服务端轮换）只换一次令牌重试；仍失败如实上报。
      if (failure.code != TtsFailureCode.unauthorized &&
          failure.code != TtsFailureCode.rejected) {
        rethrow;
      }
      await _synthesizeWith(
        await _obtainSession(refresh: true),
        text,
        outputPath,
        cancel,
      );
    }
    return const TtsResult(format: TtsAudioFormat.mp3);
  }

  Future<void> _synthesizeWith(
    _TranslatorSession session,
    String text,
    String outputPath,
    TtsCancelToken cancel,
  ) async {
    final HttpClient client = _host.httpClientFactory()
      ..userAgent = _browserUserAgent;
    try {
      final Uri uri = Uri.https(session.host, '/tfettts', <String, String>{
        'isVertical': '1',
        'IG': session.ig,
        'IID': '${session.iid}.${++_requestCount}',
      });
      final List<int> body = utf8.encode(
        Uri(
          queryParameters: <String, String>{
            'ssml': _ssml(voice, text),
            'token': session.token,
            'key': session.key,
          },
        ).query,
      );
      await ttsSendToFile(
        client: client,
        method: 'POST',
        uri: uri,
        outputPath: outputPath,
        cancel: cancel,
        body: body,
        headers: <String, String>{
          HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
          HttpHeaders.refererHeader: 'https://${session.host}/translator',
          if (session.cookies.isNotEmpty)
            HttpHeaders.cookieHeader: session.cookies
                .map((Cookie c) => '${c.name}=${c.value}')
                .join('; '),
        },
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 声音名与 Edge 神经声音同一套：直接用 Edge 的公开声音列表。
  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    final EdgeTtsProvider edge = EdgeTtsProvider(voice: voice, host: _host);
    try {
      return await edge.listVoices(cancel: cancel);
    } finally {
      await edge.dispose();
    }
  }
}

class GoogleTranslateTtsDescriptor extends TtsProviderDescriptor {
  const GoogleTranslateTtsDescriptor();

  static const String providerId = 'google_translate';
  static const String voiceKey = 'voice';
  static const String defaultVoice = 'ja';

  /// 谷歌翻译朗读支持的常用语言（每种语言只有一个声音）。
  static const List<({String code, String name})> languages =
      <({String code, String name})>[
        (code: 'ja', name: '日本語'),
        (code: 'en', name: 'English (US)'),
        (code: 'en-GB', name: 'English (UK)'),
        (code: 'zh-CN', name: '中文（普通话）'),
        (code: 'zh-TW', name: '中文（台灣）'),
        (code: 'yue', name: '粵語'),
        (code: 'ko', name: '한국어'),
        (code: 'fr', name: 'Français'),
        (code: 'de', name: 'Deutsch'),
        (code: 'es', name: 'Español'),
        (code: 'it', name: 'Italiano'),
        (code: 'pt-BR', name: 'Português (Brasil)'),
        (code: 'ru', name: 'Русский'),
        (code: 'th', name: 'ไทย'),
        (code: 'vi', name: 'Tiếng Việt'),
        (code: 'id', name: 'Bahasa Indonesia'),
      ];

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: true,
    needsCredential: false,
    maxConcurrency: 1,
    maxInputLength: 180,
  );

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[
    TtsParamSpec(
      key: voiceKey,
      kind: TtsParamKind.voice,
      required: true,
      defaultValue: defaultVoice,
    ),
  ];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      GoogleTranslateTtsProvider(
        language: preset.param(voiceKey, fallback: defaultVoice),
        host: host,
      );
}

class GoogleTranslateTtsProvider extends TtsProvider {
  GoogleTranslateTtsProvider({required this.language, required TtsHost host})
    : _client = host.httpClientFactory()..userAgent = _browserUserAgent;

  final String language;
  final HttpClient _client;

  @override
  TtsCapabilities get capabilities =>
      const GoogleTranslateTtsDescriptor().capabilities;

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    await ttsSendToFile(
      client: _client,
      method: 'GET',
      uri: Uri.https('translate.google.com', '/translate_tts', <String, String>{
        'ie': 'UTF-8',
        'client': 'tw-ob',
        'tl': language.trim().isEmpty ? 'ja' : language.trim(),
        'q': text,
      }),
      outputPath: outputPath,
      cancel: cancel,
    );
    return const TtsResult(format: TtsAudioFormat.mp3);
  }

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async =>
      <TtsVoice>[
        for (final ({String code, String name}) l
            in GoogleTranslateTtsDescriptor.languages)
          TtsVoice(id: l.code, displayName: l.name, locale: l.code),
      ];

  @override
  Future<void> dispose() async => _client.close(force: true);
}
