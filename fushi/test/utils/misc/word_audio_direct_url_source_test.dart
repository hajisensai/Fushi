// BUG-3810 回归：自定义远端音源有两种形态（Yomitan「Custom URL」直接回音频 /
// 「Custom URL (JSON)」回 audioSourceList），旧实现把所有响应当 JSON 解析：
// 直返音频的源（uapis.cn 词典发音、GPT-SoVITS /tts）抛 FormatException → 被当
// 死源计入 host 冷却 → 永远没声音。这里走真实的 defaultFetchAudioSourceEntries
// （Dio + 注入的假 HttpClientAdapter），不 mock fetcher。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/utils/misc/word_audio_cache.dart';
import 'package:fushi/src/utils/misc/word_audio_resolver.dart';

/// 反馈日志里的真实开头：`ID3` 标签 + TYER/TDAT 帧。
final Uint8List _id3Mp3 = Uint8List.fromList(<int>[
  ...ascii.encode('ID3'),
  0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32, //
  ...ascii.encode('TYER'),
  0x00, 0x00, 0x00, 0x05, 0x00, 0x00, //
  ...ascii.encode('2019'),
  0xFF, 0xFB, 0x90, 0x64, // MPEG-1 Layer III 帧头
]);

/// GPT-SoVITS `media_type=aac`：裸 ADTS 帧（layer 位 00）。
final Uint8List _adtsAac = Uint8List.fromList(<int>[
  0xFF, 0xF1, 0x50, 0x80, 0x02, 0x1F, 0xFC, 0x21, 0x00, 0x49, //
]);

class _FixedBodyAdapter implements HttpClientAdapter {
  _FixedBodyAdapter(this.body, {required this.contentType});

  final Uint8List body;
  final String contentType;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromBytes(
      body,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late HttpClientAdapter originalAdapter;
  late Directory cacheDir;

  setUp(() async {
    originalAdapter = WordAudioResolver.debugHttpClientAdapter;
    cacheDir = await Directory.systemTemp.createTemp('bug3801_audio_');
  });

  tearDown(() async {
    WordAudioResolver.debugHttpClientAdapter = originalAdapter;
    WordAudioResolver.debugResetRemoteFailureCooldown();
    WordAudioResolver.debugSetNowProvider(null);
    if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
  });

  Future<String> cacheInTemp(Uint8List bytes, String ext) =>
      cacheWordAudioBytes(bytes, ext, cacheDir: cacheDir);

  group('defaultFetchAudioSourceEntries: direct-audio vs JSON list', () {
    test('ID3 mp3 bytes (audio/mpeg) become one cached local file with the '
        'same bytes', () async {
      WordAudioResolver.debugHttpClientAdapter = _FixedBodyAdapter(
        _id3Mp3,
        contentType: 'audio/mpeg',
      );
      final List<AudioSourceListEntry> entries =
          await WordAudioResolver.defaultFetchAudioSourceEntries(
            'https://uapis.test/api/v1/dictionary/audio?word=hello',
            cacheAudioBytes: cacheInTemp,
          );
      expect(entries, hasLength(1));
      expect(entries.single.url, endsWith('.mp3'));
      expect(File(entries.single.url).readAsBytesSync(), _id3Mp3);
    });

    test(
      'audio is recognised by magic even under application/octet-stream',
      () async {
        WordAudioResolver.debugHttpClientAdapter = _FixedBodyAdapter(
          _id3Mp3,
          contentType: 'application/octet-stream',
        );
        final List<AudioSourceListEntry> entries =
            await WordAudioResolver.defaultFetchAudioSourceEntries(
              'https://cdn.test/a?word=x',
              cacheAudioBytes: cacheInTemp,
            );
        expect(entries.single.url, endsWith('.mp3'));
      },
    );

    test(
      'GPT-SoVITS style ADTS aac (audio/aac) is a direct audio hit',
      () async {
        WordAudioResolver.debugHttpClientAdapter = _FixedBodyAdapter(
          _adtsAac,
          contentType: 'audio/aac',
        );
        final List<AudioSourceListEntry> entries =
            await WordAudioResolver.defaultFetchAudioSourceEntries(
              'http://127.0.0.1:9880/tts?text=hello&media_type=aac',
              cacheAudioBytes: cacheInTemp,
            );
        expect(entries.single.url, endsWith('.aac'));
        expect(File(entries.single.url).readAsBytesSync(), _adtsAac);
      },
    );

    test(
      'Yomitan audioSourceList JSON still expands into its entries',
      () async {
        final Uint8List json = Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, Object>{
              'type': 'audioSourceList',
              'audioSources': <Map<String, String>>[
                <String, String>{
                  'name': 'NHK16',
                  'url': 'https://a.test/1.mp3',
                },
                <String, String>{
                  'name': 'Forvo',
                  'url': 'https://a.test/2.mp3',
                },
              ],
            }),
          ),
        );
        WordAudioResolver.debugHttpClientAdapter = _FixedBodyAdapter(
          json,
          contentType: 'application/json; charset=utf-8',
        );
        final List<AudioSourceListEntry> entries =
            await WordAudioResolver.defaultFetchAudioSourceEntries(
              'https://list.test/?term=x',
              cacheAudioBytes: cacheInTemp,
            );
        expect(entries.map((AudioSourceListEntry e) => e.name), <String>[
          'NHK16',
          'Forvo',
        ]);
        expect(entries.map((AudioSourceListEntry e) => e.url), <String>[
          'https://a.test/1.mp3',
          'https://a.test/2.mp3',
        ]);
        expect(cacheDir.listSync(), isEmpty, reason: 'JSON 列表不落盘');
      },
    );

