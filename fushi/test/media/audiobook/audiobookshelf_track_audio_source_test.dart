// Audiobookshelf 音轨流式源：字节区间 → Range 请求（just_audio 的 end 是开区间，HTTP
// 是闭区间）、服务器不认 Range 时自己截取、总长度来源、令牌过期后的刷新重试；以及
// 远端播放接缝（占位文件 / 音源数量 / ffmpeg 输入不把令牌写进 URL）。
//
// just_audio 把 StreamAudioSource 标成 experimental；升级 just_audio 先跑本文件。
// ignore_for_file: experimental_member_use
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/remote/audiobook_remote_playback.dart';
import 'package:fushi/src/media/audiobook/remote/audiobookshelf_remote_playback.dart';
import 'package:fushi/src/media/audiobook/remote/audiobookshelf_track_audio_source.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';

final Uri _server = Uri.parse('https://abs.example.com');
const AudiobookshelfTokens _tokens = AudiobookshelfTokens(
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
);

AudiobookshelfApi _api(MockClientHandler handler) => AudiobookshelfApi(
  serverUrl: _server,
  providerId: 'abs-test',
  tokens: _tokens,
  client: MockClient(handler),
);

AudiobookshelfTrackAudioSource _source(
  AudiobookshelfApi api, {
  int? sizeBytes,
  String? mime = 'audio/mpeg',
}) => AudiobookshelfTrackAudioSource(
  api: api,
  itemId: 'item_1',
  ino: '10',
  mimeType: mime,
  sizeBytes: sizeBytes,
);

Future<List<int>> _bytes(StreamAudioResponse response) async => <int>[
  for (final List<int> chunk in await response.stream.toList()) ...chunk,
];

