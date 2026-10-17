/// 微软 Edge「大声朗读」在线语音。
///
/// **非官方接口**：协议与 rany2/edge-tts 相同（websocket + Sec-MS-GEC 令牌 + Edge
/// 版本号）。微软随时可能改协议或限流，设置页对它标注「非官方在线服务」。免费、
/// 无需密钥，返回 MP3 与逐词边界（WordBoundary）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class EdgeTtsDescriptor extends TtsProviderDescriptor {
  const EdgeTtsDescriptor();

  static const String providerId = 'edge';
  static const String voiceKey = 'voice';
  static const String defaultVoice = 'ja-JP-NanamiNeural';

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.word,
    online: true,
    needsCredential: false,
    maxConcurrency: 2,
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
  TtsProvider create(TtsVoicePreset preset, TtsHost host) => EdgeTtsProvider(
    voice: preset.param(voiceKey, fallback: defaultVoice),
    host: host,
  );
}

/// Edge 客户端身份常量（跟随 edge-tts 上游；微软拒绝旧版本号时要一起升级）。
class EdgeTtsClientIdentity {
  static const String trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const String chromiumFullVersion = '143.0.3650.75';
  static String get chromiumMajor => chromiumFullVersion.split('.').first;
  static String get secMsGecVersion => '1-$chromiumFullVersion';
  static String get userAgent =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/$chromiumMajor.0.0.0 Safari/537.36 '
      'Edg/$chromiumMajor.0.0.0';
  static const String origin =
      'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';

  /// Sec-MS-GEC：Windows 纪元 100ns tick（取整到 5 分钟）+ 令牌的 SHA-256 大写十六进制。
  static String secMsGec(DateTime nowUtc) {
    int seconds = nowUtc.millisecondsSinceEpoch ~/ 1000 + 11644473600;
    seconds -= seconds % 300;
    final int ticks = seconds * 10000000;
    return sha256
        .convert(ascii.encode('$ticks$trustedClientToken'))
        .toString()
        .toUpperCase();
  }
}

class EdgeTtsProvider extends TtsProvider {
  EdgeTtsProvider({required this.voice, required TtsHost host}) : _host = host;

  final String voice;
  final TtsHost _host;

  /// 本机时钟与微软服务器的偏差（403 后按服务器 Date 校正一次）。
  static Duration _clockSkew = Duration.zero;

  /// 合成走 Edge 155 起的新主机：2026-10 起旧主机 speech.platform.bing.com 的合成
  /// websocket 对各地出口一律回 403（rany2/edge-tts#490 / #491）。新主机认旧令牌，
  /// 只是参数名换成 `Ocp-Apim-Subscription-Key`，Sec-MS-GEC 与版本号沿用旧算法；
  /// 声音列表仍在旧主机。
  static const String _wssBase =
      'wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1';
  static const String _voicesUrl =
      'https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list';

  @override
  TtsCapabilities get capabilities => const EdgeTtsDescriptor().capabilities;

  DateTime get _now => DateTime.now().toUtc().add(_clockSkew);

  static String _connectionId() {
    final Random random = Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Map<String, String> get _headers => <String, String>{
    'Pragma': 'no-cache',
    'Cache-Control': 'no-cache',
    'Origin': EdgeTtsClientIdentity.origin,
    'Accept-Language': 'en-US,en;q=0.9',
    'Cookie': 'muid=${_connectionId().toUpperCase()};',
  };

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    try {
      return await _synthesizeOnce(text, outputPath, cancel);
    } on _EdgeHandshakeRejected {
      // 403 多半是本机时钟偏差导致令牌过期：按服务器时间校正一次再试（edge-tts 同做法），
      // 第二次仍拒绝就如实报错。
      if (!await _syncClockSkew()) {
        throw const TtsFailure(TtsFailureCode.unauthorized, 'handshake');
      }
      try {
        return await _synthesizeOnce(text, outputPath, cancel);
      } on _EdgeHandshakeRejected {
        throw const TtsFailure(TtsFailureCode.unauthorized, 'handshake');
      }
    }
  }