    test('an unrecognised 2xx body returns empty and does not throw', () async {
      WordAudioResolver.debugHttpClientAdapter = _FixedBodyAdapter(
        Uint8List.fromList(utf8.encode('<html>not audio</html>')),
        contentType: 'text/html',
      );
      final List<AudioSourceListEntry> entries =
          await WordAudioResolver.defaultFetchAudioSourceEntries(
            'https://weird.test/?term=x',
            cacheAudioBytes: cacheInTemp,
          );
      expect(entries, isEmpty);
    });
  });

  group('resolveConfigured with a direct-audio remote source', () {
    test('returns the cached audio file, never cools the host, and a '
        'second lookup hits the source again', () async {
      final _FixedBodyAdapter adapter = _FixedBodyAdapter(
        _id3Mp3,
        contentType: 'audio/mpeg',
      );
      WordAudioResolver.debugHttpClientAdapter = adapter;
      final WordAudioResolver resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __, {int dbIndex = 0}) async => null,
        fetchAudioSourceEntries: (String url) =>
            WordAudioResolver.defaultFetchAudioSourceEntries(
              url,
              cacheAudioBytes: cacheInTemp,
            ),
        fetchAudioSourceList: (String url) async => <String>[
          for (final AudioSourceListEntry e
              in await WordAudioResolver.defaultFetchAudioSourceEntries(
                url,
                cacheAudioBytes: cacheInTemp,
              ))
            e.url,
        ],
      );
      final List<AudioSourceConfig> sources = <AudioSourceConfig>[
        AudioSourceConfig.remoteAudio(
          url: 'https://uapis.test/api/v1/dictionary/audio?word={term}',
        ),
      ];

      final String? first = await resolver.resolveConfigured(
        expression: 'hello',
        reading: '',
        sources: sources,
      );
      expect(first, isNotNull);
      expect(File(first!).readAsBytesSync(), _id3Mp3);
      expect(
        WordAudioResolver.isRemoteSourceInCooldown(
          'https://uapis.test/api/v1/dictionary/audio?word=x',
        ),
        isFalse,
      );

      final String? second = await resolver.resolveConfigured(
        expression: 'world',
        reading: '',
        sources: sources,
      );
      expect(second, first, reason: '同一段字节按内容寻址复用同一文件');
      expect(adapter.requests, 2, reason: '每次查词各打一次源，不被冷却短路');
    });

    test('an unrecognised body does not cool the host either', () async {
      WordAudioResolver.debugHttpClientAdapter = _FixedBodyAdapter(
        Uint8List.fromList(utf8.encode('plain text')),
        contentType: 'text/plain',
      );
      final WordAudioResolver resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __, {int dbIndex = 0}) async => null,
      );
      final String? result = await resolver.resolveConfigured(
        expression: 'hello',
        reading: '',
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: 'https://weird.test/?w={term}'),
        ],
      );
      expect(result, isNull);
      expect(
        WordAudioResolver.isRemoteSourceInCooldown('https://weird.test/?w=x'),
        isFalse,
        reason: '可达源的格式问题不是死源，不得冷却',
      );
    });
  });

  group('sniffWordAudioExtension', () {
    Uint8List b(List<int> v) => Uint8List.fromList(v);

    test('magic numbers', () {
      expect(sniffWordAudioExtension(_id3Mp3), 'mp3');
      expect(sniffWordAudioExtension(b(<int>[0xFF, 0xFB, 0x90])), 'mp3');
      expect(sniffWordAudioExtension(_adtsAac), 'aac');
      expect(sniffWordAudioExtension(b(ascii.encode('OggS\x00'))), 'ogg');
      expect(sniffWordAudioExtension(b(ascii.encode('fLaC'))), 'flac');
      expect(
        sniffWordAudioExtension(b(ascii.encode('RIFF\x00\x00\x00\x00WAVE'))),
        'wav',
      );
      expect(
        sniffWordAudioExtension(b(ascii.encode('\x00\x00\x00\x20ftypM4A '))),
        'm4a',
      );
    });

    test('JSON / text is not audio unless Content-Type says audio/*', () {
      final Uint8List json = b(utf8.encode('{"type":"audioSourceList"}'));
      expect(sniffWordAudioExtension(json), isNull);
      expect(
        sniffWordAudioExtension(json, contentType: 'application/json'),
        isNull,
      );
      expect(
        sniffWordAudioExtension(b(<int>[1, 2, 3]), contentType: 'audio/ogg'),
        'ogg',
      );
      expect(
        sniffWordAudioExtension(
          b(<int>[1, 2, 3]),
          contentType: 'application/octet-stream',
        ),
        isNull,
      );
    });
  });
}
