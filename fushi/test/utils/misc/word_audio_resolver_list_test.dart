import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart'
    show RemoteLookupUnreachableError;
import 'package:fushi/src/utils/misc/word_audio_resolver.dart';

/// 「选择音频源」菜单的数据源 [WordAudioResolver.listConfigured]：每个启用源各自
/// 解析、按配置顺序拼接、远端列表型源展开成带名变体，首项与 resolveConfigured
/// （单击 ♪ 播的默认源）一致。
void main() {
  tearDown(() {
    WordAudioResolver.debugResetRemoteFailureCooldown();
    WordAudioResolver.debugSetNowProvider(null);
  });

  test(
    'lists every enabled source in config order, expanding list sources',
    () async {
      final WordAudioResolver resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        queryLocalAudioByDbIndex: (_, __, int dbIndex) async => dbIndex == 0
            ? const <String, dynamic>{'file': 'a', 'source': 'nhk'}
            : null,
        extractLocalAudio: (_, __, {int dbIndex = 0}) async =>
            '/tmp/local$dbIndex.mp3',
        queryRemoteAudio: (_, __) async => 'https://peer.test/a.mp3',
        // 生产里两者都是同一端点的投影；测试替身分别注入、内容一致。
        fetchAudioSourceList: (String url) async => <String>[
          'https://forvo.test/1.mp3',
          'https://forvo.test/2.mp3',
        ],
        fetchAudioSourceEntries: (String url) async => <AudioSourceListEntry>[
          (name: 'Forvo (alice)', url: 'https://forvo.test/1.mp3'),
          (name: 'Forvo (bob)', url: 'https://forvo.test/2.mp3'),
        ],
      );
      final List<AudioSourceConfig> sources = <AudioSourceConfig>[
        AudioSourceConfig.remoteAudio(
          url: 'https://list.test/?term={term}',
          label: 'Forvo',
        ),
        AudioSourceConfig.localAudio(
          label: 'Local',
          path: '/db',
          enabled: true,
        ),
        AudioSourceConfig.localAudio(
          label: 'Empty',
          path: '/db2',
          enabled: true,
        ),
        AudioSourceConfig.fushiRemote(enabled: true),
        AudioSourceConfig.remoteAudio(
          url: 'https://off.test/?term={term}',
          enabled: false,
        ),
      ];

      final List<WordAudioCandidate> list = await resolver.listConfigured(
        expression: '猫',
        reading: 'ねこ',
        sources: sources,
      );
      final String? first = await resolver.resolveConfigured(
        expression: '猫',
        reading: 'ねこ',
        sources: sources,
      );

      expect(list.map((WordAudioCandidate c) => c.ref).toList(), <String>[
        'https://forvo.test/1.mp3',
        'https://forvo.test/2.mp3',
        '/tmp/local0.mp3',
        'https://peer.test/a.mp3',
      ]);
      expect(list.map((WordAudioCandidate c) => c.variant).take(2), <String>[
        'Forvo (alice)',
        'Forvo (bob)',
      ]);
      expect(list.map((WordAudioCandidate c) => c.sourceIndex).toList(), <int>[
        0,
        0,
        1,
        3,
      ]);
      expect(first, list.first.ref, reason: '菜单首项必须就是单击 ♪ 播的默认源');
    },
  );

  test(
    'an unreachable source is skipped and cooled down, others still listed',
    () async {
      int remoteCalls = 0;
      final WordAudioResolver resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __, {int dbIndex = 0}) async => null,
        queryRemoteAudio: (_, __) async {
          remoteCalls++;
          throw RemoteLookupUnreachableError('down');
        },
        fetchAudioSourceList: (String url) async => <String>[
          'https://plain.test/x.mp3',
        ],
      );
      final List<AudioSourceConfig> sources = <AudioSourceConfig>[
        AudioSourceConfig.fushiRemote(enabled: true),
        AudioSourceConfig.remoteAudio(url: 'https://plain.test/?t={term}'),
      ];

      final List<WordAudioCandidate> list = await resolver.listConfigured(
        expression: '猫',
        reading: 'ねこ',
        sources: sources,
      );
      expect(list.map((WordAudioCandidate c) => c.ref), <String>[
        'https://plain.test/x.mp3',
      ]);
      // 只注入 URL 列表 fetcher 时变体名为空（与默认播放同一端点）。
      expect(list.single.variant, '');

      await resolver.listConfigured(
        expression: '猫',
        reading: 'ねこ',
        sources: sources,
      );
      expect(remoteCalls, 1, reason: '不可达的互联源进入冷却，第二次列表不再请求');
    },
  );
}
