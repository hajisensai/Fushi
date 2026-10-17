// BUG-3065 / BUG-3066 / BUG-3067：「一口气下载全部哆啦A梦剧场版」实测选错的版本。
//
// 2026-10-08 用户实测（TMDB 合集 47 部，每部带日文标题 + 年份），每条「错选」都是
// 下面用例里原样的发布名：重制版 / 续作被当成本作（身份），国语 / 英配 / 内嵌字幕
// 被当成原语言（语言），老片的「WEB-4k」超分与 DVD 压过 1080p（画质）。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/torrent/video_release_language.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_work_match.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_reducer.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_resource_picker.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_franchise.dart';
import 'package:fushi_engine/media/video/download/video_resource_version_groups.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

int _nextId = 0;

class _Resource extends VideoResourceCandidate {
  _Resource(String title, {super.seeders = 10, super.resolution})
    : super(
        remoteId: 'r${_nextId++}',
        title: title,
        providerId: 'nyaa',
        providerInstanceId: 'nyaa',
        providerPriority: 100,
        trusted: false,
      );
}

VideoMediaReference _movie(
  String title, {
  required int year,
  List<String> aliases = const <String>[],
}) => VideoMediaReference(
  providerId: 'tmdb',
  mediaId: 'm$year-${title.hashCode}',
  mediaKind: VideoMetadataMediaKind.movie,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: title,
  originalTitle: title,
  aliases: aliases,
  year: year,
);

VideoResourceWorkMismatch? _mismatch(
  String release,
  VideoMediaReference work,
) => videoResourceWorkMismatch(
  release,
  VideoResourceWorkTarget.fromReference(work),
);

// ---- 用户实测的错选（原样） ------------------------------------------------

const String _byg2020 =
    '[BYG-RAWS][哆啦A梦：大雄的新恐龙/Doraemon Nobita\'s New Dinosaur]'
    '[WEB-4k][MP4][国语中字]';
const String _dmg2014 =
    '[DMG][映画 ドラえもん 新・のび太の大魔境 ~ペコと5人の探検隊~][BDrip]'
    '[簡繁外掛][1080P]';
const String _yyq2026 =
    '[YYQ字幕组][哆啦A梦剧场版：新·大雄的海底鬼岩城 / Doraemon the Movie: '
    'Nobita\'s New Underwater Castle / 映画ドラえもん 新・のび太の海底鬼岩城]'
    '[BDRIP][1080P][AVC_AAC][简日内嵌][MP4]';
const String _vcb2016 =
    '[VCB-Studio] Eiga Doraemon: Shin Nobita no Nippon Tanjou/映画ドラえもん '
    '新・のび太の日本誕生 8bit 1080p HEVC BDRip [Fin]';
const String _standByMe2 =
    '[MLSUB&VCB-Studio] Stand By Me Doraemon 2 / STAND BY ME ドラえもん 2 '
    '10-bit 1080p HEVC BDRip [MOVIE Fin]';
const String _ripp2021 =
    '[RIPP RAWS] Eiga Doraemon: Nobita no Little Star Wars 2021 [1080p]'
    '[English Sub]';
const String _englishDub1998 =
    '[TWiLiGHT_TWiNKLE] Doraemon: Nobita\'s Great Adventure in the South Seas '
    '(1998) (Disney XD Asia English Dub Restoration)';

// ---- 同一部作品的正确版本 ------------------------------------------------

const String _fabre1989 = '[Fabre-RAW] Doraemon Movie 10 (1989) [1080p].mkv';
const String _named1989 =
    'Doraemon Movie 10 - Nobita no Nippon Tanjou (1989) 1080p';

final VideoMediaReference _dinosaur1980 = _movie(
  '映画ドラえもん のび太の恐竜',
  year: 1980,
  aliases: const <String>['Doraemon: Nobita\'s Dinosaur'],
);
final VideoMediaReference _makyou1982 = _movie('映画ドラえもん のび太の大魔境', year: 1982);
final VideoMediaReference _kiganjou1983 = _movie(
  '映画ドラえもん のび太の海底鬼岩城',
  year: 1983,
);
final VideoMediaReference _nippon1989 = _movie(
  '映画ドラえもん のび太の日本誕生',
  year: 1989,
  aliases: const <String>['Eiga Doraemon: Nobita no Nippon Tanjou'],
);
final VideoMediaReference _standByMe2014 = _movie(
  'STAND BY ME ドラえもん',
  year: 2014,
  aliases: const <String>['Stand by Me Doraemon'],
);
final VideoMediaReference _standByMe2020 = _movie(
  'STAND BY ME ドラえもん 2',
  year: 2020,
  aliases: const <String>['Stand by Me Doraemon 2'],
);
final VideoMediaReference _starWars1985 = _movie(
  '映画ドラえもん のび太の宇宙小戦争',
  year: 1985,
);
final VideoMediaReference _starWars2022 = _movie(
  '映画ドラえもん のび太の宇宙小戦争 2021',
  year: 2022,
);

