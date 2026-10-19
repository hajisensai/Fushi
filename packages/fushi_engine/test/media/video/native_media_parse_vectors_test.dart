// 文件名解析 / 字幕时序扫描 / Fribb 映射解析搬进 Rust（native/fushi_compute）后的逐条
// 一致性回归。
//
// 摘要是删除旧 Dart 实现**之前**用旧实现跑 native_parse_corpus.dart 的固定种子语料得到的
// （全字段编码后做 64 位 FNV-1a）；新实现必须完全一致。另外在真实数据上做过全量对拍
// （本机视频库 ~1700 个路径、31 个真实 SRT、Fribb 全表 7.5 MB），见提交说明。
//
// 原生库是硬依赖：找不到库这里直接失败，不 skip。
@TestOn('vm')
library;

import 'dart:convert';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/scraper/filename_parser.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_timing_check.dart';
import 'package:test/test.dart';

import 'native_parse_corpus.dart';

/// 旧实现的「今年」：摘要生成于 2026 年，原生接口把它当输入，结果与运行日期无关。
const int _corpusYear = 2026;

String _enc(FfcParsedName p) => encodeParsedFields(
  p.title,
  p.secondaryTitle,
  p.episode,
  p.season,
  p.year,
  p.titleWithTrailingYear,
  p.releaseGroup,
  p.resolution,
  p.isMovieHint,
);

String _fribb(String body) {
  try {
    return jsonEncode(<Object?>[
      for (final AnimeIdentityEntry e in animeIdentityEntriesFromJsonUtf8(
        utf8.encode(body),
      ))
        <Object?>[
          e.anidbId,
          e.malIds.toList(),
          e.anilistId,
          e.tvdbId,
          e.tmdbId,
          e.tmdbSeason,
          e.tmdbEpisodeOffset,
          e.tvdbSeason,
          e.tvdbEpisodeOffset,
          e.type?.codeUnits,
          e.tmdbIsMovieNamespace,
        ],
    ]);
  } on FfcFribbNotAList {
    return 'NOTLIST';
  } on FfcFribbInvalidJson {
    return 'INVALID';
  }
}

void main() {
  test('filename parse matches the frozen old-Dart digest', () {
    final List<String> corpus = filenameCorpus(20000);
    final List<FfcParsedName> got = MediaNameNative.instance.parseNames(
      corpus,
      extensions: kVideoExtensions,
      currentYear: _corpusYear,
    );
    expect(got, hasLength(corpus.length));
    expect(fnv1a64(got.map(_enc)), _filenameDigest);
  });

  test('trailing numeric season matches the frozen old-Dart digest', () {
    final List<String> corpus = filenameCorpus(20000);
    final List<FfcTrailingSeason?> got = MediaNameNative.instance
        .trailingSeasons(corpus);
    final List<String> encoded = <String>[
      for (int i = 0; i < corpus.length; i++)
        got[i] == null
            ? '-'
            : '${got[i]!.season}|'
                  '${jsonEncode(corpus[i].substring(got[i]!.titleStart, got[i]!.titleEnd).codeUnits)}',
    ];
    expect(fnv1a64(encoded), _trailingDigest);
  });

  test('path candidates match the frozen old-Dart digest', () {
    final List<String> corpus = pathCorpus(5000);
    final List<FfcParsedName> got = MediaNameNative.instance.candidatesForPaths(
      corpus,
      extensions: kVideoExtensions,
      currentYear: _corpusYear,
    );
    final List<List<String>> perPath = List<List<String>>.generate(
      corpus.length,
      (_) => <String>[],
    );
    for (final FfcParsedName p in got) {
      perPath[p.inputIndex].add(_enc(p));
    }
    expect(
      fnv1a64(perPath.map((List<String> c) => c.join('|'))),
      _candidatesDigest,
    );
  });

  test('subtitle timing matches the frozen old-Dart digest', () {
    final List<String> corpus = subtitleCorpus(20000);
    expect(
      fnv1a64(
        corpus.map((String s) {
          final SubtitleTimingSummary r = summarizeSubtitleTiming(s);
          return '${r.cueCount},${r.firstStartMs},${r.lastEndMs}';
        }),
      ),
      _subtitleDigest,
    );
  });

  test('Fribb entries match the frozen old-Dart digest', () {
    expect(fnv1a64(fribbCorpus(5000).map(_fribb)), _fribbDigest);
  });

  group('representative cases (old Dart outputs)', () {
    for (final (String input, String expected) in _samples) {
      test(input, () {
        final FfcParsedName got = MediaNameNative.instance
            .parseNames(
              <String>[input],
              extensions: kVideoExtensions,
              currentYear: _corpusYear,
            )
            .single;
        expect(_enc(got), expected);
        // 公共 API 走同一条链路。
        expect(
          FilenameParser.parseAll(<String>[input]).single.title,
          got.title,
        );
      });
    }
  });
}

