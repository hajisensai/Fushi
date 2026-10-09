// BUG-3066 补修：「原语言」的配音 / 硬字幕判定要看作品原语言。
//
// 修前 `releaseIsDubOnly` / `releaseHasBurnedInSubtitles` 只看标题，国产片 / 国漫
// （作品语言 zh）选「原语言」字幕后，标「国语 / 普通话」「中字」的发布全被当成配音 /
// 外语硬字幕丢掉 → noCandidates；粤语港片的「粤语」同理。
//
// 同文件也钉住 BUG-3065 身份判据的两处误判：标题后的「新版」/ 前面的「最新」被当成
// 重制记号；字幕组 `Title 01` 的集号被当成续作序号。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/torrent/video_release_language.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_work_match.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_reducer.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_resource_picker.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
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
  discoveryCategory: VideoDiscoveryCategory.movie,
  title: title,
  originalTitle: title,
  aliases: aliases,
  year: year,
);

VideoMetadataWork _work(VideoMediaReference reference, String language) =>
    VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.movie,
      title: reference.title,
      year: reference.year,
      originalLanguage: language,
    );

const String _mandarinChs = '[BYG-RAWS][流浪地球][2019][1080P][国语中字]';
const String _mandarinPlain = '流浪地球.The.Wandering.Earth.2019.1080p.WEB-DL.普通话';
const String _englishDub = '[G] The Wandering Earth (2019) English Dub 1080p';
const String _cantoneseTrack = '[HK] 无间道 Infernal Affairs (2002) [粤语][1080P]';
const String _mandarinOfCantonese =
    '[HK] 无间道 Infernal Affairs (2002) [国语][1080P]';

