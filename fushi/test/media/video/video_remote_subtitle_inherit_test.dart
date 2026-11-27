// BUG-5464 远端合集：成员自己没选过字幕时，按描述沿用兄弟成员最近一次的选择。
//
// 钉子（纯函数，`video_subtitle_inherit.dart` 后半段）：
// - 描述的 wire 编解码：两种 kind 往返一致；缺键 / 类型不符 / source 与 kind 对不上
//   一律拒收（当没有描述，不猜）；
// - 选轨那一刻写描述：`embedded:<n>` 按本成员轨表读出语言 + 标题 + 文本 / 图形，
//   host 外挂字幕按视频主名切尾巴；关闭 / 本机档 / 后端默认 / 轨表里没有的序号 /
//   不知道文件名都不写；
// - 兄弟成员：按 `video_remote_position_at_` 取最近、跳过当前成员 / 没有播放时刻 /
//   没有描述的旧选择 / 描述与选择对不上（别处改了选择）；`off:` 不要描述也能沿用；
// - 落到当前成员：两个成员轨顺序不同也按描述对上、Signs 不顶 Full、文本不顶图形；
//   host 外挂字幕按尾巴找本成员的那一条，不知道文件名不猜。
import 'dart:convert';

import 'package:fushi_engine/media/video/video_subtitle_inherit.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoEmbeddedSubtitleTrack, RemoteVideoSidecarSubtitle;
import 'package:test/test.dart';

RemoteVideoEmbeddedSubtitleTrack _track(
  int index, {
  String codec = 'subrip',
  String? language,
  String? title,
  bool isText = true,
}) => RemoteVideoEmbeddedSubtitleTrack(
  streamIndex: index,
  codec: codec,
  language: language,
  title: title,
  isText: isText,
);

RemoteVideoSidecarSubtitle _sidecar(String fileName) =>
    RemoteVideoSidecarSubtitle(fileName: fileName, format: 'srt');

/// ep1 的轨序：Signs、English、Full；ep2：Signs、Full、English。
final List<RemoteVideoEmbeddedSubtitleTrack> _ep1Tracks =
    <RemoteVideoEmbeddedSubtitleTrack>[
      _track(0, language: 'jpn', title: 'Signs & Songs'),
      _track(1, language: 'eng', title: 'English'),
      _track(2, language: 'jpn', title: 'Full'),
    ];
final List<RemoteVideoEmbeddedSubtitleTrack> _ep2Tracks =
    <RemoteVideoEmbeddedSubtitleTrack>[
      _track(0, language: 'jpn', title: 'Signs & Songs'),
      _track(1, language: 'jpn', title: 'Full'),
      _track(2, language: 'eng', title: 'English'),
    ];

RemoteSubtitleChoiceDescriptor _describe(
  String source, {
  List<RemoteVideoEmbeddedSubtitleTrack>? tracks,
  String? videoFileName,
}) => describeRemoteSubtitleChoice(
  source: source,
  embeddedTracks: tracks ?? _ep1Tracks,
  videoFileName: videoFileName,
)!;

RemoteMemberSubtitleMemory _memory(
  String id, {
  String? source,
  RemoteSubtitleChoiceDescriptor? descriptor,
  int playedAt = 0,
}) => (
  memberId: id,
  subtitleSource: source,
  descriptor: descriptor,
  playedAt: playedAt,
);