void main() {
  group('AudiobookshelfTrackAudioSource.request', () {
    test('区间请求：end 开区间转成 Range 闭区间，带 Bearer，读 Content-Range 总长', () async {
      late http.Request seen;
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen = request;
        return http.Response.bytes(
          List<int>.generate(100, (int i) => i),
          206,
          headers: <String, String>{'content-range': 'bytes 100-199/5000'},
        );
      });
      final StreamAudioResponse response = await _source(api).request(100, 200);
      expect(seen.url.path, '/api/items/item_1/file/10');
      expect(seen.headers['Range'], 'bytes=100-199');
      expect(seen.headers['Authorization'], 'Bearer access-1');
      expect(response.offset, 100);
      expect(response.sourceLength, 5000);
      expect(response.contentLength, 100);
      expect(response.contentType, 'audio/mpeg');
      expect((await _bytes(response)), hasLength(100));
      api.close();
    });

    test('只给起点：Range 开放结尾', () async {
      late http.Request seen;
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen = request;
        return http.Response.bytes(
          <int>[1, 2, 3],
          206,
          headers: <String, String>{'content-range': 'bytes 7-9/10'},
        );
      });
      final StreamAudioResponse response = await _source(api).request(7);
      expect(seen.headers['Range'], 'bytes=7-');
      expect(response.offset, 7);
      expect(response.sourceLength, 10);
      api.close();
    });

    test('不带区间：整份文件，没有 Range 头，总长取 Content-Length', () async {
      late http.Request seen;
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen = request;
        return http.Response.bytes(<int>[1, 2, 3, 4], 200);
      });
      final StreamAudioResponse response = await _source(api).request();
      expect(seen.headers.containsKey('Range'), isFalse);
      expect(response.offset, 0);
      expect(response.sourceLength, 4);
      expect(await _bytes(response), <int>[1, 2, 3, 4]);
      api.close();
    });

    test('服务器忽略 Range 回了整份 200：自己跳过前缀并截到区间', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async =>
            http.Response.bytes(List<int>.generate(10, (int i) => i), 200),
      );
      final StreamAudioResponse response = await _source(api).request(3, 7);
      expect(response.offset, 3);
      expect(response.contentLength, 4);
      expect(await _bytes(response), <int>[3, 4, 5, 6]);
      api.close();
    });

    test('服务器报的文件大小优先于响应头', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => http.Response.bytes(
          <int>[1],
          206,
          headers: <String, String>{'content-range': 'bytes 0-0/999'},
        ),
      );
      final StreamAudioResponse response = await _source(
        api,
        sizeBytes: 12345,
      ).request(0, 1);
      expect(response.sourceLength, 12345);
      api.close();
    });

    test('令牌过期（401）→ 刷新 → 带新令牌重试，播放不中断', () async {
      final List<String> auths = <String>[];
      final AudiobookshelfApi api = _api((http.Request request) async {
        if (request.url.path == '/auth/refresh') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'user': <String, Object?>{
                'id': 'u',
                'username': 'me',
                'accessToken': 'access-2',
                'refreshToken': 'refresh-2',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        auths.add(request.headers['Authorization'] ?? '');
        return auths.length == 1
            ? http.Response('expired', 401)
            : http.Response.bytes(
                <int>[9],
                206,
                headers: <String, String>{'content-range': 'bytes 0-0/1'},
              );
      });
      final StreamAudioResponse response = await _source(api).request(0, 1);
      expect(auths, <String>['Bearer access-1', 'Bearer access-2']);
      expect(await _bytes(response), <int>[9]);
      api.close();
    });

    test('服务器出错（404）→ 抛 ExternalProviderFailure，不吞', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => http.Response('gone', 404),
      );
      await expectLater(_source(api).request(0, 10), throwsA(isA<Object>()));
      api.close();
    });
  });

  group('辅助函数', () {
    test('audiobookshelfPlayableMime：m4b 当 mp4，缺失当 mp3，其余小写原样', () {
      expect(audiobookshelfPlayableMime('audio/x-m4b'), 'audio/mp4');
      expect(audiobookshelfPlayableMime('audio/m4b'), 'audio/mp4');
      expect(audiobookshelfPlayableMime(null), 'audio/mpeg');
      expect(audiobookshelfPlayableMime('  '), 'audio/mpeg');
      expect(audiobookshelfPlayableMime('Audio/OGG'), 'audio/ogg');
    });

    test(
      'audiobookshelfTotalLength：206 取 Content-Range 的总长，200 取 Content-Length',
      () {
        http.StreamedResponse response(
          int status,
          Map<String, String> headers, [
          int? length,
        ]) => http.StreamedResponse(
          const Stream<List<int>>.empty(),
          status,
          headers: headers,
          contentLength: length,
        );
        expect(
          audiobookshelfTotalLength(
            response(206, <String, String>{'content-range': 'bytes 0-9/777'}),
          ),
          777,
        );
        expect(
          audiobookshelfTotalLength(response(200, <String, String>{}, 42)),
          42,
        );
        expect(
          audiobookshelfTotalLength(
            response(206, <String, String>{'content-range': 'bytes 0-9/*'}),
          ),
          isNull,
        );
      },
    );
  });

  group('AudiobookshelfRemotePlayback', () {
    final RemoteAudioBinding binding = RemoteAudioBinding(
      srtBookUid: 'srtbook_1',
      provider: RemoteAudioBinding.providerAudiobookshelf,
      serverConfigId: 'srv',
      itemId: 'item_1',
      tracks: const <RemoteAudioTrack>[
        RemoteAudioTrack(
          ino: '10',
          startOffsetMs: 0,
          durationMs: 1000,
          filename: 'part1.mp3',
        ),
        RemoteAudioTrack(
          ino: '11',
          startOffsetMs: 1000,
          durationMs: 1000,
          mimeType: 'audio/x-m4b',
        ),
      ],
      createdAt: 0,
      updatedAt: 0,
    );

    AudiobookshelfRemotePlayback playback(AudiobookshelfApi api) =>
        AudiobookshelfRemotePlayback(api: api, binding: binding);

    test('占位文件与音源一轨一个，占位路径不存在于磁盘', () {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => http.Response('', 404),
      );
      final AudiobookshelfRemotePlayback remote = playback(api);
      expect(remote.trackCount, 2);
      expect(remote.placeholderFiles, hasLength(2));
      expect(remote.placeholderFiles[0].path, endsWith('10.mp3'));
      expect(remote.placeholderFiles[1].path, endsWith('11.m4b'));
      expect(remote.placeholderFiles.any((f) => f.existsSync()), isFalse);
      expect(remote.buildSources(), hasLength(2));
      expect(
        identical(remote.buildTrackSource(0), remote.buildTrackSource(0)),
        isFalse,
        reason: '句子回放的临时播放器要拿全新实例',
      );
      api.close();
    });

    test('ffmpeg 输入：地址里没有令牌，令牌走请求头', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => http.Response('', 404),
      );
      final AudiobookTrackInput input = await playback(api).trackInput(1);
      expect(input.input, 'https://abs.example.com/api/items/item_1/file/11');
      expect(input.input.contains('token'), isFalse);
      expect(input.headers['Authorization'], 'Bearer access-1');
      expect(input.isRemote, isTrue);
      api.close();
    });

    test('本机输入不算远端', () {
      expect(
        const AudiobookTrackInput(input: '/books/a.mp3').isRemote,
        isFalse,
      );
      expect(
        const AudiobookTrackInput(input: r'C:\books\a.mp3').isRemote,
        isFalse,
      );
    });
  });
}
