// BUG-5464：合集里一集自己没选过字幕时，沿用同合集兄弟集最近一次的字幕选择。
//
// 钉子（纯函数，`video_subtitle_inherit.dart`）：
// - 兄弟集选择：按 lastPlayedAt 取最近、跳过当前集 / 没有选择 / 没有播放时刻的行；
// - 意图：`off:` 沿用关闭；`embedded:<n>` 只拿序号去兄弟集读描述；同目录同名 sidecar
//   取去掉视频主名后的后缀；下载 / 导入进 video_subtitles 的单集字幕档不沿用（BUG-165）；
// - 内封轨按语言 + 轨标题匹配，两集轨顺序不同也对得上，Signs 不顶替 Full，缺语言标签
//   不算冲突，序号只做决胜；
// - 落到新集枚举：没有对应的源返回 null（调用方照常兜底）。
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_subtitle_inherit.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:test/test.dart';

VideoBookRow _row(
  String uid, {
  String? subtitleSource,
  int? lastPlayedAt,
  String? videoPath,
}) => VideoBookRow(
  bookUid: uid,
  title: uid,
  videoPath: videoPath ?? '/media/Show/$uid.mkv',
  subtitleSource: subtitleSource,
  lastPlayedAt: lastPlayedAt,
  lastPositionMs: 0,
  currentEpisode: 0,
  delayMs: 0,
);

EmbeddedSubtitleTrack _track(
  int index, {
  String codec = 'ass',
  String? language,
  String? title,
}) => EmbeddedSubtitleTrack(
  streamIndex: index,
  codec: codec,
  language: language,
  title: title,
);

SubtitleSourceListing _listing(
  List<EmbeddedSubtitleTrack> tracks, {
  List<String> externalPaths = const <String>[],
}) => SubtitleSourceListing(
  sources: <SubtitleSource>[
    for (final EmbeddedSubtitleTrack t in tracks)
      SubtitleSource.embedded(
        streamIndex: t.streamIndex,
        label: t.title ?? 'track ${t.streamIndex}',
        language: t.language,
        codec: t.codec,
      ),
    for (final String path in externalPaths)
      SubtitleSource.external(externalPath: path, label: path),
  ],
  embeddedProbe: EmbeddedSubtitleTrackProbeResult(
    tracks: tracks,
    status: EmbeddedSubtitleTrackProbeStatus.success,
    timeout: const Duration(seconds: 1),
    sizeBytes: 1,
  ),
);

