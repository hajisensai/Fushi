// EXlaIL2eKQ：扩展的 mpvArgs 白名单解析 + 可选外挂音轨 → `audio-add ... auto`。
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

  group('externalAudioMiningSource', () {
    const Map<String, String> sources = <String, String>{
      'JP': 'https://cdn/a.m4a',
      'EN': 'https://cdn/b.m4a',
    };

    test('显式选中外挂音轨 → 它的原地址；选中自带音轨 → null', () {
      expect(
        externalAudioMiningSource(
          sourcesByTitle: sources,
          selectedIsAuto: false,
          selectedTitle: 'EN',
          realTrackTitles: const <String?>['Original', 'JP', 'EN'],
        ),
        'https://cdn/b.m4a',
      );
      expect(
        externalAudioMiningSource(
          sourcesByTitle: sources,
          selectedIsAuto: false,
          selectedTitle: 'Original',
          realTrackTitles: const <String?>['Original', 'JP', 'EN'],
        ),
        isNull,
      );
    });

    test('仍是 auto：纯视频流（真实音轨全是外挂）→ 第一条；流自带原声 → null', () {
      expect(
        externalAudioMiningSource(
          sourcesByTitle: sources,
          selectedIsAuto: true,
          selectedTitle: null,
          realTrackTitles: const <String?>['JP', 'EN'],
        ),
        'https://cdn/a.m4a',
      );
      expect(
        externalAudioMiningSource(
          sourcesByTitle: sources,
          selectedIsAuto: true,
          selectedTitle: null,
          realTrackTitles: const <String?>[null, 'JP'],
        ),
        isNull,
      );
    });
  });
}