  Future<bool> _syncClockSkew() async {
    final HttpClient client = _host.httpClientFactory();
    try {
      final HttpClientRequest req = await client.headUrl(
        Uri.parse('https://speech.platform.bing.com/'),
      );
      final HttpClientResponse res = await req.close().timeout(
        const Duration(seconds: 15),
      );
      await res.drain<void>().catchError((Object _) {});
      final String? date = res.headers.value(HttpHeaders.dateHeader);
      if (date == null) return false;
      final DateTime server = HttpDate.parse(date);
      _clockSkew = server.difference(DateTime.now().toUtc());
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<TtsResult> _synthesizeOnce(
    String text,
    String outputPath,
    TtsCancelToken cancel,
  ) async {
    cancel.throwIfCancelled();
    final String connectionId = _connectionId();
    final Uri uri = Uri.parse(_wssBase).replace(
      queryParameters: <String, String>{
        'Ocp-Apim-Subscription-Key': EdgeTtsClientIdentity.trustedClientToken,
        'Sec-MS-GEC': EdgeTtsClientIdentity.secMsGec(_now),
        'Sec-MS-GEC-Version': EdgeTtsClientIdentity.secMsGecVersion,
        'ConnectionId': connectionId,
      },
    );
    final HttpClient client = _host.httpClientFactory()
      // UA 必须设在 client 上：经 headers 传会与 dart:io 默认 UA 合并成两段，
      // 微软据此拒绝握手（403）。
      ..userAgent = EdgeTtsClientIdentity.userAgent;
    WebSocket socket;
    try {
      socket = await WebSocket.connect(
        uri.toString(),
        headers: _headers,
        customClient: client,
      ).timeout(const Duration(seconds: 20));
    } on WebSocketException catch (e) {
      client.close(force: true);
      if (e.httpStatusCode == 403) throw const _EdgeHandshakeRejected();
      if (e.httpStatusCode == 429) {
        throw const TtsFailure(TtsFailureCode.rateLimited, 'HTTP 429');
      }
      throw const TtsFailure(TtsFailureCode.network, 'websocket');
    } on TimeoutException {
      client.close(force: true);
      throw const TtsFailure(TtsFailureCode.timeout);
    } on SocketException {
      client.close(force: true);
      throw const TtsFailure(TtsFailureCode.network);
    } on HttpException {
      client.close(force: true);
      throw const TtsFailure(TtsFailureCode.network);
    }

    final BytesBuilder audio = BytesBuilder(copy: false);
    final List<({String text, int offsetMs, int durationMs})> words =
        <({String text, int offsetMs, int durationMs})>[];
    final Completer<void> done = Completer<void>();
    final void Function() unregister = cancel.onCancel(() {
      if (!done.isCompleted) {
        done.completeError(const TtsFailure(TtsFailureCode.cancelled));
      }
      unawaited(socket.close());
    });
    late final StreamSubscription<Object?> sub;
    sub = socket.listen(
      (Object? message) {
        if (message is String) {
          final int split = message.indexOf('\r\n\r\n');
          final String head = split < 0 ? message : message.substring(0, split);
          final String body = split < 0 ? '' : message.substring(split + 4);
          if (head.contains('Path:turn.end')) {
            if (!done.isCompleted) done.complete();
          } else if (head.contains('Path:audio.metadata')) {
            words.addAll(_parseWordBoundaries(body));
          }
        } else if (message is List<int>) {
          final Uint8List bytes = message is Uint8List
              ? message
              : Uint8List.fromList(message);
          if (bytes.length < 2) return;
          final int headerLength = (bytes[0] << 8) | bytes[1];
          if (bytes.length < 2 + headerLength) return;
          final String header = ascii.decode(
            bytes.sublist(2, 2 + headerLength),
            allowInvalid: true,
          );
          if (!header.contains('Path:audio')) return;
          audio.add(bytes.sublist(2 + headerLength));
        }
      },
      onError: (Object _) {
        if (!done.isCompleted) {
          done.completeError(const TtsFailure(TtsFailureCode.network));
        }
      },
      onDone: () {
        if (!done.isCompleted) {
          done.completeError(
            const TtsFailure(TtsFailureCode.badResponse, 'closed early'),
          );
        }
      },
    );
    try {
      final String timestamp = _jsDateString(_now);
      socket.add(
        'X-Timestamp:$timestamp\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":{'
        '"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n',
      );
      socket.add(
        'X-RequestId:${_connectionId()}\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${timestamp}Z\r\n'
        'Path:ssml\r\n\r\n'
        "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xml:lang='en-US'><voice name='${ttsEscapeXml(voice)}'>"
        "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>"
        '${ttsEscapeXml(text)}</prosody></voice></speak>',
      );
      await done.future.timeout(kTtsRequestTimeout);
    } on TimeoutException {
      throw const TtsFailure(TtsFailureCode.timeout);
    } finally {
      // 提前离开（发送失败等）时收口，避免之后无人等待的 completeError。
      if (!done.isCompleted) done.complete();
      unregister();
      await sub.cancel();
      unawaited(socket.close());
      client.close(force: true);
    }
    final Uint8List bytes = audio.takeBytes();
    if (bytes.isEmpty) {
      throw const TtsFailure(TtsFailureCode.badResponse, 'no audio');
    }
    await File(outputPath).writeAsBytes(bytes, flush: true);
    return TtsResult(
      format: TtsAudioFormat.mp3,
      boundaries: locateTtsWordBoundaries(text, words),
    );
  }

  static List<({String text, int offsetMs, int durationMs})>
  _parseWordBoundaries(String body) {
    final List<({String text, int offsetMs, int durationMs})> result =
        <({String text, int offsetMs, int durationMs})>[];
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) return result;
      final Object? metadata = decoded['Metadata'];
      if (metadata is! List) return result;
      for (final Object? item in metadata) {
        if (item is! Map || item['Type'] != 'WordBoundary') continue;
        final Object? data = item['Data'];
        if (data is! Map) continue;
        final Object? offset = data['Offset'], duration = data['Duration'];
        final Object? textInfo = data['text'];
        final Object? word = textInfo is Map ? textInfo['Text'] : null;
        if (offset is! num || duration is! num || word is! String) continue;
        result.add((
          text: word,
          offsetMs: offset ~/ 10000,
          durationMs: duration ~/ 10000,
        ));
      }
    } on FormatException {
      // 元数据坏了只丢词边界，不影响音频。
    }
    return result;
  }

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    final HttpClient client = _host.httpClientFactory()
      ..userAgent = EdgeTtsClientIdentity.userAgent;
    try {
      final Uri uri = Uri.parse(_voicesUrl).replace(
        queryParameters: <String, String>{
          'trustedclienttoken': EdgeTtsClientIdentity.trustedClientToken,
          'Sec-MS-GEC': EdgeTtsClientIdentity.secMsGec(_now),
          'Sec-MS-GEC-Version': EdgeTtsClientIdentity.secMsGecVersion,
        },
      );
      final Object? raw = await ttsGetJson(
        client: client,
        uri: uri,
        headers: <String, String>{'Origin': EdgeTtsClientIdentity.origin},
        cancel: cancel,
      );
      return parseMicrosoftVoiceList(raw);
    } finally {
      client.close(force: true);
    }
  }
}

