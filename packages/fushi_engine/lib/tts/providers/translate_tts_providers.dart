/// 翻译服务的朗读接口（免费、无需用户密钥、**非官方**）：
/// - 微软翻译：照微软翻译 Android 客户端的做法，先向
///   `dev.microsofttranslator.com/apps/endpoint` 发带 HMAC 签名的请求换一枚短期
///   语音令牌（区域 + JWT），再拿它调 `<区域>.tts.speech.microsoft.com` 的
///   `cognitiveservices/v1`（SSML，神经声音名与 Edge / Azure 同一套），返回 MP3。
///   旧做法（`bing.com/translator` 网页取 IG / token 再 POST `tfettts`）已被服务端
///   弃用（2026-11 实测回 HTTP 500 空正文）。
/// - 谷歌翻译：`translate.google.com/translate_tts?client=tw-ob`，按语言选声音（每种
///   语言一个声音），单次约 200 字，返回 MP3。
///
/// 两者都可能随服务端改版失效或被限流，设置页标注「非官方」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:fushi_engine/tts/providers/edge_tts_provider.dart'
    show parseMicrosoftVoiceList;
import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

const String _browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0';

class MicrosoftTranslatorTtsDescriptor extends TtsProviderDescriptor {
  const MicrosoftTranslatorTtsDescriptor();

  /// 冻结的持久化名（预设里存的就是它），换协议不换 id。
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

/// 微软翻译 Android 客户端换取语音令牌的协议常量（非官方，照抄客户端行为）。
abstract final class MicrosoftTranslatorProtocol {
  /// 令牌端点：带签名的空 POST，回 `{"r": 区域, "t": JWT}`。
  static final Uri tokenEndpoint = Uri.parse(
    'https://dev.microsofttranslator.com/apps/endpoint?api-version=1.0',
  );

  static const String application = 'MSTranslatorAndroidApp';
  static const String clientVersion = '4.0.530a 5fe1dc6c';

  /// 客户端公开的签名常量（不是任何用户的 Azure 订阅密钥）。
  static const String signingKey =
      'oik6PdDdMnOXemTbwvMn9de/h9lFnfBaCWbGMMZqqoSaQaqUOqjVGm5NqsmjcBI1x+sS9ugjB55HEJWRiFXYFw==';

  /// 区域名只认 Azure 区域的字符集：它要拼进主机名，不能让响应改写目标域。
  static final RegExp regionPattern = RegExp(r'^[a-z][a-z0-9]{1,39}$');

  static const List<String> _weekdays = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  static const List<String> _months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// RFC 1123 日期（`Wed, 04 Nov 2026 15:38:01 GMT`），按 UTC。
  static String httpDate(DateTime time) {
    final DateTime u = time.toUtc();
    return '${_weekdays[u.weekday - 1]}, ${_two(u.day)} ${_months[u.month - 1]} '
        '${u.year} ${_two(u.hour)}:${_two(u.minute)}:${_two(u.second)} GMT';
  }

  /// `X-MT-Signature` 头：`应用::HMAC-SHA256(base64)::小写日期::nonce`，
  /// 被签名串 = 小写(应用 + URL 编码的「去掉协议的端点」+ 日期 + nonce)。
  static String signature({
    required DateTime now,
    required String nonce,
    Uri? endpoint,
  }) {
    final Uri target = endpoint ?? tokenEndpoint;
    final String date = httpDate(now).toLowerCase();
    final String withoutScheme = target.toString().substring(
      target.scheme.length + 3,
    );
    final String input =
        '$application${Uri.encodeQueryComponent(withoutScheme)}$date$nonce'
            .toLowerCase();
    final Digest mac = Hmac(
      sha256,
      base64.decode(signingKey),
    ).convert(utf8.encode(input));
    return '$application::${base64.encode(mac.bytes)}::$date::$nonce';
  }