// ↓ 由旧 Dart 实现生成（临时对拍装置，未入库；2026-10-18）。
const int _filenameDigest = -463071794031697267;
const int _trailingDigest = -6484963035296573127;
const int _candidatesDigest = 291537107996254609;
const int _subtitleDigest = 314982625092058234;
const int _fribbDigest = -2399658920168417481;

const List<(String, String)> _samples = <(String, String)>[
  (
    '[Erai-raws] Mushoku Tensei III - Isekai Ittara Honki Dasu - 12 [1080p CR WEBRip HEVC AAC][MultiSub][7F1CE626].mkv',
    '[[77,117,115,104,111,107,117,32,84,101,110,115,101,105],[73,115,101,107,97,105,32,73,116,116,97,114,97,32,72,111,110,107,105,32,68,97,115,117],12,3,null,null,[69,114,97,105,45,114,97,119,115],[49,48,56,48,112],false]',
  ),
  (
    '[Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 17 [1080p CR WEB-DL AVC AAC][MultiSub][FEA1AA5E].mkv',
    '[[82,101,32,90,101,114,111,32,107,97,114,97,32,72,97,106,105,109,101,114,117,32,73,115,101,107,97,105,32,83,101,105,107,97,116,115,117],null,17,4,null,null,[69,114,97,105,45,114,97,119,115],[49,48,56,48,112],false]',
  ),
  (
    '無職転生Ⅲ ～異世界行ったら本気だす～ (2026) - S03E13.mkv',
    '[[28961,32887,36578,29983,8546],[30064,19990,30028,34892,12387,12383,12425,26412,27671,12384,12377],13,3,2026,null,null,null,false]',
  ),
  (
    '無職転生Ⅲ ～異世界行ったら本気だす～ (2026)',
    '[[28961,32887,36578,29983],[30064,19990,30028,34892,12387,12383,12425,26412,27671,12384,12377],null,3,2026,null,null,null,false]',
  ),
  (
    'BLEACH 千年血戦篇-禍進譚- (2026) - S17E41.mkv',
    '[[66,76,69,65,67,72,32,21315,24180,34880,25126,31687,45,31117,36914,35674],null,41,17,2026,null,null,null,false]',
  ),
  (
    'Tai-Ari deshita._ Ojou-sama wa Kakutou Game nante Shinai (2026) - S01E02.mkv',
    '[[84,97,105,45,65,114,105,32,100,101,115,104,105,116,97,46,32,79,106,111,117,45,115,97,109,97,32,119,97,32,75,97,107,117,116,111,117,32,71,97,109,101,32,110,97,110,116,101,32,83,104,105,110,97,105],null,2,1,2026,null,null,null,false]',
  ),
  (
    '[SubsPlease] Tai-Ari deshita. Ojousama wa Kakutou Game nante Shinai - 12 (1080p) [AD0E2244].mkv',
    '[[84,97,105,45,65,114,105,32,100,101,115,104,105,116,97,46,32,79,106,111,117,115,97,109,97,32,119,97,32,75,97,107,117,116,111,117,32,71,97,109,101,32,110,97,110,116,101,32,83,104,105,110,97,105],null,12,null,null,null,[83,117,98,115,80,108,101,97,115,101],[49,48,56,48,112],false]',
  ),
  (
    'Bleach.2004.S17E48.1080p.CR.WEB-DL.AAC2.0.H.264-AnoZu.mkv',
    '[[66,108,101,97,99,104],null,48,17,2004,[66,108,101,97,99,104,32,50,48,48,52],null,[49,48,56,48,112],false]',
  ),
  (
    'Re_ゼロから始める異世界生活 4th season (2026)',
    '[[82,101,32,12476,12525,12363,12425,22987,12417,12427,30064,19990,30028,29983,27963],null,null,4,2026,null,null,null,false]',
  ),
  ('Season 04', '[[],null,null,4,null,null,null,null,false]'),
  (
    '[Lilith-Raws] Sousou no Frieren - 05 [Baha][WEB-DL][1080p][AVC AAC][CHT][MP4].mp4',
    '[[83,111,117,115,111,117,32,110,111,32,70,114,105,101,114,101,110],null,5,null,null,null,[76,105,108,105,116,104,45,82,97,119,115],[49,48,56,48,112],false]',
  ),
  (
    '【喵萌奶茶屋】★10月新番★[葬送的芙莉莲][05][1080p][简日双语][招募翻译].mp4',
    '[[9733,49,48,26376,26032,30058,9733],null,5,null,null,null,[21941,33804,22902,33590,23627],[49,48,56,48,112],false]',
  ),
  (
    '[桜都字幕组] 某科学的超电磁炮 第三季 04 [1080P][简繁内封].mkv',
    '[[26576,31185,23398,30340,36229,30005,30913,28846],null,4,3,null,null,[26716,37117,23383,24149,32452],[49,48,56,48,80],false]',
  ),
  (
    '[VCB-Studio] Hibike! Euphonium 2 [03][Ma10p_1080p][x265_flac].mkv',
    '[[72,105,98,105,107,101,33,32,69,117,112,104,111,110,105,117,109],null,3,2,null,null,[86,67,66,45,83,116,117,100,105,111],[49,48,56,48,112],false]',
  ),
  (
    '[组] [4th - 14] [1080p].mkv',
    '[[],null,14,4,null,null,[32452],[49,48,56,48,112],false]',
  ),
  (
    '[组] 作品 [第01-12话][合集].mkv',
    '[[20316,21697],null,null,null,null,null,[32452],null,false]',
  ),
  (
    'Mushoku.Tensei.S03E04.Title.1080p.WEB-DL.mkv',
    '[[77,117,115,104,111,107,117,32,84,101,110,115,101,105],[84,105,116,108,101],4,3,null,null,null,[49,48,56,48,112],false]',
  ),
  (
    'Frieren.2023.1080p.WEB-DL.mkv',
    '[[70,114,105,101,114,101,110],null,null,null,2023,[70,114,105,101,114,101,110,32,50,48,50,51],null,[49,48,56,48,112],false]',
  ),
  (
    'Death Race 2000.mkv',
    '[[68,101,97,116,104,32,82,97,99,101],null,null,null,2000,[68,101,97,116,104,32,82,97,99,101,32,50,48,48,48],null,null,false]',
  ),
  (
    'Blade Runner 2049.mkv',
    '[[66,108,97,100,101,32,82,117,110,110,101,114,32,50,48,52,57],null,null,null,null,null,null,null,false]',
  ),
  (
    'Ip Man 2.mkv',
    '[[73,112,32,77,97,110,32,50],null,null,null,null,null,null,null,false]',
  ),
  (
    'Mob Psycho 100 - 03.mkv',
    '[[77,111,98,32,80,115,121,99,104,111,32,49,48,48],null,3,null,null,null,null,null,false]',
  ),
  (
    '剧场版 紫罗兰永恒花园 (2020).mkv',
    '[[32043,32599,20848,27704,24658,33457,22253],null,null,null,2020,null,null,null,true]',
  ),
  (
    '映画大好きポンポさん.mkv',
    '[[26144,30011,22823,22909,12365,12509,12531,12509,12373,12435],null,null,null,null,null,null,null,false]',
  ),
  (
    'Re: Zero - 05.mkv',
    '[[82,101,58,32,90,101,114,111],null,5,null,null,null,null,null,false]',
  ),
  (
    'Overlord IV: Episode 3.mkv',
    '[[79,118,101,114,108,111,114,100],[69,112,105,115,111,100,101,32,51],null,4,null,null,null,null,false]',
  ),
  ('VID_20260701_123456.mp4', '[[],null,null,null,null,null,null,null,false]'),
  ('2026-07-01 21-03-55.mp4', '[[],null,null,null,null,null,null,null,false]'),
  ('m\u212av - 03.Mkv', '[[],null,3,null,null,null,null,null,false]'),
  (
    'Title\u0085 - 07\u0085',
    '[[84,105,116,108,101],null,7,null,null,null,null,null,false]',
  ),
  ('A\ud800B - 03', '[[65,55296,66],null,3,null,null,null,null,null,false]'),
  ('', '[[],null,null,null,null,null,null,null,false]'),
];