class _EdgeHandshakeRejected implements Exception {
  const _EdgeHandshakeRejected();
}

/// 微软两套接口（Edge / Azure）共用的声音列表形状：`ShortName` / `Locale` / `Gender`。
List<TtsVoice> parseMicrosoftVoiceList(Object? raw) => <TtsVoice>[
  if (raw is List)
    for (final Object? v in raw)
      if (v is Map && v['ShortName'] is String && v['Locale'] is String)
        TtsVoice(
          id: v['ShortName'] as String,
          displayName: (v['LocalName'] ?? v['FriendlyName'] ?? v['ShortName'])
              .toString(),
          locale: v['Locale'] as String,
          gender: v['Gender'] is String ? v['Gender'] as String : null,
        ),
];

/// 把引擎按序给出的词（文本 + 时间）定位回请求文本的 UTF-16 偏移。找不到的词丢弃
/// （引擎会把数字等读法改写，宁缺勿错）。
List<TtsBoundary> locateTtsWordBoundaries(
  String text,
  List<({String text, int offsetMs, int durationMs})> words,
) {
  final List<TtsBoundary> result = <TtsBoundary>[];
  int cursor = 0;
  for (final ({String text, int offsetMs, int durationMs}) word in words) {
    if (word.text.isEmpty) continue;
    final int at = text.indexOf(word.text, cursor);
    if (at < 0) continue;
    result.add(
      TtsBoundary(
        textOffset: at,
        textLength: word.text.length,
        offsetMs: word.offsetMs,
        durationMs: word.durationMs,
      ),
    );
    cursor = at + word.text.length;
  }
  return result;
}

/// JS `Date.prototype.toString()` 形状（Edge 客户端发的 X-Timestamp）。
String _jsDateString(DateTime utc) {
  const List<String> days = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  const List<String> months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int v) => v.toString().padLeft(2, '0');
  return '${days[utc.weekday - 1]} ${months[utc.month - 1]} ${two(utc.day)} '
      '${utc.year} ${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} '
      'GMT+0000 (Coordinated Universal Time)';
}
