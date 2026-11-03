// EXlaIL2eKQ：扩展的 mpvArgs 白名单解析 + 可选外挂音轨 → `audio-add ... auto`。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoExternalAudioTrack;

import 'package:fushi/src/media/video/online/anime_source_mpv_args.dart';
import 'package:fushi/src/media/video/video_external_audio_tracks.dart';

void main() {
  group('AnimeSourceMpvArgs.parse 白名单', () {
    test('请求头 / referrer / user-agent / audio-files 生效，其余记为忽略', () {
      final AnimeSourceMpvArgs parsed =
          AnimeSourceMpvArgs.parse(const <MapEntry<String, String>>[
            MapEntry<String, String>(
              '--http-header-fields',
              'Origin: https://a.example,Cookie: x=1, y=2',
            ),
            MapEntry<String, String>('referrer', 'https://a.example/'),
            MapEntry<String, String>('user-agent', 'UA/1'),
            MapEntry<String, String>(
              'audio-files',
              'https://cdn/a.m4a;https://cdn/b.m4a',
            ),
            MapEntry<String, String>('scripts', '/evil.lua'),
            MapEntry<String, String>('http-proxy', 'http://x'),
          ]);
      expect(parsed.headers, <String, String>{
        'Origin': 'https://a.example',
        'Cookie': 'x=1, y=2',
        'Referer': 'https://a.example/',
        'User-Agent': 'UA/1',
      });
      expect(parsed.audioFiles, <String>[
        'https://cdn/a.m4a',
        'https://cdn/b.m4a',
      ]);
      expect(parsed.ignoredKeys, <String>['scripts', 'http-proxy']);
    });

    test('空参数 → 空结果', () {
      final AnimeSourceMpvArgs parsed = AnimeSourceMpvArgs.parse(
        const <MapEntry<String, String>>[],
      );
      expect(parsed.headers, isEmpty);
      expect(parsed.audioFiles, isEmpty);
      expect(parsed.ignoredKeys, isEmpty);
    });
  });

  group('buildExternalAudioAddCommands', () {
    test('auto 不 select、标题唯一、带语言码时附在末尾', () {
      final List<VideoExternalAudioAdd> adds = buildExternalAudioAddCommands(
        const <RemoteVideoExternalAudioTrack>[
          RemoteVideoExternalAudioTrack(url: 'https://cdn/a.m4a', label: 'JP'),
          RemoteVideoExternalAudioTrack(
            url: 'https://cdn/b.m4a',
            label: 'JP',
            language: 'ja',
          ),
          RemoteVideoExternalAudioTrack(url: 'https://cdn/c.m4a'),
        ],
        nativeUri: (String url) => 'native:$url',
      );
      expect(
        adds.map((VideoExternalAudioAdd a) => a.command).toList(),
        <List<String>>[
          <String>['audio-add', 'native:https://cdn/a.m4a', 'auto', 'JP'],
          <String>[
            'audio-add',
            'native:https://cdn/b.m4a',
            'auto',
            'JP (2)',
            'ja',
          ],
          <String>[
            'audio-add',
            'native:https://cdn/c.m4a',
            'auto',
            'External audio 3',
          ],
        ],
      );
      expect(adds[1].sourceUrl, 'https://cdn/b.m4a');
    });
  });

  group('resolveExternalAudioTracks（按 track-list 的 external-filename 认轨）', () {
    final List<VideoExternalAudioAdd> adds =
        buildExternalAudioAddCommands(const <RemoteVideoExternalAudioTrack>[
          RemoteVideoExternalAudioTrack(
            url: 'https://cdn/ja.m4a',
            label: 'Japanese',
          ),
          RemoteVideoExternalAudioTrack(url: 'https://cdn/en.m4a', label: 'EN'),
        ], nativeUri: (String url) => 'native:$url');

    // mpv `getProperty('track-list')` 的 JSON 形状（只保留用到的字段）。
    String trackList(List<Map<String, Object?>> tracks) => jsonEncode(tracks);

    test('自带音轨与外挂轨同名：只把外挂那条认成外挂（id 身份，不看标题）', () {
      final ExternalAudioTrackResolution resolution =
          resolveExternalAudioTracks(
            trackListJson: trackList(<Map<String, Object?>>[
              <String, Object?>{'id': 1, 'type': 'video', 'external': false},
              <String, Object?>{
                'id': 1,
                'type': 'audio',
                'title': 'Japanese',
                'external': false,
              },
              <String, Object?>{
                'id': 2,
                'type': 'audio',
                'title': 'Japanese',
                'external': true,
                'external-filename': 'native:https://cdn/ja.m4a',
              },
              <String, Object?>{
                'id': 3,
                'type': 'audio',
                'title': 'EN',
                'external': true,
                'external-filename': 'native:https://cdn/en.m4a',
              },
            ]),
            adds: adds,
          )!;
      expect(resolution.sourcesByTrackId, <String, String>{
        '2': 'https://cdn/ja.m4a',
        '3': 'https://cdn/en.m4a',
      });
      expect(resolution.failed, isEmpty);
      expect(resolution.hasOwnAudio, isTrue);
      expect(resolution.silent, isFalse);
      // 用户选中同名的**自带**轨（id 1）：制卡不能改从外挂配音裁。
      expect(
        externalAudioMiningSource(
          sourcesByTrackId: resolution.sourcesByTrackId,
          selectedIsAuto: false,
          selectedId: '1',
          realTrackIds: const <String>['1', '2', '3'],
        ),
        isNull,
      );
      expect(
        externalAudioMiningSource(
          sourcesByTrackId: resolution.sourcesByTrackId,
          selectedIsAuto: false,
          selectedId: '2',
          realTrackIds: const <String>['1', '2', '3'],
        ),
        'https://cdn/ja.m4a',
      );
    });

    test('audio-add 没挂上的轨（mpv 只记日志不抛）记为失败、不进来源表', () {
      final ExternalAudioTrackResolution resolution =
          resolveExternalAudioTracks(
            trackListJson: trackList(<Map<String, Object?>>[
              <String, Object?>{'id': 1, 'type': 'video'},
              <String, Object?>{
                'id': 1,
                'type': 'audio',
                'external': true,
                'external-filename': 'native:https://cdn/en.m4a',
              },
            ]),
            adds: adds,
          )!;
      expect(resolution.sourcesByTrackId, <String, String>{
        '1': 'https://cdn/en.m4a',
      });
      expect(
        resolution.failed.map((VideoExternalAudioAdd a) => a.sourceUrl),
        <String>['https://cdn/ja.m4a'],
      );
      expect(resolution.silent, isFalse);
    });

    test('纯视频流的外挂音频全部没挂上 → silent（要发失败信号）', () {
      final ExternalAudioTrackResolution resolution =
          resolveExternalAudioTracks(
            trackListJson: trackList(<Map<String, Object?>>[
              <String, Object?>{'id': 1, 'type': 'video'},
            ]),
            adds: adds,
          )!;
      expect(resolution.sourcesByTrackId, isEmpty);
      expect(resolution.failed, hasLength(2));
      expect(resolution.hasOwnAudio, isFalse);
      expect(resolution.silent, isTrue);
    });

    test('流自带原声、替代配音全部失败 → 不算 silent', () {
      final ExternalAudioTrackResolution resolution =
          resolveExternalAudioTracks(
            trackListJson: trackList(<Map<String, Object?>>[
              <String, Object?>{'id': 1, 'type': 'audio', 'external': false},
            ]),
            adds: adds,
          )!;
      expect(resolution.failed, hasLength(2));
      expect(resolution.silent, isFalse);
    });

    test('track-list 读不懂（空串 / 非数组）→ null，不下结论', () {
      expect(resolveExternalAudioTracks(trackListJson: '', adds: adds), isNull);
      expect(
        resolveExternalAudioTracks(trackListJson: '{"a":1}', adds: adds),
        isNull,
      );
    });
  });

  group('externalAudioMiningSource', () {
    const Map<String, String> sources = <String, String>{
      '2': 'https://cdn/a.m4a',
      '3': 'https://cdn/b.m4a',
    };

    test('显式选中外挂音轨 → 它的原地址；选中自带音轨 → null', () {
      expect(
        externalAudioMiningSource(
          sourcesByTrackId: sources,
          selectedIsAuto: false,
          selectedId: '3',
          realTrackIds: const <String>['1', '2', '3'],
        ),
        'https://cdn/b.m4a',
      );
      expect(
        externalAudioMiningSource(
          sourcesByTrackId: sources,
          selectedIsAuto: false,
          selectedId: '1',
          realTrackIds: const <String>['1', '2', '3'],
        ),
        isNull,
      );
    });

    test('仍是 auto：纯视频流（真实音轨全是外挂）→ 第一条；流自带原声 → null', () {
      expect(
        externalAudioMiningSource(
          sourcesByTrackId: sources,
          selectedIsAuto: true,
          selectedId: 'auto',
          realTrackIds: const <String>['2', '3'],
        ),
        'https://cdn/a.m4a',
      );
      expect(
        externalAudioMiningSource(
          sourcesByTrackId: sources,
          selectedIsAuto: true,
          selectedId: 'auto',
          realTrackIds: const <String>['1', '2'],
        ),
        isNull,
      );
    });
  });
}