  /// 解析令牌端点的响应。形状不对 / 区域非法 / JWT 已过期一律
  /// [TtsFailureCode.badResponse]（接口改版的信号，不猜）。
  static MicrosoftTranslatorToken parseToken(
    String body, {
    required DateTime now,
  }) {
    const TtsFailure bad = TtsFailure(
      TtsFailureCode.badResponse,
      'translator token',
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw bad;
    }
    if (decoded is! Map) throw bad;
    final Object? region = decoded['r'];
    final Object? bearer = decoded['t'];
    if (region is! String || !regionPattern.hasMatch(region)) throw bad;
    if (bearer is! String ||
        bearer.isEmpty ||
        bearer.length > 16384 ||
        bearer.codeUnits.any((int c) => c <= 0x20 || c >= 0x7f)) {
      throw bad;
    }
    final List<String> parts = bearer.split('.');
    if (parts.length != 3 || parts.any((String s) => s.isEmpty)) throw bad;
    final Object? claims;
    try {
      claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
    } on FormatException {
      throw bad;
    }
    if (claims is! Map) throw bad;
    final Object? exp = claims['exp'];
    if (exp is! int) throw bad;
    final DateTime expiresAt = DateTime.fromMillisecondsSinceEpoch(
      exp * 1000,
      isUtc: true,
    );
    if (!expiresAt.isAfter(now)) throw bad;
    return MicrosoftTranslatorToken(
      region: region,
      bearer: bearer,
      expiresAt: expiresAt,
    );
  }
}

/// 一枚语音令牌：[region] 决定合成主机，[bearer] 是短期 JWT（约十分钟）。
class MicrosoftTranslatorToken {
  const MicrosoftTranslatorToken({
    required this.region,
    required this.bearer,
    required this.expiresAt,
  });

  final String region;
  final String bearer;
  final DateTime expiresAt;
}

/// 令牌会话：进程内共用、只在内存、不落盘。并发的多句合成共享同一次换取
/// （single-flight），临期一分钟内视作过期。
class MicrosoftTranslatorSession {
  MicrosoftTranslatorSession({
    Uri? tokenEndpoint,
    DateTime Function()? clock,
    Random? random,
  }) : tokenEndpoint =
           tokenEndpoint ?? MicrosoftTranslatorProtocol.tokenEndpoint,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  /// app 内所有微软翻译声音共用的会话。
  static final MicrosoftTranslatorSession shared = MicrosoftTranslatorSession();

  final Uri tokenEndpoint;
  final DateTime Function() _clock;
  final Random _random;

  late final String _userId = _hex(8);
  MicrosoftTranslatorToken? _cached;
  Future<MicrosoftTranslatorToken>? _pending;