void main() {
  group('作品身份（BUG-3065）', () {
    test('重制版：新・ / 新· / 插入「新」「Shin」「New」都判成别的作品', () {
      expect(
        _mismatch(_byg2020, _dinosaur1980),
        VideoResourceWorkMismatch.remake,
      );
      expect(
        _mismatch(_dmg2014, _makyou1982),
        VideoResourceWorkMismatch.remake,
      );
      expect(
        _mismatch(_yyq2026, _kiganjou1983),
        VideoResourceWorkMismatch.remake,
      );
      expect(
        _mismatch(_vcb2016, _nippon1989),
        VideoResourceWorkMismatch.remake,
      );
      // 只有拉丁写法时靠「在目标标题里插入 Shin」认出来。
      expect(
        _mismatch(
          'Eiga Doraemon: Shin Nobita no Nippon Tanjou 1080p',
          _nippon1989,
        ),
        VideoResourceWorkMismatch.remake,
      );
    });

    test('重制版本身是目标时不误杀（目标标题自带「新」）', () {
      final VideoMediaReference nippon2016 = _movie(
        '映画ドラえもん 新・のび太の日本誕生',
        year: 2016,
        aliases: const <String>['Eiga Doraemon: Shin Nobita no Nippon Tanjou'],
      );
      expect(_mismatch(_vcb2016, nippon2016), isNull);
      final VideoMediaReference dinosaur2020 = _movie(
        '映画ドラえもん のび太の新恐竜',
        year: 2020,
        aliases: const <String>['Doraemon: Nobita\'s New Dinosaur'],
      );
      expect(_mismatch(_byg2020, dinosaur2020), isNull);
    });

    test('续作序号：本作要 2014，「… 2」是别的作品；反过来也一样', () {
      expect(
        _mismatch(_standByMe2, _standByMe2014),
        VideoResourceWorkMismatch.sequel,
      );
      const String standByMe1 =
          '[VCB-Studio] STAND BY ME ドラえもん / Stand by Me Doraemon '
          '10-bit 1080p HEVC BDRip [MOVIE Fin]';
      expect(_mismatch(standByMe1, _standByMe2014), isNull);
      expect(_mismatch(_standByMe2, _standByMe2020), isNull);
      // 声道 / 位深紧跟标题时不是续作序号。
      expect(
        _mismatch('Stand by Me Doraemon 5.1 DTS 1080p', _standByMe2014),
        isNull,
      );
      expect(
        _mismatch(standByMe1, _standByMe2020),
        VideoResourceWorkMismatch.sequel,
      );
    });

    test('标题里别的年份：1985 不收 2021 的新版，2022 那部收', () {
      expect(
        _mismatch(_ripp2021, _starWars1985),
        VideoResourceWorkMismatch.year,
      );
      expect(_mismatch(_ripp2021, _starWars2022), isNull);
    });

    test('多部合集包（年份区间）不当成任何一部，连区间端点那部也不当', () {
      const String pack =
          '[Fabre-RAW] Doraemon Movies 01-25 (1980-2004) [WEB-DL 1080p]';
      expect(
        _mismatch(pack, _dinosaur1980),
        VideoResourceWorkMismatch.collection,
      );
      expect(_mismatch(pack, _nippon1989), VideoResourceWorkMismatch.year);
      // 首映 / 上映跨年的 ±1 区间不是合集。
      expect(
        _mismatch('[G] Nobita no Kyouryuu (1980-1981) [1080p]', _dinosaur1980),
        isNull,
      );
    });

    test('正确版本（编号 / 罗马字 / 年份写法）不被误杀', () {
      expect(_mismatch(_fabre1989, _nippon1989), isNull);
      expect(_mismatch(_named1989, _nippon1989), isNull);
      expect(
        _mismatch(
          '[Ommex] Doraemon Movie 19 - Nobita no Nankai Daibouken (1998) [1080p]',
          _movie('映画ドラえもん のび太の南海大冒険', year: 1998),
        ),
        isNull,
      );
    });

    test('1989：VCB 的《新·日本诞生》被清洗掉，编号版胜出', () {
      final List<VideoResourceCandidate> cleaned = cleanResourceCandidates(
        <VideoResourceCandidate>[
          _Resource(_vcb2016, seeders: 500),
          _Resource(_fabre1989, seeders: 5),
          _Resource(_named1989, seeders: 3),
        ],
        skipExtras: false,
        work: VideoResourceWorkTarget.fromReference(_nippon1989),
      );
      expect(cleaned.map((VideoResourceCandidate c) => c.title), <String>[
        _fabre1989,
        _named1989,
      ]);
    });
  });

  group('原语言（BUG-3066）', () {
    test('配音：国语 / English Dub 判成只有配音；双音轨不算', () {
      expect(releaseIsDubOnly(_byg2020), isTrue);
      expect(releaseIsDubOnly(_englishDub1998), isTrue);
      expect(
        releaseIsDubOnly('[G] Movie (1998) [Dual-Audio] English Dub 1080p'),
        isFalse,
      );
      expect(releaseIsDubOnly('[G][国日双语][1080P]'), isFalse);
      expect(releaseIsDubOnly(_ripp2021), isFalse);
      expect(releaseIsDubOnly('[G] Dubai Story 1080p'), isFalse);
      expect(releaseIsDubOnly('[G][简日双语][1080P]'), isFalse);
    });

    test('硬字幕：内嵌 / 中字（没写外挂）是烧进画面的；外挂 / 内封不是', () {
      expect(releaseHasBurnedInSubtitles(_byg2020), isTrue);
      expect(releaseHasBurnedInSubtitles(_yyq2026), isTrue);
      expect(releaseHasBurnedInSubtitles('[G] Movie [HardSub] 1080p'), isTrue);
      expect(releaseHasBurnedInSubtitles(_dmg2014), isFalse);
      expect(releaseHasBurnedInSubtitles('[G][中字][外挂][1080P]'), isFalse);
      expect(releaseHasBurnedInSubtitles('[G][简日内封][1080P]'), isFalse);
      expect(releaseHasBurnedInSubtitles(_ripp2021), isFalse);
    });

    test('要原语言时清掉配音 / 硬字幕；不要求时照留', () {
      final List<VideoResourceCandidate> items = <VideoResourceCandidate>[
        _Resource(_englishDub1998, seeders: 300),
        _Resource(
          '[Ommex] Doraemon Movie 19 - Nobita no Nankai Daibouken (1998) [1080p]',
        ),
      ];
      expect(
        cleanResourceCandidates(
          items,
          skipExtras: false,
          originalLanguageOnly: true,
        ).map((VideoResourceCandidate c) => c.title),
        <String>[
          '[Ommex] Doraemon Movie 19 - Nobita no Nankai Daibouken (1998) [1080p]',
        ],
      );
      expect(cleanResourceCandidates(items, skipExtras: false), hasLength(2));
    });
  });

  group('画质（BUG-3067）', () {
    VideoResourceVersionGroup group(String title, {String? resolution}) =>
        buildVideoResourceVersionGroups(<VideoResourceCandidate>[
          _Resource(title, resolution: resolution),
        ]).single;

    test('超分嫌疑：老片的网络源 4K、明写 upscale / 超分；UHD 蓝光与新片不算', () {
      expect(isSuspectedUpscale(group(_byg2020), workYear: 1980), isTrue);
      expect(isSuspectedUpscale(group(_byg2020), workYear: 2020), isFalse);
      expect(
        isSuspectedUpscale(
          group('[G] Movie (1980) 2160p UHD BluRay Remux'),
          workYear: 1980,
        ),
        isFalse,
      );
      expect(
        isSuspectedUpscale(group('[G] Movie (2014) [AI Upscale 4K]')),
        isTrue,
      );
      expect(isSuspectedUpscale(group('[G] 电影 [超分][1080P]')), isTrue);
      expect(
        isSuspectedUpscale(group('[G] Ai no Uta (2014) [1080p]')),
        isFalse,
      );
    });

    test('会话 1080p 一张都没有时：退到最近的一档，超分 4K 与 DVD 殿后', () {
      final List<VideoResourceVersionGroup> groups =
          buildVideoResourceVersionGroups(<VideoResourceCandidate>[
            _Resource(
              '[BYG-RAWS] Doraemon Nobita no Kyouryuu (1980) [WEB-4k]',
              seeders: 900,
              resolution: '2160p',
            ),
            _Resource(
              '[D] Doraemon Nobita no Kyouryuu 1980 dvd [872x480]',
              seeders: 500,
              resolution: '480p',
            ),
            _Resource(
              '[W] Doraemon Nobita no Kyouryuu (1980) [WEB-DL 720p]',
              seeders: 2,
              resolution: '720p',
            ),
          ]);
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        groups,
        mode: VideoAcquisitionMode.download,
        quality: VideoAcquisitionQuality.best,
        nearestHeight: 1080,
        workYear: 1980,
      );
      expect(
        outcome.eligible.map((VideoResourceVersionGroup g) => g.resolution),
        <String?>['720p', '480p', '2160p'],
      );
    });

    test('整套计划：会话 1080p 没有时退到离 1080p 最近的 720p，不是最高的 2160p', () {
      final VideoAcquisitionFranchiseEntry planned = planFranchiseEntry(
        VideoAcquisitionFranchiseEntry(
          item: VideoDiscoveryItem(
            reference: _movie('映画ドラえもん のび太の新恐竜', year: 2020),
          ),
        ),
        VideoAcquisitionFranchiseEntryResolvedEvent(
          index: 0,
          items: <VideoResourceCandidate>[
            _Resource(
              '[UHD] Doraemon Nobita no Shin Kyouryuu (2020) 2160p WEB-DL',
              seeders: 900,
              resolution: '2160p',
            ),
            _Resource(
              '[HD] Doraemon Nobita no Shin Kyouryuu (2020) 720p WEB-DL',
              seeders: 3,
              resolution: '720p',
            ),
          ],
        ),
        quality: VideoAcquisitionQuality.p1080,
        defaults: const VideoAcquisitionDefaults(),
      );
      expect(planned.status, VideoAcquisitionFranchiseEntryStatus.ready);
      expect(planned.plan!.group.resolution, '720p');
    });

    test('同为 1080p：DVD 片源的放大版排在 WEB-DL / BD 后面', () {
      final List<VideoResourceVersionGroup> groups =
          buildVideoResourceVersionGroups(<VideoResourceCandidate>[
            _Resource('[DV] Movie (1985) DVDRip 1080p', seeders: 900),
            _Resource('[WB] Movie (1985) WEB-DL 1080p', seeders: 1),
          ]);
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        groups,
        mode: VideoAcquisitionMode.download,
        quality: VideoAcquisitionQuality.p1080,
      );
      expect(outcome.eligible.first.releaseGroup, 'WB');
    });
  });

  group('整套下载端到端（reducer）', () {
    const VideoAcquisitionDefaults defaults = VideoAcquisitionDefaults(
      qualityPref: '1080p',
      subtitleLanguagePref: kVideoAcquisitionSubtitleOriginal,
      sources: <VideoAcquisitionSource>[
        VideoAcquisitionSource(id: 7, label: 'Anime'),
      ],
    );
    final VideoDiscoveryItem anchor = VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'tmdb',
        mediaId: 'tv',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'ドラえもん',
        originalTitle: 'ドラえもん',
        year: 2005,
      ),
    );

    VideoAcquisitionState reachFranchise(List<VideoMediaReference> movies) {
      VideoAcquisitionState state = const VideoAcquisitionState();
      for (final VideoAcquisitionEvent event in <VideoAcquisitionEvent>[
        const VideoAcquisitionUserTextEvent('一口气下载全部哆啦A梦剧场版'),
        const VideoAcquisitionAiIntentEvent(
          VideoAcquisitionIntent(
            VideoAcquisitionIntentKind.provide,
            VideoAcquisitionIntentPatch(
              workQueries: <String>['ドラえもん'],
              scope: VideoAcquisitionScope.franchiseMovies,
            ),
          ),
          utterance: '一口气下载全部哆啦A梦剧场版',
        ),
        VideoAcquisitionWorksLoadedEvent(
          query: 'ドラえもん',
          items: <VideoDiscoveryItem>[anchor],
        ),
        const VideoAcquisitionDetailsLoadedEvent(),
        VideoAcquisitionFranchiseLoadedEvent(
          VideoFranchise(
            name: 'ドラえもん',
            series: const <VideoDiscoveryItem>[],
            movies: <VideoDiscoveryItem>[
              for (final VideoMediaReference movie in movies)
                VideoDiscoveryItem(reference: movie),
            ],
          ),
        ),
      ]) {
        state = reduceVideoAcquisition(state, event, defaults).$1;
      }
      expect(state.stage, VideoAcquisitionStage.planningFranchise);
      return state;
    }

    test('单部下载走同一份清洗：1989 那部展示的是编号版，不是 VCB 的重制版', () {
      final VideoDiscoveryItem movie = VideoDiscoveryItem(
        reference: _nippon1989,
      );
      VideoAcquisitionState state = const VideoAcquisitionState();
      for (final VideoAcquisitionEvent event in <VideoAcquisitionEvent>[
        const VideoAcquisitionUserTextEvent('下载 のび太の日本誕生'),
        const VideoAcquisitionAiIntentEvent(
          VideoAcquisitionIntent(
            VideoAcquisitionIntentKind.provide,
            VideoAcquisitionIntentPatch(workQueries: <String>['のび太の日本誕生']),
          ),
          utterance: '下载 のび太の日本誕生',
        ),
        VideoAcquisitionWorksLoadedEvent(
          query: 'のび太の日本誕生',
          items: <VideoDiscoveryItem>[movie],
        ),
        const VideoAcquisitionDetailsLoadedEvent(),
        VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[
          _Resource(_vcb2016, seeders: 900),
          _Resource(
            '[BYG-RAWS][哆啦A梦：大雄的日本诞生][1989][1080P][国语中字]',
            seeders: 800,
          ),
          _Resource(_fabre1989),
        ]),
      ]) {
        state = reduceVideoAcquisition(state, event, defaults).$1;
      }
      expect(state.stage, VideoAcquisitionStage.awaitingResourceConfirm);
      expect(
        state.groups.map(
          (VideoResourceVersionGroup g) => g.representative.title,
        ),
        <String>[_fabre1989],
      );
    });

    test('用户那一单的四部：每部都落到自己的版本', () {
      VideoAcquisitionState state = reachFranchise(<VideoMediaReference>[
        _dinosaur1980,
        _nippon1989,
        _movie('映画ドラえもん のび太の南海大冒険', year: 1998),
        _standByMe2014,
      ]);
      // 清单按上映年排：1980 / 1989 / 1998 / 2014。
      expect(
        state.franchiseEntries.map(
          (VideoAcquisitionFranchiseEntry e) => e.item.reference.year,
        ),
        <int>[1980, 1989, 1998, 2014],
      );
      expect(wantsOriginalLanguageRelease(state), isTrue);
      final List<List<VideoResourceCandidate>> results =
          <List<VideoResourceCandidate>>[
            <VideoResourceCandidate>[
              _Resource(_byg2020, seeders: 900),
              _Resource(
                '[Fabre-RAW] Doraemon Movie 01 - Nobita no Kyouryuu (1980) '
                '[WEB-DL 1080p].mkv',
              ),
            ],
            <VideoResourceCandidate>[
              _Resource(_vcb2016, seeders: 900),
              _Resource(_fabre1989),
            ],
            <VideoResourceCandidate>[
              _Resource(_englishDub1998, seeders: 900, resolution: '1080p'),
              _Resource(
                '[Ommex] Doraemon Movie 19 - Nobita no Nankai Daibouken '
                '(1998) [1080p]',
              ),
            ],
            <VideoResourceCandidate>[
              _Resource(_standByMe2, seeders: 900),
              _Resource(
                '[VCB-Studio] STAND BY ME ドラえもん / Stand by Me Doraemon '
                '10-bit 1080p HEVC BDRip [MOVIE Fin]',
              ),
            ],
          ];
      for (int i = 0; i < results.length; i++) {
        state = reduceVideoAcquisition(
          state,
          VideoAcquisitionFranchiseEntryResolvedEvent(
            index: i,
            items: results[i],
          ),
          defaults,
        ).$1;
      }
      final List<String?> picked = <String?>[
        for (final VideoAcquisitionFranchiseEntry entry
            in state.franchiseEntries)
          entry.plan?.picks.single.title,
      ];
      expect(picked, <String?>[
        '[Fabre-RAW] Doraemon Movie 01 - Nobita no Kyouryuu (1980) '
            '[WEB-DL 1080p].mkv',
        _fabre1989,
        '[Ommex] Doraemon Movie 19 - Nobita no Nankai Daibouken (1998) '
            '[1080p]',
        '[VCB-Studio] STAND BY ME ドラえもん / Stand by Me Doraemon '
            '10-bit 1080p HEVC BDRip [MOVIE Fin]',
      ]);
    });
  });
}