void main() {
  group('作品语言是中文：作品自己的音轨不算配音（BUG-3066）', () {
    test('国语片：国语 / 普通话 / 国语中字都不是「只有配音」', () {
      expect(releaseIsDubOnly(_mandarinChs, workLanguage: 'zh'), isFalse);
      expect(releaseIsDubOnly(_mandarinPlain, workLanguage: 'zh'), isFalse);
      expect(releaseIsDubOnly(_mandarinChs, workLanguage: 'zh-CN'), isFalse);
      expect(releaseIsDubOnly(_mandarinChs, workLanguage: 'cmn'), isFalse);
    });

    test('国语片：英配仍是配音；普通话片的粤配也是', () {
      expect(releaseIsDubOnly(_englishDub, workLanguage: 'zh'), isTrue);
      expect(releaseIsDubOnly(_cantoneseTrack, workLanguage: 'zh-CN'), isTrue);
    });

    test('粤语片：粤语是原音轨，国语是配音；只知道 zh 时两条都放行', () {
      expect(releaseIsDubOnly(_cantoneseTrack, workLanguage: 'yue'), isFalse);
      expect(releaseIsDubOnly(_cantoneseTrack, workLanguage: 'zh-HK'), isFalse);
      // TMDB 把粤语片的 original_language 标成 `cn`。
      expect(releaseIsDubOnly(_cantoneseTrack, workLanguage: 'cn'), isFalse);
      expect(
        releaseIsDubOnly(_mandarinOfCantonese, workLanguage: 'yue'),
        isTrue,
      );
      expect(
        releaseIsDubOnly(_mandarinOfCantonese, workLanguage: 'zh-HK'),
        isTrue,
      );
      // 归一化后的 `zh` 分不出国语片还是粤语片：不替用户丢资源。
      expect(releaseIsDubOnly(_cantoneseTrack, workLanguage: 'zh'), isFalse);
      expect(
        releaseIsDubOnly(_mandarinOfCantonese, workLanguage: 'zh'),
        isFalse,
      );
    });

    test('日语作品原判定不变：国语 / 粤语都是配音', () {
      expect(releaseIsDubOnly(_mandarinChs, workLanguage: 'ja'), isTrue);
      expect(releaseIsDubOnly(_cantoneseTrack, workLanguage: 'ja'), isTrue);
      expect(releaseIsDubOnly(_mandarinChs), isTrue);
    });

    test('中文作品的中字 / 内嵌简中是同语言字幕；没写语言的内嵌照旧不合格', () {
      expect(
        releaseHasBurnedInSubtitles(_mandarinChs, workLanguage: 'zh'),
        isFalse,
      );
      expect(
        releaseHasBurnedInSubtitles(
          '[G][流浪地球][2019][内嵌简中][1080P]',
          workLanguage: 'zh',
        ),
        isFalse,
      );
      expect(
        releaseHasBurnedInSubtitles(
          '[G][无间道][2002][粤语中字][1080P]',
          workLanguage: 'yue',
        ),
        isFalse,
      );
      expect(
        releaseHasBurnedInSubtitles(
          '[G] The Wandering Earth (2019) [HardSub] 1080p',
          workLanguage: 'zh',
        ),
        isTrue,
      );
      // 日语作品：中字仍是外语硬字幕。
      expect(
        releaseHasBurnedInSubtitles(_mandarinChs, workLanguage: 'ja'),
        isTrue,
      );
      expect(releaseHasBurnedInSubtitles(_mandarinChs), isTrue);
    });

    test('清洗：国产片要原语言时国语中字留下、英配丢掉', () {
      final List<VideoResourceCandidate> items = <VideoResourceCandidate>[
        _Resource(_englishDub, seeders: 900),
        _Resource(_mandarinChs, seeders: 300),
        _Resource(_mandarinPlain),
      ];
      expect(
        cleanResourceCandidates(
          items,
          skipExtras: false,
          originalLanguageOnly: true,
          workLanguage: 'zh',
        ).map((VideoResourceCandidate c) => c.title),
        <String>[_mandarinChs, _mandarinPlain],
      );
      // 判不出作品语言：仍按外语作品判（国语 / 普通话都算配音，全被清掉）。
      expect(
        cleanResourceCandidates(
          items,
          skipExtras: false,
          originalLanguageOnly: true,
        ),
        isEmpty,
      );
    });

    test('整套计划：这一部的详情说它是中文，国语中字版落地而不是 noResource', () {
      final VideoMediaReference earth = _movie('流浪地球', year: 2019);
      final VideoAcquisitionFranchiseEntry planned = planFranchiseEntry(
        VideoAcquisitionFranchiseEntry(
          item: VideoDiscoveryItem(reference: earth),
        ),
        VideoAcquisitionFranchiseEntryResolvedEvent(
          index: 0,
          work: _work(earth, 'zh'),
          items: <VideoResourceCandidate>[
            _Resource(_englishDub, seeders: 900, resolution: '1080p'),
            _Resource(_mandarinChs, seeders: 300, resolution: '1080p'),
          ],
        ),
        quality: VideoAcquisitionQuality.p1080,
        defaults: const VideoAcquisitionDefaults(),
        originalLanguageOnly: true,
      );
      expect(planned.status, VideoAcquisitionFranchiseEntryStatus.ready);
      expect(planned.plan!.picks.single.title, _mandarinChs);
    });

    test('整套计划：详情没语言时用会话的作品语言（粤语片）', () {
      final VideoMediaReference infernal = _movie('无间道', year: 2002);
      VideoAcquisitionFranchiseEntry plan(String? language) =>
          planFranchiseEntry(
            VideoAcquisitionFranchiseEntry(
              item: VideoDiscoveryItem(reference: infernal),
            ),
            VideoAcquisitionFranchiseEntryResolvedEvent(
              index: 0,
              items: <VideoResourceCandidate>[
                _Resource(_mandarinOfCantonese, seeders: 900),
                _Resource(_cantoneseTrack, seeders: 5),
              ],
            ),
            quality: VideoAcquisitionQuality.p1080,
            defaults: const VideoAcquisitionDefaults(),
            originalLanguageOnly: true,
            workLanguage: language,
          );
      expect(plan('yue').plan!.picks.single.title, _cantoneseTrack);
      // 日语作品（原行为）：两条都是配音 → 没资源。
      expect(
        plan('ja').status,
        VideoAcquisitionFranchiseEntryStatus.noResource,
      );
    });

    test('单部 reducer：国产片选「原语言」字幕，国语中字版进版本卡', () {
      const VideoAcquisitionDefaults defaults = VideoAcquisitionDefaults(
        qualityPref: '1080p',
        subtitleLanguagePref: kVideoAcquisitionSubtitleOriginal,
        sources: <VideoAcquisitionSource>[
          VideoAcquisitionSource(id: 7, label: 'Movies'),
        ],
      );
      final VideoMediaReference earth = _movie('流浪地球', year: 2019);
      VideoAcquisitionState state = const VideoAcquisitionState();
      for (final VideoAcquisitionEvent event in <VideoAcquisitionEvent>[
        const VideoAcquisitionUserTextEvent('下载 流浪地球'),
        const VideoAcquisitionAiIntentEvent(
          VideoAcquisitionIntent(
            VideoAcquisitionIntentKind.provide,
            VideoAcquisitionIntentPatch(workQueries: <String>['流浪地球']),
          ),
          utterance: '下载 流浪地球',
        ),
        VideoAcquisitionWorksLoadedEvent(
          query: '流浪地球',
          items: <VideoDiscoveryItem>[VideoDiscoveryItem(reference: earth)],
        ),
        VideoAcquisitionDetailsLoadedEvent(work: _work(earth, 'zh')),
      ]) {
        state = reduceVideoAcquisition(state, event, defaults).$1;
      }
      expect(state.contentLanguage?.code, 'zh');
      expect(wantsOriginalLanguageRelease(state), isTrue);
      state = reduceVideoAcquisition(
        state,
        VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[
          _Resource(_englishDub, seeders: 900, resolution: '1080p'),
          _Resource(_mandarinChs, seeders: 300, resolution: '1080p'),
        ]),
        defaults,
      ).$1;
      expect(state.stage, VideoAcquisitionStage.awaitingResourceConfirm);
      expect(
        state.groups.map(
          (VideoResourceVersionGroup g) => g.representative.title,
        ),
        <String>[_mandarinChs],
      );
    });
  });

  group('身份判据的误判（BUG-3065 补修）', () {
    final VideoMediaReference dinosaurZh = _movie('大雄的恐龙', year: 1980);
    final VideoMediaReference doraemonZh = _movie('哆啦A梦', year: 2019);
    final VideoMediaReference earth = _movie(
      '流浪地球',
      year: 2019,
      aliases: const <String>['The Wandering Earth'],
    );
    final VideoMediaReference earth2 = _movie(
      '流浪地球 2',
      year: 2023,
      aliases: const <String>['The Wandering Earth 2'],
    );

    VideoResourceWorkMismatch? mismatch(
      String release,
      VideoMediaReference w,
    ) => videoResourceWorkMismatch(
      release,
      VideoResourceWorkTarget.fromReference(w),
    );

    test('标题后的「新版」、前面的「最新」不是重制记号', () {
      expect(mismatch('[G][大雄的恐龙][新版][1080P]', dinosaurZh), isNull);
      expect(mismatch('【最新】哆啦A梦 [1080P]', doraemonZh), isNull);
      expect(mismatch('[G][更新]哆啦A梦[1080P]', doraemonZh), isNull);
    });

    test('前缀 / 插入的「新」仍是重制版', () {
      expect(
        mismatch('[G][新大雄的恐龙][1080P]', dinosaurZh),
        VideoResourceWorkMismatch.remake,
      );
      expect(
        mismatch('[G][大雄的新恐龙][1080P]', dinosaurZh),
        VideoResourceWorkMismatch.remake,
      );
      expect(
        mismatch('[G] 新·大雄的恐龙 [1080P]', dinosaurZh),
        VideoResourceWorkMismatch.remake,
      );
    });

    test('标题后的集号不是续作序号', () {
      expect(mismatch('[Sub] The Wandering Earth 01 [1080p]', earth), isNull);
      expect(mismatch('[Sub] The Wandering Earth - 3 [1080p]', earth), isNull);
      expect(mismatch('[Sub][The Wandering Earth][3][1080p]', earth), isNull);
      expect(mismatch('[Sub] The Wandering Earth 3v2 [1080p]', earth), isNull);
    });

    test('真续作序号照旧判成别的续作', () {
      expect(
        mismatch('[G] The Wandering Earth 2 [1080p]', earth),
        VideoResourceWorkMismatch.sequel,
      );
      expect(
        mismatch('[G] The Wandering Earth [1080p]', earth2),
        VideoResourceWorkMismatch.sequel,
      );
      expect(mismatch('[G] The Wandering Earth 2 [1080p]', earth2), isNull);
    });
  });
}