  String _hex(int bytes) => <String>[
    for (int i = 0; i < bytes; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  String _uuid() {
    final String h = _hex(16);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// 有效令牌（必要时去换）。失败抛 [TtsFailure]。
  Future<MicrosoftTranslatorToken> token(HttpClient Function() clientFactory) {
    final MicrosoftTranslatorToken? cached = _cached;
    if (cached != null &&
        cached.expiresAt.isAfter(_clock().add(const Duration(minutes: 1)))) {
      return Future<MicrosoftTranslatorToken>.value(cached);
    }
    return _pending ??= _fetch(clientFactory).whenComplete(() {
      _pending = null;
    });
  }

  /// 合成端拒收了 [stale]（服务端提前作废）：丢掉它，下次 [token] 重新换。
  void invalidate(MicrosoftTranslatorToken stale) {
    if (identical(_cached, stale)) _cached = null;
  }

  Future<MicrosoftTranslatorToken> _fetch(
    HttpClient Function() clientFactory,
  ) async {
    final HttpClient client = clientFactory();
    try {
      final DateTime now = _clock();
      final HttpClientRequest req = await client
          .postUrl(tokenEndpoint)
          .timeout(const Duration(seconds: 20));
      req.followRedirects = false;
      req.headers
        ..set('X-ClientVersion', MicrosoftTranslatorProtocol.clientVersion)
        ..set('X-UserId', _userId)
        ..set('X-ClientTraceId', _uuid())
        ..set(
          'X-MT-Signature',
          MicrosoftTranslatorProtocol.signature(
            now: now,
            nonce: _hex(16),
            endpoint: tokenEndpoint,
          ),
        )
        ..set(HttpHeaders.acceptLanguageHeader, 'ja-JP');
      req.contentLength = 0;
      final HttpClientResponse res = await req.close().timeout(
        const Duration(seconds: 20),
      );
      if (res.statusCode != 200) {
        await res.drain<void>().catchError((Object _) {});
        throw ttsFailureForStatus(
          res.statusCode,
          retryAfter: ttsParseRetryAfter(
            res.headers.value(HttpHeaders.retryAfterHeader),
          ),
        );
      }
      final String body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
      return _cached = MicrosoftTranslatorProtocol.parseToken(body, now: now);
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
}

/// 合成主机：`<区域>.tts.speech.microsoft.com`（与 Azure 官方同一套 REST）。
Uri microsoftTranslatorSpeechBase(String region) =>
    Uri.https('$region.tts.speech.microsoft.com');

/// 声音名 `ja-JP-NanamiNeural` / `yue-CN-XiaoMinNeural` 的语言区域（前两段）。
String microsoftVoiceLocale(String voice) {
  final List<String> parts = voice.split('-');
  return parts.length >= 3 ? '${parts[0]}-${parts[1]}' : 'ja-JP';
}

class MicrosoftTranslatorTtsProvider extends TtsProvider {
  MicrosoftTranslatorTtsProvider({
    required this.voice,
    required TtsHost host,
    MicrosoftTranslatorSession? session,
    Uri Function(String region)? speechBase,
  }) : _host = host,
       _session = session ?? MicrosoftTranslatorSession.shared,
       _speechBase = speechBase ?? microsoftTranslatorSpeechBase;

  final String voice;
  final TtsHost _host;
  final MicrosoftTranslatorSession _session;
  final Uri Function(String region) _speechBase;

  @override
  TtsCapabilities get capabilities =>
      const MicrosoftTranslatorTtsDescriptor().capabilities;

  static String ssml(String voice, String text) {
    final String lang = ttsEscapeXml(microsoftVoiceLocale(voice));
    return "<speak version='1.0' xml:lang='$lang'>"
        "<voice xml:lang='$lang' name='${ttsEscapeXml(voice)}'>"
        '${ttsEscapeXml(text)}</voice></speak>';
  }

  /// 用令牌发一次请求；令牌被拒（401/403）时换一枚新令牌再发一次——JWT 只有约
  /// 十分钟寿命，服务端可能早于 `exp` 作废，这是协议内的正常续期，不是兜底重试。
  /// 新令牌仍被拒就如实上报。
  Future<T> _authorized<T>(
    Future<T> Function(MicrosoftTranslatorToken token) send,
  ) async {
    final MicrosoftTranslatorToken first = await _session.token(
      _host.httpClientFactory,
    );
    try {
      return await send(first);
    } on TtsFailure catch (failure) {
      if (failure.code != TtsFailureCode.unauthorized) rethrow;
      _session.invalidate(first);
      return send(await _session.token(_host.httpClientFactory));
    }
  }

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    cancel.throwIfCancelled();
    final List<int> body = utf8.encode(ssml(voice, text));
    await _authorized<void>((MicrosoftTranslatorToken token) async {
      final HttpClient client = _host.httpClientFactory();
      try {
        await ttsSendToFile(
          client: client,
          method: 'POST',
          uri: _speechBase(token.region).replace(path: '/cognitiveservices/v1'),
          outputPath: outputPath,
          cancel: cancel,
          body: body,
          headers: <String, String>{
            HttpHeaders.authorizationHeader: 'Bearer ${token.bearer}',
            HttpHeaders.contentTypeHeader: 'application/ssml+xml',
            'X-Microsoft-OutputFormat': 'audio-24khz-48kbitrate-mono-mp3',
            HttpHeaders.userAgentHeader: 'Fushi',
          },
        );
      } finally {
        client.close(force: true);
      }
    });
    return const TtsResult(format: TtsAudioFormat.mp3);
  }

  /// 声音列表直接问合成端（与能合成的声音严格一致）。
  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) =>
      _authorized<List<TtsVoice>>((MicrosoftTranslatorToken token) async {
        final HttpClient client = _host.httpClientFactory();
        try {
          return parseMicrosoftVoiceList(
            await ttsGetJson(
              client: client,
              uri: _speechBase(
                token.region,
              ).replace(path: '/cognitiveservices/voices/list'),
              headers: <String, String>{
                HttpHeaders.authorizationHeader: 'Bearer ${token.bearer}',
                HttpHeaders.userAgentHeader: 'Fushi',
              },
              cancel: cancel,
            ),
          );
        } finally {
          client.close(force: true);
        }
      });
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