void main() {
  group('pickLatestSiblingSubtitleChoice', () {
    test('取有选择的兄弟集里最近播放的那一集', () {
      final SiblingSubtitleChoice? choice =
          pickLatestSiblingSubtitleChoice(<VideoBookRow>[
            _row('ep1', subtitleSource: 'embedded:1', lastPlayedAt: 100),
            _row('ep2'),
            _row('ep3', subtitleSource: 'embedded:2', lastPlayedAt: 300),
            _row('ep4', subtitleSource: 'embedded:0', lastPlayedAt: 200),
          ], currentBookUid: 'ep2');
      expect(choice, isNotNull);
      expect(choice!.subtitleSource, 'embedded:2');
      expect(choice.videoPath, '/media/Show/ep3.mkv');
    });

    test('跳过当前集自己（哪怕它最近）、没有选择的、没有播放时刻的', () {
      final SiblingSubtitleChoice? choice =
          pickLatestSiblingSubtitleChoice(<VideoBookRow>[
            _row('ep1', subtitleSource: 'embedded:1', lastPlayedAt: 100),
            _row('ep2', subtitleSource: 'embedded:5', lastPlayedAt: 900),
            _row('ep3', lastPlayedAt: 800),
            _row('ep4', subtitleSource: '', lastPlayedAt: 700),
            _row('ep5', subtitleSource: '/media/Show/ep5.ja.srt'),
          ], currentBookUid: 'ep2');
      expect(choice?.subtitleSource, 'embedded:1');
    });

    test('关闭哨兵也是一次选择', () {
      expect(
        pickLatestSiblingSubtitleChoice(<VideoBookRow>[
          _row('ep1', subtitleSource: 'embedded:1', lastPlayedAt: 100),
          _row(
            'ep3',
            subtitleSource: SubtitleSource.offSentinel,
            lastPlayedAt: 200,
          ),
        ], currentBookUid: 'ep2')?.subtitleSource,
        SubtitleSource.offSentinel,
      );
    });

    test('同一时刻取合集顺序靠前的一集', () {
      expect(
        pickLatestSiblingSubtitleChoice(<VideoBookRow>[
          _row('ep1', subtitleSource: 'embedded:1', lastPlayedAt: 100),
          _row('ep3', subtitleSource: 'embedded:3', lastPlayedAt: 100),
        ], currentBookUid: 'ep2')?.subtitleSource,
        'embedded:1',
      );
    });

    test('没有可借的选择 → null', () {
      expect(
        pickLatestSiblingSubtitleChoice(<VideoBookRow>[
          _row('ep1'),
          _row('ep2', subtitleSource: 'embedded:1', lastPlayedAt: 100),
        ], currentBookUid: 'ep2'),
        isNull,
      );
      expect(
        pickLatestSiblingSubtitleChoice(
          const <VideoBookRow>[],
          currentBookUid: 'ep2',
        ),
        isNull,
      );
    });
  });

  group('inheritedSubtitleIntent', () {
    test('off: → 沿用关闭', () {
      expect(
        inheritedSubtitleIntent((
          videoPath: '/media/Show/ep1.mkv',
          subtitleSource: SubtitleSource.offSentinel,
        )),
        isA<InheritSubtitleOff>(),
      );
    });

    test('embedded:<n> → 记下兄弟集视频与序号（只用来读描述）', () {
      final InheritedSubtitleIntent? intent = inheritedSubtitleIntent((
        videoPath: '/media/Show/ep1.mkv',
        subtitleSource: 'embedded:2',
      ));
      expect(intent, isA<InheritEmbeddedSubtitle>());
      intent as InheritEmbeddedSubtitle;
      expect(intent.previousVideoPath, '/media/Show/ep1.mkv');
      expect(intent.streamIndex, 2);
    });

    test('坏的 embedded 值 / hostsidecar 编码 → null', () {
      for (final String bad in <String>[
        'embedded:',
        'embedded:x',
        'embedded:-1',
        'hostsidecar:ep1.ja.srt',
      ]) {
        expect(
          inheritedSubtitleIntent((
            videoPath: '/media/Show/ep1.mkv',
            subtitleSource: bad,
          )),
          isNull,
          reason: bad,
        );
      }
    });

    test('同目录同名 sidecar → 去掉视频主名后的后缀（主名里带点也切得对）', () {
      final InheritedSubtitleIntent? intent = inheritedSubtitleIntent((
        videoPath: '/media/Show/[Grp] Show.S01E01.1080p.mkv',
        subtitleSource: '/media/Show/[Grp] Show.S01E01.1080p.JA.srt',
      ));
      expect(intent, isA<InheritSidecarSubtitle>());
      expect((intent! as InheritSidecarSubtitle).suffix, '.ja.srt');
    });

    test('BUG-165：下载 / 导入进 video_subtitles 的单集字幕档不沿用', () {
      expect(
        inheritedSubtitleIntent((
          videoPath: '/media/Anime/Re Zero/S04E01.mkv',
          subtitleSource:
              '/home/u/Documents/app/video_subtitles/'
              '(Hi10)_Re_Zero_-_01_(BD_720p).ja-en.ass',
        )),
        isNull,
      );
    });

    test('别的文件夹挑的档、不是同名前缀的同目录档、非字幕扩展名 → null', () {
      for (final String path in <String>[
        '/media/subs/S01E01.ja.srt',
        '/media/Show/other-episode.ja.srt',
        '/media/Show/ep1.ja.txt',
      ]) {
        expect(
          inheritedSubtitleIntent((
            videoPath: '/media/Show/ep1.mkv',
            subtitleSource: path,
          )),
          isNull,
          reason: path,
        );
      }
    });
  });

  group('matchEmbeddedSubtitleTrack', () {
    final List<EmbeddedSubtitleTrack> ep1 = <EmbeddedSubtitleTrack>[
      _track(0, language: 'eng', title: 'English'),
      _track(1, language: 'jpn', title: 'Full'),
      _track(2, language: 'jpn', title: 'Signs & Songs'),
    ];

    test('两集轨顺序不同：按语言 + 标题对上，不按序号', () {
      final List<EmbeddedSubtitleTrack> ep2 = <EmbeddedSubtitleTrack>[
        _track(0, language: 'jpn', title: 'Signs & Songs'),
        _track(1, language: 'eng', title: 'English'),
        _track(2, language: 'jpn', title: 'Full'),
      ];
      expect(matchEmbeddedSubtitleTrack(ep1[1], ep2)?.streamIndex, 2);
      expect(matchEmbeddedSubtitleTrack(ep1[2], ep2)?.streamIndex, 0);
      expect(matchEmbeddedSubtitleTrack(ep1[0], ep2)?.streamIndex, 1);
    });

    test('标题比较忽略大小写与标点、语言 jpn / ja 视为同一种', () {
      final List<EmbeddedSubtitleTrack> ep2 = <EmbeddedSubtitleTrack>[
        _track(0, language: 'ja', title: 'signs/songs'),
        _track(1, language: 'ja', title: ' FULL '),
      ];
      expect(matchEmbeddedSubtitleTrack(ep1[1], ep2)?.streamIndex, 1);
      expect(matchEmbeddedSubtitleTrack(ep1[2], ep2)?.streamIndex, 0);
    });

    test('Signs 不顶替 Full：同语言只有别的标题时不匹配', () {
      final List<EmbeddedSubtitleTrack> ep2 = <EmbeddedSubtitleTrack>[
        _track(0, language: 'eng', title: 'English'),
        _track(1, language: 'jpn', title: 'Signs & Songs'),
      ];
      expect(matchEmbeddedSubtitleTrack(ep1[1], ep2), isNull);
    });

    test('新集同语言的轨没有标题：可以顶上（标题对不上才排除）', () {
      final List<EmbeddedSubtitleTrack> ep2 = <EmbeddedSubtitleTrack>[
        _track(0, language: 'eng'),
        _track(1, language: 'jpn', title: 'Signs & Songs'),
        _track(2, language: 'jpn'),
      ];
      expect(matchEmbeddedSubtitleTrack(ep1[1], ep2)?.streamIndex, 2);
    });

    test('缺语言标签不算冲突：同标题照样对上', () {
      final List<EmbeddedSubtitleTrack> ep2 = <EmbeddedSubtitleTrack>[
        _track(0, title: 'Signs & Songs'),
        _track(1, title: 'Full'),
      ];
      expect(matchEmbeddedSubtitleTrack(ep1[1], ep2)?.streamIndex, 1);
      final EmbeddedSubtitleTrack untaggedFull = _track(4, title: 'Full');
      expect(
        matchEmbeddedSubtitleTrack(untaggedFull, <EmbeddedSubtitleTrack>[
          _track(0, language: 'eng', title: 'English'),
          _track(1, language: 'jpn', title: 'Full'),
        ])?.streamIndex,
        1,
      );
    });

    test('两边都声明了语言且不同：同标题也不匹配', () {
      expect(
        matchEmbeddedSubtitleTrack(ep1[1], <EmbeddedSubtitleTrack>[
          _track(0, language: 'eng', title: 'Full'),
        ]),
        isNull,
      );
    });

    test('只有语言、没有标题：同语言里序号决胜，其次按轨序', () {
      final EmbeddedSubtitleTrack wanted = _track(1, language: 'jpn');
      expect(
        matchEmbeddedSubtitleTrack(wanted, <EmbeddedSubtitleTrack>[
          _track(0, language: 'jpn'),
          _track(1, language: 'jpn'),
        ])?.streamIndex,
        1,
      );
      expect(
        matchEmbeddedSubtitleTrack(wanted, <EmbeddedSubtitleTrack>[
          _track(0, language: 'eng'),
          _track(2, language: 'jpn'),
          _track(3, language: 'jpn'),
        ])?.streamIndex,
        2,
      );
    });

    test('完全没有描述：只认新集同序号、同样没有描述的那条', () {
      final EmbeddedSubtitleTrack wanted = _track(1);
      expect(
        matchEmbeddedSubtitleTrack(wanted, <EmbeddedSubtitleTrack>[
          _track(0),
          _track(1),
        ])?.streamIndex,
        1,
      );
      expect(
        matchEmbeddedSubtitleTrack(wanted, <EmbeddedSubtitleTrack>[
          _track(0),
          _track(1, language: 'jpn', title: 'Full'),
        ]),
        isNull,
      );
    });

    test('文本轨不拿图形轨顶替，反之亦然', () {
      expect(
        matchEmbeddedSubtitleTrack(ep1[1], <EmbeddedSubtitleTrack>[
          _track(0, codec: 'hdmv_pgs_subtitle', language: 'jpn', title: 'Full'),
        ]),
        isNull,
      );
      expect(
        matchEmbeddedSubtitleTrack(
          _track(0, codec: 'hdmv_pgs_subtitle', language: 'jpn'),
          <EmbeddedSubtitleTrack>[
            _track(0, language: 'jpn'),
            _track(1, codec: 'hdmv_pgs_subtitle', language: 'jpn'),
          ],
        )?.streamIndex,
        1,
      );
    });

    test('同标题多条：同序号决胜', () {
      expect(
        matchEmbeddedSubtitleTrack(ep1[1], <EmbeddedSubtitleTrack>[
          _track(0, language: 'jpn', title: 'Full'),
          _track(1, language: 'jpn', title: 'Full'),
        ])?.streamIndex,
        1,
      );
    });
  });

  group('resolveInheritedSubtitleSource', () {
    const String ep2Video = '/media/Show/[Grp] Show - 02.mkv';

    test('内封：兄弟集序号 → 描述 → 新集对应的源', () {
      final SubtitleSource? source = resolveInheritedSubtitleSource(
        intent: const InheritEmbeddedSubtitle(
          previousVideoPath: '/media/Show/[Grp] Show - 01.mkv',
          streamIndex: 1,
        ),
        previousEmbeddedTracks: <EmbeddedSubtitleTrack>[
          _track(0, language: 'eng', title: 'English'),
          _track(1, language: 'jpn', title: 'Full'),
        ],
        videoPath: ep2Video,
        listing: _listing(<EmbeddedSubtitleTrack>[
          _track(0, language: 'jpn', title: 'Full'),
          _track(1, language: 'eng', title: 'English'),
        ]),
      );
      expect(source?.isEmbedded, isTrue);
      expect(source?.toPersistedValue(), 'embedded:0');
    });

    test('兄弟集轨表读不到（文件不在 / 那条轨没了）→ null，不按序号瞎猜', () {
      expect(
        resolveInheritedSubtitleSource(
          intent: const InheritEmbeddedSubtitle(
            previousVideoPath: '/media/Show/gone.mkv',
            streamIndex: 1,
          ),
          previousEmbeddedTracks: const <EmbeddedSubtitleTrack>[],
          videoPath: ep2Video,
          listing: _listing(<EmbeddedSubtitleTrack>[
            _track(0, language: 'jpn'),
            _track(1, language: 'eng'),
          ]),
        ),
        isNull,
      );
    });

    test('sidecar：按后缀挑新集的同名字幕', () {
      final SubtitleSource? source = resolveInheritedSubtitleSource(
        intent: const InheritSidecarSubtitle('.de.srt'),
        previousEmbeddedTracks: const <EmbeddedSubtitleTrack>[],
        videoPath: ep2Video,
        listing: _listing(
          <EmbeddedSubtitleTrack>[_track(0, language: 'jpn')],
          externalPaths: <String>[
            '/media/Show/[Grp] Show - 02.ja.srt',
            '/media/Show/[Grp] Show - 02.de.srt',
          ],
        ),
      );
      expect(source?.externalPath, '/media/Show/[Grp] Show - 02.de.srt');
    });

    test('sidecar：新集没有同后缀的 → null（不退「第一个外挂」）', () {
      expect(
        resolveInheritedSubtitleSource(
          intent: const InheritSidecarSubtitle('.de.srt'),
          previousEmbeddedTracks: const <EmbeddedSubtitleTrack>[],
          videoPath: ep2Video,
          listing: _listing(
            const <EmbeddedSubtitleTrack>[],
            externalPaths: <String>[
              '/media/Show/[Grp] Show - 02.ja.srt',
              '/media/Show/[Grp] Show - 02.de.ass',
            ],
          ),
        ),
        isNull,
      );
    });

    test('关闭不需要枚举：恒 null，由调用方直接按关闭处理', () {
      expect(
        resolveInheritedSubtitleSource(
          intent: const InheritSubtitleOff(),
          previousEmbeddedTracks: const <EmbeddedSubtitleTrack>[],
          videoPath: ep2Video,
          listing: _listing(<EmbeddedSubtitleTrack>[_track(0)]),
        ),
        isNull,
      );
    });
  });

  test('normalizeSubtitleTrackTitle', () {
    expect(normalizeSubtitleTrackTitle('Signs & Songs'), 'signs songs');
    expect(
      normalizeSubtitleTrackTitle('  [SubsPlease]  Full '),
      'subsplease full',
    );
    expect(normalizeSubtitleTrackTitle('日本語（全）'), '日本語 全');
    expect(normalizeSubtitleTrackTitle(null), '');
    expect(normalizeSubtitleTrackTitle(' - '), '');
  });
}
