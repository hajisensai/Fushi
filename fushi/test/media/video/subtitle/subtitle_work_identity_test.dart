import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_catalog.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_subtitle_provider.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_content_language.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_work_identity.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

/// BUG-3068：候选作品身份核对的逐条证据。每条只让**一种**证据起作用，证明它单独
/// 就能把错作品拒掉（端到端的组合见 video_subtitle_backfill_work_identity_test）。
void main() {
  VideoMediaReference movie(
    String title,
    int year, {
    int? anilistId,
    int? tmdbId,
    String? imdbId,
    List<String> aliases = const <String>[],
  }) => VideoMediaReference(
    providerId: 'anidb',
    mediaId: '1',
    mediaKind: VideoMetadataMediaKind.movie,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: title,
    aliases: aliases,
    year: year,
    anilistId: anilistId,
    tmdbId: tmdbId,
    imdbId: imdbId,
  );

  group('parseSubtitleReleaseName', () {
    test('Netflix 发布名：标题止于片源标记，尾部语言与 [cc] 剥掉', () {
      final SubtitleReleaseName name = parseSubtitleReleaseName(
        '映画ドラえもん.新・のび太と鉄人兵団.はばたけ.天使たち.WEBRip.Netflix.ja[cc].srt',
      );
      expect(name.title, '映画どらえもん新のび太と鉄人兵団はばたけ天使たち');
      expect(name.year, isNull);
      expect(name.namesEpisode, isFalse);
    });

    test('标题后的独立年份读成年份；贴在片名上的不拆', () {
      final SubtitleReleaseName split = parseSubtitleReleaseName(
        '映画ドラえもん.のび太の宇宙小戦争.2021.WEBRip.Netflix.ja[cc].srt',
      );
      expect(split.title, '映画どらえもんのび太の宇宙小戦争');
      expect(split.year, 2021);
      final SubtitleReleaseName glued = parseSubtitleReleaseName(
        '映画ドラえもん.のび太の恐竜2006.WEBRip.srt',
      );
      expect(glued.title, '映画どらえもんのび太の恐竜2006');
      expect(glued.year, isNull);
    });

    test('场景发布名：S03E25 记为集，发布组后缀不进标题', () {
      final SubtitleReleaseName name = parseSubtitleReleaseName(
        'Pinky.And.The.Brain.S03E25.DVDRip.XviD-SAiNTS.srt',
      );
      expect(name.title, 'pinkyandthebrain');
      expect(name.namesEpisode, isTrue);
      expect(
        parseSubtitleReleaseName(
          'Your.Name.2016.1080p.BluRay.x264-SPARKS.srt',
        ).title,
        'yourname',
      );
    });

    test('纯集号 / 纯语言标记不算带标题', () {
      expect(parseSubtitleReleaseName('01.srt').hasTitle, isFalse);
      expect(parseSubtitleReleaseName('ja.srt').hasTitle, isFalse);
      expect(parseSubtitleReleaseName('[Group] 1080p.ass').hasTitle, isFalse);
    });
  });

  group('checkSubtitleWork', () {
    test('④ 发布名是目标标题的变体：来源已用 AniList 确认也拒', () {
      final _Candidate candidate = _Candidate(
        '映画ドラえもん.のび太の恐竜.WEBRip.Netflix.ja[cc].srt',
        work: SubtitleWorkClaim(titles: <String>['Doraemon'], anilistId: 2665),
      );
      final SubtitleWorkCheck check = checkSubtitleWork(
        movie('映画ドラえもん のび太の恐竜2006', 2006, anilistId: 2665),
        candidate,
      );
      expect(check.rejected, isTrue);
      expect(check.detail, contains('different work'));
    });

    test('来源确认 + 发布名是罗马字写法（非变体）→ 收', () {
      final _Candidate candidate = _Candidate(
        '[Group] Kimi no Na wa (BD 1080p).ass',
        work: SubtitleWorkClaim(titles: <String>['君の名は。'], anilistId: 21519),
      );
      expect(
        checkSubtitleWork(
          movie('君の名は。', 2016, anilistId: 21519),
          candidate,
        ).rejected,
        isFalse,
      );
    });

    group('BUG-3082 id 已确认时标题后的版本修饰不推翻 id', () {
      for (final String file in <String>[
        'Your.Name.Extended.Cut.2016.1080p.BluRay.x264-GROUP.srt',
        'Your.Name.Directors.Cut.1080p.WEBRip.en.srt',
      ]) {
        test('TMDB 确认 + $file → 收', () {
          final SubtitleWorkCheck check = checkSubtitleWork(
            movie(
              '君の名は。',
              2016,
              tmdbId: 372058,
              aliases: <String>['Your Name.', 'Kimi no Na wa.'],
            ),
            _Candidate(
              file,
              work: SubtitleWorkClaim(
                titles: <String>['Your Name.'],
                kind: VideoMetadataMediaKind.movie,
                tmdbId: 372058,
              ),
            ),
          );
          expect(check.rejected, isFalse, reason: check.detail);
        });
      }

      test('IMDb 确认 + 版本修饰 → 收', () {
        expect(
          checkSubtitleWork(
            movie(
              '君の名は。',
              2016,
              imdbId: 'tt5311514',
              aliases: <String>['Your Name.'],
            ),
            _Candidate(
              'Your.Name.Extended.Cut.srt',
              work: SubtitleWorkClaim(imdbId: '5311514'),
            ),
          ).rejected,
          isFalse,
        );
      });

      test('id 确认但目标标题比发布名多出一截（发布名指的是原作）→ 仍拒', () {
        final SubtitleWorkCheck check = checkSubtitleWork(
          movie('映画ドラえもん のび太の恐竜2006', 2006, tmdbId: 9001),
          _Candidate(
            '映画ドラえもん.のび太の恐竜.WEBRip.Netflix.ja[cc].srt',
            work: SubtitleWorkClaim(
              kind: VideoMetadataMediaKind.movie,
              tmdbId: 9001,
            ),
          ),
        );
        expect(check.rejected, isTrue);
        expect(check.detail, contains('different work'));
      });

      test('只有来源条目名相等（无 id）时版本修饰仍按变体拒', () {
        expect(
          checkSubtitleWork(
            movie('Your Name.', 2016),
            _Candidate(
              'Your.Name.Extended.Cut.srt',
              work: SubtitleWorkClaim(titles: <String>['Your Name.']),
            ),
          ).rejected,
          isTrue,
          reason: '条目名相等是弱确认，重制版 / 续作的发布名同样包含原标题',
        );
      });
    });

    test('BUG-3084 AniDB 主源电影无 tmdb/imdb：别名里的英文官方名对上发布名即收', () {
      // AniDB 的 `_selectTitles` 把主标题之外的全部语言标题（en official、x-jat
      // main、synonym）放进 aliases，scrapedMediaReference 原样带到这里。
      expect(
        checkSubtitleWork(
          movie(
            '君の名は。',
            2016,
            aliases: <String>['Kimi no Na wa.', 'Your Name.'],
          ),
          _Candidate('Your.Name.2016.1080p.BluRay.x264-SPARKS.srt'),
        ).rejected,
        isFalse,
      );
    });

    test('⑤ 发布名写着 SxxEyy、来源什么都没说 → 电影目标拒', () {
      expect(
        checkSubtitleWork(
          movie('映画ドラえもん のび太の宇宙漂流記', 1999),
          _Candidate('Pinky.And.The.Brain.S03E25.DVDRip.XviD-SAiNTS.srt'),
        ).detail,
        contains('TV episode'),
      );
    });

    test('⑥ OpenSubtitles 剧集特征：只看 id 也拒（父级 IMDb 不等）', () {
      final SubtitleWorkClaim? claim =
          parseOpenSubtitlesFeatureWork(<Object?, Object?>{
            'feature_type': 'Episode',
            'parent_title': 'Pinky and the Brain',
            'parent_imdb_id': 112123,
            'parent_tmdb_id': 2489,
          });
      expect(claim!.kind, VideoMetadataMediaKind.tv);
      expect(claim.imdbId, 'tt112123');
      // 种类抹掉，只剩 id：id 单独也足以拒。
      final SubtitleWorkCheck check = checkSubtitleWork(
        movie('映画ドラえもん のび太の宇宙漂流記', 1999, imdbId: 'tt0221735'),
        _Candidate(
          'Doraemon.srt',
          work: SubtitleWorkClaim(titles: claim.titles, imdbId: claim.imdbId),
        ),
      );
      expect(check.detail, contains('ids differ'));
    });

    test('② 来源年份与目标差一年以上 → 拒；差一年以内不拒', () {
      final VideoMediaReference target = movie('映画ドラえもん のび太の宇宙小戦争', 1985);
      expect(
        checkSubtitleWork(
          target,
          _Candidate('ja.srt', work: SubtitleWorkClaim(year: 2022)),
        ).detail,
        contains('2022'),
      );
      expect(
        checkSubtitleWork(
          target,
          _Candidate('ja.srt', work: SubtitleWorkClaim(year: 1986)),
        ).rejected,
        isFalse,
      );
    });

    test('发布名不带标题时看来源条目名：不等即拒，等即收', () {
      final VideoMediaReference target = movie('映画ドラえもん のび太と鉄人兵団', 1986);
      expect(
        checkSubtitleWork(
          target,
          _Candidate(
            '01.srt',
            work: jimakuEntryWorkClaim(
              const JimakuEntry(
                id: 1,
                name: 'Doraemon: Shin Nobita to Tetsujin Heidan',
                japaneseName: '映画ドラえもん 新・のび太と鉄人兵団 ～はばたけ 天使たち～',
              ),
            ),
          ),
        ).rejected,
        isTrue,
      );
      expect(
        checkSubtitleWork(
          target,
          _Candidate(
            '01.srt',
            work: jimakuEntryWorkClaim(
              const JimakuEntry(
                id: 2,
                name: 'Doraemon: Nobita to Tetsujin Heidan',
                japaneseName: 'ドラえもん のび太と鉄人兵団',
              ),
            ),
          ),
        ).rejected,
        isFalse,
        reason: '「映画」前缀两侧对称剥离',
      );
    });

    test('对照：雲の王国同名 Netflix 文件、来源无身份 → 收', () {
      expect(
        checkSubtitleWork(
          movie('映画ドラえもん のび太と雲の王国', 1992),
          _Candidate('映画ドラえもん.のび太と雲の王国.WEBRip.Netflix.ja[cc].srt'),
        ).rejected,
        isFalse,
      );
    });

    test('剧集目标不做标题 / 年份 / AniList 判断（季间 AniList 本就不同）', () {
      final VideoMediaReference show = VideoMediaReference(
        providerId: 'tmdb',
        mediaId: '1',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: '葬送のフリーレン',
        year: 2023,
        anilistId: 154587,
        episode: 3,
      );
      expect(
        checkSubtitleWork(
          show,
          _Candidate(
            '[SubsPlease] Sousou no Frieren S2 - 03 (1080p).srt',
            work: SubtitleWorkClaim(
              titles: <String>['Sousou no Frieren 2nd Season'],
              year: 2026,
              anilistId: 182255,
            ),
          ),
        ).rejected,
        isFalse,
      );
      expect(
        checkSubtitleWork(
          show,
          _Candidate(
            'Frieren.Movie.srt',
            work: ajattEntryWorkClaim(
              const AjattCatalogEntry(
                type: AjattEntryType.animeMovie,
                pagePath: 'anime_movie/x.html',
                name: 'Frieren Movie',
                englishName: '',
                japaneseName: '',
                lastModifiedMs: 0,
              ),
            ),
          ),
        ).rejected,
        isTrue,
        reason: '剧集目标遇到来源标明的电影：种类矛盾照拒',
      );
    });
  });

  group('subtitleContentContradictsLanguage', () {
    test('中日正文是硬证据；拉丁字母只否定中日韩；认不出不否定', () {
      expect(
        subtitleContentContradictsLanguage(
          SubtitleContentLanguage.simplifiedChinese,
          'ja',
        ),
        isTrue,
      );
      expect(
        subtitleContentContradictsLanguage(
          SubtitleContentLanguage.bilingualJaZh,
          'ja',
        ),
        isFalse,
      );
      expect(
        subtitleContentContradictsLanguage(
          SubtitleContentLanguage.english,
          'ja',
        ),
        isTrue,
      );
      expect(
        subtitleContentContradictsLanguage(
          SubtitleContentLanguage.english,
          'fr',
        ),
        isFalse,
        reason: '法语也是拉丁字母，检测器分不出',
      );
      expect(
        subtitleContentContradictsLanguage(
          SubtitleContentLanguage.unknown,
          'ja',
        ),
        isFalse,
      );
    });
  });
}

class _Candidate extends VideoSubtitleCandidate {
  _Candidate(String fileName, {super.work})
    : super(
        providerId: 'test',
        remoteId: fileName,
        fileName: fileName,
        language: 'ja',
        providerPriority: 0,
      );
}