void main() {
  group('RemoteSubtitleChoiceDescriptor wire', () {
    test('内封轨往返一致，缺省的语言 / 标题不写', () {
      final RemoteSubtitleChoiceDescriptor full = _describe('embedded:2');
      expect(full.source, 'embedded:2');
      expect(full.toJson(), <String, Object?>{
        'source': 'embedded:2',
        'kind': 'embedded',
        'codec': 'subrip',
        'language': 'jpn',
        'title': 'Full',
        'graphic': false,
      });
      final Object? wire = jsonDecode(jsonEncode(full.toJson()));
      expect(RemoteSubtitleChoiceDescriptor.fromJson(wire), full);

      final RemoteSubtitleChoiceDescriptor bare = _describe(
        'embedded:5',
        tracks: <RemoteVideoEmbeddedSubtitleTrack>[
          _track(5, codec: 'hdmv_pgs_subtitle', isText: false),
        ],
      );
      expect(bare.toJson(), <String, Object?>{
        'source': 'embedded:5',
        'kind': 'embedded',
        'codec': 'hdmv_pgs_subtitle',
        'graphic': true,
      });
      expect(RemoteSubtitleChoiceDescriptor.fromJson(bare.toJson()), bare);
    });

    test('host 外挂字幕往返一致', () {
      final RemoteSubtitleChoiceDescriptor d = _describe(
        'hostsidecar:Show.S01E01.1080p.ja.srt',
        videoFileName: 'Show.S01E01.1080p.mkv',
      );
      expect(d.toJson(), <String, Object?>{
        'source': 'hostsidecar:Show.S01E01.1080p.ja.srt',
        'kind': 'host_sidecar',
        'suffix': '.ja.srt',
      });
      expect(
        RemoteSubtitleChoiceDescriptor.fromJson(
          jsonDecode(jsonEncode(d.toJson())),
        ),
        d,
      );
    });

    test('形状不对一律拒收', () {
      for (final Object? bad in <Object?>[
        null,
        'embedded:2',
        <String, Object?>{'kind': 'embedded', 'codec': 'ass', 'graphic': false},
        <String, Object?>{
          'source': 'embedded:x',
          'kind': 'embedded',
          'codec': 'ass',
          'graphic': false,
        },
        <String, Object?>{
          'source': 'embedded:-1',
          'kind': 'embedded',
          'codec': 'ass',
          'graphic': false,
        },
        <String, Object?>{
          'source': 'embedded:1',
          'kind': 'embedded',
          'graphic': false,
        },
        <String, Object?>{
          'source': 'embedded:1',
          'kind': 'embedded',
          'codec': 'ass',
          'graphic': 'no',
        },
        <String, Object?>{
          'source': 'embedded:1',
          'kind': 'embedded',
          'codec': 'ass',
          'graphic': false,
          'language': 3,
        },
        // source 与 kind 对不上。
        <String, Object?>{
          'source': 'hostsidecar:a.srt',
          'kind': 'embedded',
          'codec': 'ass',
          'graphic': false,
        },
        <String, Object?>{
          'source': 'embedded:1',
          'kind': 'host_sidecar',
          'suffix': '.srt',
        },
        <String, Object?>{
          'source': 'hostsidecar:a.srt',
          'kind': 'host_sidecar',
        },
        <String, Object?>{
          'source': 'hostsidecar:',
          'kind': 'host_sidecar',
          'suffix': '.srt',
        },
        <String, Object?>{'source': 'off:', 'kind': 'off'},
      ]) {
        expect(
          RemoteSubtitleChoiceDescriptor.fromJson(bad),
          isNull,
          reason: '$bad',
        );
      }
    });
  });

  group('describeRemoteSubtitleChoice（选轨那一刻写描述）', () {
    test('关闭 / 本机档 / 后端默认 / 轨表里没有的序号都不写', () {
      for (final String source in <String>[
        SubtitleSource.offSentinel,
        '/docs/video_subtitles/ep1.ja.srt',
        'https://host/api/library/videos/ep1/subtitle',
        'embedded:9',
        'embedded:x',
      ]) {
        expect(
          describeRemoteSubtitleChoice(
            source: source,
            embeddedTracks: _ep1Tracks,
            videoFileName: 'Show - 01.mkv',
          ),
          isNull,
          reason: source,
        );
      }
    });

    test('host 外挂字幕：不知道视频文件名、或文件名不以视频主名开头时不写', () {
      expect(
        describeRemoteSubtitleChoice(
          source: 'hostsidecar:Show - 01.ja.srt',
          embeddedTracks: const <RemoteVideoEmbeddedSubtitleTrack>[],
          videoFileName: null,
        ),
        isNull,
      );
      expect(
        describeRemoteSubtitleChoice(
          source: 'hostsidecar:Other.ja.srt',
          embeddedTracks: const <RemoteVideoEmbeddedSubtitleTrack>[],
          videoFileName: 'Show - 01.mkv',
        ),
        isNull,
      );
    });
  });

  group('pickLatestRemoteSiblingSubtitleChoice', () {
    final RemoteSubtitleChoiceDescriptor full = _describe('embedded:2');
    final RemoteSubtitleChoiceDescriptor english = _describe('embedded:1');

    test('取播放时刻最新的兄弟成员，跳过当前成员', () {
      final RemoteSiblingSubtitleChoice? choice =
          pickLatestRemoteSiblingSubtitleChoice(<RemoteMemberSubtitleMemory>[
            _memory(
              'ep1',
              source: 'embedded:2',
              descriptor: full,
              playedAt: 100,
            ),
            _memory(
              'ep2',
              source: 'embedded:1',
              descriptor: english,
              playedAt: 300,
            ),
            _memory(
              'ep3',
              source: 'embedded:1',
              descriptor: english,
              playedAt: 200,
            ),
          ], currentMemberId: 'ep2');
      expect(choice?.subtitleSource, 'embedded:1');
      expect(choice?.descriptor, english);
      final RemoteSiblingSubtitleChoice? fromEp3 =
          pickLatestRemoteSiblingSubtitleChoice(<RemoteMemberSubtitleMemory>[
            _memory(
              'ep1',
              source: 'embedded:2',
              descriptor: full,
              playedAt: 400,
            ),
            _memory(
              'ep3',
              source: 'embedded:1',
              descriptor: english,
              playedAt: 200,
            ),
          ], currentMemberId: 'ep3');
      expect(fromEp3?.descriptor, full);
    });

    test('没有播放时刻 / 没有描述的旧选择 / 描述与选择对不上的成员不参与', () {
      final RemoteSiblingSubtitleChoice? choice =
          pickLatestRemoteSiblingSubtitleChoice(<RemoteMemberSubtitleMemory>[
            _memory(
              'ep1',
              source: 'embedded:2',
              descriptor: full,
              playedAt: 100,
            ),
            // 播得更近但没播放时刻。
            _memory('ep2', source: 'embedded:1', descriptor: english),
            // 旧版本记下的选择，没有描述。
            _memory('ep3', source: 'embedded:0', playedAt: 500),
            // 别处（旧版本 / 同步对端）把选择改成了本机档，描述还是旧的。
            _memory(
              'ep4',
              source: '/docs/video_subtitles/ep4.srt',
              descriptor: english,
              playedAt: 600,
            ),
            _memory('ep5', source: '', playedAt: 700),
          ], currentMemberId: 'ep9');
      expect(choice?.subtitleSource, 'embedded:2');
      expect(choice?.descriptor, full);
    });

    test('off: 不要描述也沿用；同一时刻取靠前的', () {
      final RemoteSiblingSubtitleChoice? off =
          pickLatestRemoteSiblingSubtitleChoice(<RemoteMemberSubtitleMemory>[
            _memory(
              'ep1',
              source: 'embedded:2',
              descriptor: full,
              playedAt: 100,
            ),
            _memory('ep2', source: SubtitleSource.offSentinel, playedAt: 200),
          ], currentMemberId: 'ep3');
      expect(off?.subtitleSource, SubtitleSource.offSentinel);
      expect(off?.descriptor, isNull);

      final RemoteSiblingSubtitleChoice? tie =
          pickLatestRemoteSiblingSubtitleChoice(<RemoteMemberSubtitleMemory>[
            _memory(
              'ep1',
              source: 'embedded:2',
              descriptor: full,
              playedAt: 100,
            ),
            _memory(
              'ep2',
              source: 'embedded:1',
              descriptor: english,
              playedAt: 100,
            ),
          ], currentMemberId: 'ep3');
      expect(tie?.subtitleSource, 'embedded:2');
    });

    test('没有可沿用的兄弟成员返回 null', () {
      expect(
        pickLatestRemoteSiblingSubtitleChoice(<RemoteMemberSubtitleMemory>[
          _memory('ep1', source: 'embedded:2', descriptor: full, playedAt: 1),
        ], currentMemberId: 'ep1'),
        isNull,
      );
      expect(
        pickLatestRemoteSiblingSubtitleChoice(
          const <RemoteMemberSubtitleMemory>[],
          currentMemberId: 'ep1',
        ),
        isNull,
      );
    });
  });

  group('resolveRemoteInheritedSubtitleSource', () {
    String? resolve(
      RemoteSiblingSubtitleChoice choice, {
      List<RemoteVideoEmbeddedSubtitleTrack>? tracks,
      List<RemoteVideoSidecarSubtitle> sidecars =
          const <RemoteVideoSidecarSubtitle>[],
      String? videoFileName = 'Show - 02.mkv',
    }) => resolveRemoteInheritedSubtitleSource(
      choice: choice,
      embeddedTracks: tracks ?? _ep2Tracks,
      sidecars: sidecars,
      videoFileName: videoFileName,
    );

    RemoteSiblingSubtitleChoice embedded(
      int index, {
      List<RemoteVideoEmbeddedSubtitleTrack>? from,
    }) {
      final RemoteSubtitleChoiceDescriptor d = _describe(
        'embedded:$index',
        tracks: from,
      );
      return (subtitleSource: d.source, descriptor: d);
    }

    test('off: 沿用关闭', () {
      expect(
        resolve((subtitleSource: SubtitleSource.offSentinel, descriptor: null)),
        SubtitleSource.offSentinel,
      );
    });

    test('两个成员轨顺序不同：按语言 + 标题落到本成员的序号', () {
      // ep1 的 Full 是 embedded:2，ep2 里 Full 是 embedded:1。
      expect(resolve(embedded(2)), 'embedded:1');
      expect(resolve(embedded(1)), 'embedded:2');
      expect(resolve(embedded(0)), 'embedded:0');
    });

    test('标题对不上的同语言轨不顶替；没有对应轨返回 null', () {
      final List<RemoteVideoEmbeddedSubtitleTrack> onlySigns =
          <RemoteVideoEmbeddedSubtitleTrack>[
            _track(0, language: 'jpn', title: 'Signs & Songs'),
            _track(1, language: 'eng', title: 'English'),
          ];
      expect(resolve(embedded(2), tracks: onlySigns), isNull);
      // 无标题的同语言轨可以顶（ja / jpn 归一）。
      expect(
        resolve(
          embedded(2),
          tracks: <RemoteVideoEmbeddedSubtitleTrack>[
            _track(0, language: 'jpn', title: 'Signs & Songs'),
            _track(3, language: 'ja'),
          ],
        ),
        'embedded:3',
      );
    });

    test('文本轨不拿图形轨顶替', () {
      expect(
        resolve(
          embedded(2),
          tracks: <RemoteVideoEmbeddedSubtitleTrack>[
            _track(
              0,
              codec: 'hdmv_pgs_subtitle',
              language: 'jpn',
              title: 'Full',
              isText: false,
            ),
          ],
        ),
        isNull,
      );
    });

    test('描述与选择对不上 / 没有描述：不猜', () {
      final RemoteSubtitleChoiceDescriptor full = _describe('embedded:2');
      expect(resolve((subtitleSource: 'embedded:1', descriptor: full)), isNull);
      expect(resolve((subtitleSource: 'embedded:2', descriptor: null)), isNull);
    });

    test('host 外挂字幕按尾巴找本成员的那一条（发布组文件名带点也行）', () {
      final RemoteSubtitleChoiceDescriptor d = _describe(
        'hostsidecar:Show.S01E01.1080p.ja.srt',
        videoFileName: 'Show.S01E01.1080p.mkv',
      );
      final RemoteSiblingSubtitleChoice choice = (
        subtitleSource: d.source,
        descriptor: d,
      );
      final List<RemoteVideoSidecarSubtitle> sidecars =
          <RemoteVideoSidecarSubtitle>[
            _sidecar('Show.S01E02.1080p.en.srt'),
            _sidecar('Show.S01E02.1080p.ja.srt'),
          ];
      expect(
        resolve(
          choice,
          sidecars: sidecars,
          videoFileName: 'Show.S01E02.1080p.mkv',
        ),
        'hostsidecar:Show.S01E02.1080p.ja.srt',
      );
      // 本成员没有同尾巴的：不退第一个外挂。
      expect(
        resolve(
          choice,
          sidecars: <RemoteVideoSidecarSubtitle>[
            _sidecar('Show.S01E02.1080p.en.srt'),
          ],
          videoFileName: 'Show.S01E02.1080p.mkv',
        ),
        isNull,
      );
      // 不知道本成员的视频文件名：不猜。
      expect(resolve(choice, sidecars: sidecars, videoFileName: null), isNull);
    });
  });

  test('sidecarSubtitleNameSuffix 与同目录版同口径', () {
    expect(
      sidecarSubtitleNameSuffix(
        videoFileName: 'Show - 01.mkv',
        subtitleFileName: 'show - 01.JA.srt',
      ),
      '.ja.srt',
    );
    expect(
      sidecarSubtitleNameSuffix(
        videoFileName: 'Show - 01.mkv',
        subtitleFileName: 'Show - 01.txt',
      ),
      isNull,
    );
    expect(
      sidecarSubtitleNameSuffix(
        videoFileName: 'Show - 01.mkv',
        subtitleFileName: 'Show - 02.ja.srt',
      ),
      isNull,
    );
  });
}
