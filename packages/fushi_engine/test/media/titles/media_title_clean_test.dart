import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/titles/media_title_clean.dart';
import 'package:fushi_engine/media/tracking/local_title_clean.dart';
import 'package:fushi_engine/media/video/download/video_resource_version_groups.dart';
import 'package:test/test.dart';

/// BUG：media-title-crc-suffix-not-cleaned。全媒体共用一份标题清洗：显示层
/// [cleanImportedTitle] 只去「一定不是标题」的部分，检索 / 键层原语被分卷键、
/// 追踪检索词、下载版本分组共用。
void main() {
  group('cleanImportedTitle', () {
    test('真实书名：末尾 CRC 与扩展名去掉', () {
      expect(
        cleanImportedTitle('週に一度クラスメイトを買う話 ～ふたりの時間、言い訳の五千円～ 2 [e0914585]'),
        '週に一度クラスメイトを買う話 ～ふたりの時間、言い訳の五千円～ 2',
      );
      expect(
        cleanImportedTitle(
          '週に一度クラスメイトを買う話 ～ふたりの時間、言い訳の五千円～ 1 '
          '(ヤングチャンピオン・コミックス) [31aa2836]',
        ),
        '週に一度クラスメイトを買う話 ～ふたりの時間、言い訳の五千円～ 1 '
        '(ヤングチャンピオン・コミックス)',
      );
      expect(cleanImportedTitle('志乃と恋 ２ [e11812e5]'), '志乃と恋 ２');
      expect(
        cleanImportedTitle('すわっぷ⇔すわっぷ 01 [cf55ff65].epub'),
        'すわっぷ⇔すわっぷ 01',
      );
      expect(cleanImportedTitle('志乃と恋 [3574f94a].cbz'), '志乃と恋');
    });

    test('纯数字 / 拉丁贴数字的书名原样', () {
      expect(cleanImportedTitle('86'), '86');
      expect(cleanImportedTitle('Catch22'), 'Catch22');
      expect(cleanImportedTitle('Catch-22'), 'Catch-22');
      expect(cleanImportedTitle('Dr.STONE'), 'Dr.STONE');
    });

    test('出版社 / 版本标签、特典短篇、『』、卷号都保留', () {
      expect(cleanImportedTitle('安達としまむら13 (電撃文庫)'), '安達としまむら13 (電撃文庫)');
      expect(
        cleanImportedTitle('とある魔術の禁書目録 BOOK☆WALKER限定書き下ろしショートストーリー [1a2b3c4d]'),
        'とある魔術の禁書目録 BOOK☆WALKER限定書き下ろしショートストーリー',
      );
      expect(
        cleanImportedTitle('『薬屋のひとりごと』特典SS (初回限定版) [ABCDEF12].epub'),
        '『薬屋のひとりごと』特典SS (初回限定版)',
      );
      expect(cleanImportedTitle('Title (2)'), 'Title (2)');
      expect(cleanImportedTitle('Title [2024]'), 'Title [2024]');
      expect(cleanImportedTitle('Title [上]'), 'Title [上]');
    });

    test('CRC 判据：恰好 8 位十六进制、方 / 圆括号、大小写、连续多段、只认末尾', () {
      expect(cleanImportedTitle('Title [679FB7C9]'), 'Title');
      expect(cleanImportedTitle('Title (679fb7c9)'), 'Title');
      expect(cleanImportedTitle('A [11111111] (22222222)'), 'A');
      expect(cleanImportedTitle('Title [679fb7c]'), 'Title [679fb7c]');
      expect(cleanImportedTitle('Title [679fb7c90]'), 'Title [679fb7c90]');
      expect(cleanImportedTitle('Title [679fb7cz]'), 'Title [679fb7cz]');
      expect(cleanImportedTitle('Title [679fb7c9) '), 'Title [679fb7c9)');
      expect(
        cleanImportedTitle('Title [679fb7c9] 第2巻'),
        'Title [679fb7c9] 第2巻',
      );
    });

    test('扩展名：大小写不敏感，CRC 与扩展名任意顺序叠加', () {
      expect(
        cleanImportedTitle('Show - 01 [1080p][ABCD1234].MKV'),
        'Show - 01 [1080p]',
      );
      expect(cleanImportedTitle('Album.flac'), 'Album');
      expect(cleanImportedTitle('Vol.zip [0a1b2c3d]'), 'Vol');
      expect(cleanImportedTitle('Name .epub'), 'Name .epub');
    });

    test('空白：首尾去掉、ASCII 连续空白折一个，全角空格不动', () {
      expect(cleanImportedTitle('  A   B\t[abcdef12] '), 'A B');
      expect(cleanImportedTitle('ＡＢＣ　ＤＥＦ'), 'ＡＢＣ　ＤＥＦ');
    });

    test('清空了就原样返回 raw；幂等', () {
      expect(cleanImportedTitle('[679fb7c9]'), '[679fb7c9]');
      expect(cleanImportedTitle('  [679fb7c9].epub'), '  [679fb7c9].epub');
      expect(cleanImportedTitle(''), '');
      for (final String raw in <String>[
        '志乃と恋 [3574f94a].cbz',
        '[679fb7c9]',
        '  A   B [abcdef12] ',
        '86',
      ]) {
        final String once = cleanImportedTitle(raw);
        expect(cleanImportedTitle(once), once, reason: raw);
      }
    });
  });

  test('扩展名表 ⊇ 视频 / 音频导入扩展名（新加格式不漏）', () {
    final Set<String> media = <String>{
      for (final String ext in <String>{
        ...kVideoExtensions,
        ...kAudioExtensions,
      })
        ext.substring(1),
    };
    expect(kImportedTitleFileExtensions, containsAll(media));
    expect(isCrcHex('E0914585'), isTrue);
    expect(isCrcHex('e091458'), isFalse);
  });

  group('各消费方共用同一判据', () {
    test('分卷键：方括号 / 圆括号 / 大写 CRC 得到同一个系列键', () {
      final String? square = parseBookSeriesKey('志乃と恋 3 [998c5526]')?.key;
      expect(square, isNotNull);
      expect(parseBookSeriesKey('志乃と恋 3 (998C5526)')?.key, square);
      expect(parseBookSeriesKey('志乃と恋 3 [998c5526] [11111111]')?.key, square);
      expect(parseBookSeriesKey('志乃と恋 3 [998c5526]')?.volume, 3);
    });

    test('追踪检索词：音频扩展名也剥掉、圆括号 CRC 当发布标签', () {
      expect(localTitleSearchCandidates('Ajin.mp3').first, 'Ajin');
      expect(localTitleSearchCandidates('Ajin (DEADBEEF)').first, 'Ajin');
    });

    test('下载版本分组：CRC 不算发布组名', () {
      expect(releaseGroupTagFromTitle('[ABCDEF12] Show - 01'), isNull);
      expect(releaseGroupTagFromTitle('[SubsPlease] Show - 01'), 'SubsPlease');
    });
  });
}
