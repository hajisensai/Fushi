/// 文件名解析层（[FilenameParser]）单元测试：全部使用真实世界命名样例。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_extensions.dart';
import 'package:fushi/src/media/video/scraper/filename_parser.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';

void main() {
  group('中文字幕组命名（半角/全角括号）', () {
    test('桜都字幕组：波浪号副标题 + 括号集数 + 语言标签', () {
      final ParsedMediaName p = FilenameParser.parse(
        '[桜都字幕组] 无职转生～到了异世界就拿出真本事～ [11][1080p][简繁内封].mkv',
      );
      expect(p.releaseGroup, '桜都字幕组');
      expect(p.title, '无职转生');
      expect(p.secondaryTitle, '到了异世界就拿出真本事');
      expect(p.episode, 11);
      expect(p.season, isNull);
      expect(p.resolution, '1080p');
      expect(p.isMovieHint, isFalse);
    });

    test('幻樱字幕组：全括号命名（标题也在括号里）+ 全角括号', () {
      final ParsedMediaName p = FilenameParser.parse(
        '【幻樱字幕组】【4月新番】【夏日重现】【04】【GB_MP4】【1920X1080】.mp4',
      );
      expect(p.releaseGroup, '幻樱字幕组');
      expect(p.title, '夏日重现');
      expect(p.episode, 4);
      expect(p.resolution, '1920X1080');
    });

    test('北宇治字幕组：第三季 + WebRip 来源块', () {
      final ParsedMediaName p = FilenameParser.parse(
        '[北宇治字幕组] 摇曳露营 第三季 [08][WebRip][1080p][简繁内封].mkv',
      );
      expect(p.releaseGroup, '北宇治字幕组');
      expect(p.title, '摇曳露营');
      expect(p.season, 3);
      expect(p.episode, 8);
      expect(p.resolution, '1080p');
    });
  });

  group('SubsPlease / ANi 命名', () {
    test('SubsPlease：dash 集数 + 圆括号分辨率 + 校验码', () {
      final ParsedMediaName p = FilenameParser.parse(
        '[SubsPlease] Sousou no Frieren - 28 (1080p) [A1B2C3D4].mkv',
      );
      expect(p.releaseGroup, 'SubsPlease');
      expect(p.title, 'Sousou no Frieren');
      expect(p.episode, 28);
      expect(p.resolution, '1080p');
      expect(p.year, isNull);
    });

    test('ANi：中文标题 + Baha/WEB-DL/编码/语言多块', () {
      final ParsedMediaName p = FilenameParser.parse(
        '[ANi] 葬送的芙莉莲 - 28 [1080P][Baha][WEB-DL][AAC AVC][CHT].mp4',
      );
      expect(p.releaseGroup, 'ANi');
      expect(p.title, '葬送的芙莉莲');
      expect(p.episode, 28);
      expect(p.resolution, '1080P');
    });
  });

  group('VCB-Studio 多块命名', () {
    test('VCB-Studio：Ma10p_1080p 混合块提取分辨率', () {
      final ParsedMediaName p = FilenameParser.parse(
        '[VCB-Studio] Yuru Camp [01][Ma10p_1080p][x265_flac].mkv',
      );
      expect(p.releaseGroup, 'VCB-Studio');
      expect(p.title, 'Yuru Camp');
      expect(p.episode, 1);
      expect(p.resolution, '1080p');
    });

    test('联合发布组（含 &）+ 标题带感叹号', () {
      final ParsedMediaName p = FilenameParser.parse(
        '[Nekomoe kissaten&VCB-Studio] Bocchi the Rock! [08][Ma10p_1080p][x265_flac_aac].mkv',
      );
      expect(p.releaseGroup, 'Nekomoe kissaten&VCB-Studio');
      expect(p.title, 'Bocchi the Rock!');
      expect(p.episode, 8);
      expect(p.resolution, '1080p');
    });
  });

  group('点分隔西式命名', () {
    test('S03E04 + 尾部噪音 token 截断', () {
      final ParsedMediaName p = FilenameParser.parse(
        'Mushoku.Tensei.S03E04.1080p.WEB-DL.x265.mkv',
      );
      expect(p.title, 'Mushoku Tensei');
      expect(p.season, 3);
      expect(p.episode, 4);
      expect(p.resolution, '1080p');
    });

    test('多词标题：End 一词不被误当噪音截断', () {
      final ParsedMediaName p = FilenameParser.parse(
        'Frieren.Beyond.Journeys.End.S01E05.720p.BluRay.x264.mkv',
      );
      expect(p.title, 'Frieren Beyond Journeys End');
      expect(p.season, 1);
      expect(p.episode, 5);
      expect(p.resolution, '720p');
    });
  });

  group('第N话 / 第N季', () {
    test('第26话', () {
      final ParsedMediaName p = FilenameParser.parse('鬼灭之刃 第26话.mp4');
      expect(p.title, '鬼灭之刃');
      expect(p.episode, 26);
      expect(p.season, isNull);
    });

    test('中文数字季 + 尾部裸集数', () {
      final ParsedMediaName p = FilenameParser.parse('某科学的超电磁炮 第三季 04.mkv');
      expect(p.title, '某科学的超电磁炮');
      expect(p.season, 3);
      expect(p.episode, 4);
    });

    test('阿拉伯数字季 + 繁体第N話', () {
      final ParsedMediaName p = FilenameParser.parse('进击的巨人 第4季 第05話.mkv');
      expect(p.title, '进击的巨人');
      expect(p.season, 4);
      expect(p.episode, 5);
    });
  });

  group('罗马数字季度', () {
    test('Unicode 罗马数字直接贴在标题后（目录名场景）', () {
      final ParsedMediaName p = FilenameParser.parse('无职转生Ⅲ');
      expect(p.title, '无职转生');
      expect(p.season, 3);
    });

    test('ASCII 罗马数字独立结尾 token', () {
      final ParsedMediaName p = FilenameParser.parse('Overlord IV - 03.mkv');
      expect(p.title, 'Overlord');
      expect(p.season, 4);
      expect(p.episode, 3);
    });

    test('单字母 X 不被误认为罗马数字', () {
      final ParsedMediaName p =
          FilenameParser.parse('Hunter X Hunter - 01.mkv');
      expect(p.title, 'Hunter X Hunter');
      expect(p.season, isNull);
      expect(p.episode, 1);
    });
  });

  group('S01E04 普通命名', () {
    test('空格分隔的 SxxExx', () {
      final ParsedMediaName p = FilenameParser.parse('Spy x Family S01E04.mkv');
      expect(p.title, 'Spy x Family');
      expect(p.season, 1);
      expect(p.episode, 4);
    });

    test('独立 S2 token', () {
      final ParsedMediaName p = FilenameParser.parse(
        '[LoliHouse] Mushoku Tensei S2 - 12 [WebRip 1080p HEVC-10bit AAC].mkv',
      );
      expect(p.releaseGroup, 'LoliHouse');
      expect(p.title, 'Mushoku Tensei');
      expect(p.season, 2);
      expect(p.episode, 12);
      expect(p.resolution, '1080p');
    });
  });

  group('电影提示', () {
    test('剧场版 + 圆括号年份', () {
      final ParsedMediaName p = FilenameParser.parse('紫罗兰永恒花园 剧场版 (2019).mkv');
      expect(p.title, '紫罗兰永恒花园');
      expect(p.isMovieHint, isTrue);
      expect(p.year, 2019);
    });

    test('英文 Movie 关键词 + 标题尾数字 0 不被误当集数', () {
      final ParsedMediaName p = FilenameParser.parse(
        '[SubsPlease] Jujutsu Kaisen 0 Movie (1080p) [1B2C3D4E].mkv',
      );
      expect(p.title, 'Jujutsu Kaisen 0');
      expect(p.isMovieHint, isTrue);
      expect(p.resolution, '1080p');
      expect(p.episode, isNull);
    });

    test('dash 副标题 + 剧场版', () {
      final ParsedMediaName p = FilenameParser.parse('魔法少女小圆 - 叛逆的物语 剧场版.mkv');
      expect(p.title, '魔法少女小圆');
      expect(p.secondaryTitle, '叛逆的物语');
      expect(p.isMovieHint, isTrue);
    });
  });

  group('纯日期/设备命名返回空标题', () {
    test('VID_ 设备前缀', () {
      final ParsedMediaName p = FilenameParser.parse('VID_20260701.mp4');
      expect(p.title, isEmpty);
    });

    test('OBS 式日期时间命名', () {
      final ParsedMediaName p = FilenameParser.parse('2026-07-01 21-03-55.mkv');
      expect(p.title, isEmpty);
      expect(p.episode, isNull);
    });

    test('IMG_ 设备前缀（.mov 扩展名）', () {
      final ParsedMediaName p = FilenameParser.parse('IMG_0231.mov');
      expect(p.title, isEmpty);
    });
  });

  group('candidatesForPath：目录名优先与坏目录名跳过', () {
    test('Windows 路径：目录名（含罗马数字季度）优先，文件名只有集数', () {
      final List<ParsedMediaName> c = FilenameParser.candidatesForPath(
        r'D:\Videos\无职转生Ⅲ\[Sakurato] 04.mkv',
      );
      expect(c, hasLength(2));
      expect(c[0].title, '无职转生');
      expect(c[0].season, 3);
      // 文件名标题为空但集数保留，供上层做一致性校验。
      expect(c[1].title, isEmpty);
      expect(c[1].episode, 4);
      expect(c[1].releaseGroup, 'Sakurato');
    });

    test('目录候选在前、文件候选在后', () {
      final List<ParsedMediaName> c = FilenameParser.candidatesForPath(
        r'D:\Anime\葬送的芙莉莲\[ANi] 葬送的芙莉莲 - 28 [1080P][WEB-DL].mp4',
      );
      expect(c, hasLength(2));
      expect(c[0].title, '葬送的芙莉莲');
      expect(c[0].episode, isNull);
      expect(c[1].title, '葬送的芙莉莲');
      expect(c[1].episode, 28);
    });

    test('Downloads 目录被跳过', () {
      final List<ParsedMediaName> c = FilenameParser.candidatesForPath(
        r'C:\Users\wrds\Downloads\[ANi] 葬送的芙莉莲 - 28 [1080P].mp4',
      );
      expect(c, hasLength(1));
      expect(c[0].title, '葬送的芙莉莲');
      expect(c[0].episode, 28);
    });

    test('新建文件夹被跳过', () {
      final List<ParsedMediaName> c = FilenameParser.candidatesForPath(
        r'D:\新建文件夹\Mushoku.Tensei.S03E04.mkv',
      );
      expect(c, hasLength(1));
      expect(c[0].title, 'Mushoku Tensei');
      expect(c[0].season, 3);
    });

    test('盘符根目录被跳过', () {
      final List<ParsedMediaName> c = FilenameParser.candidatesForPath(
        r'D:\[SubsPlease] Frieren - 01 (1080p).mkv',
      );
      expect(c, hasLength(1));
      expect(c[0].title, 'Frieren');
    });

    test('单字母目录被跳过', () {
      final List<ParsedMediaName> c = FilenameParser.candidatesForPath(
        r'D:\V\鬼灭之刃 第26话.mp4',
      );
      expect(c, hasLength(1));
      expect(c[0].title, '鬼灭之刃');
    });

    test('Unix 正斜杠路径：中文目录名带第二季', () {
      final List<ParsedMediaName> c = FilenameParser.candidatesForPath(
        '/home/user/Videos/摇曳露营 第二季/[VCB-Studio] Yuru Camp [05][Ma10p_1080p][x265_flac].mkv',
      );
      expect(c, hasLength(2));
      expect(c[0].title, '摇曳露营');
      expect(c[0].season, 2);
      expect(c[1].title, 'Yuru Camp');
      expect(c[1].episode, 5);
    });

    test('纯日期目录 + 设备命名文件：无任何可用候选', () {
      final List<ParsedMediaName> c = FilenameParser.candidatesForPath(
        r'D:\2026-07-01\VID_20260701.mp4',
      );
      expect(c, isEmpty);
    });
  });

  group('杂项边界', () {
    test('括号集数带 END 尾巴', () {
      final ParsedMediaName p =
          FilenameParser.parse('[组名] 石纪元 [24 END][1080p].mkv');
      expect(p.title, '石纪元');
      expect(p.episode, 24);
    });

    test('2nd Season 序数词季度', () {
      final ParsedMediaName p = FilenameParser.parse(
        '[SubsPlease] Oshi no Ko 2nd Season - 05 (720p).mkv',
      );
      expect(p.title, 'Oshi no Ko');
      expect(p.season, 2);
      expect(p.episode, 5);
      expect(p.resolution, '720p');
    });

    test('Part 2 季度', () {
      final ParsedMediaName p =
          FilenameParser.parse('Spice and Wolf Part.2 - 01.mkv');
      expect(p.title, 'Spice and Wolf');
      expect(p.season, 2);
      expect(p.episode, 1);
    });
  });

  group('自导入端引擎并入的规则（G10 第二步）', () {
    test('无「第」的 N話/N集 简写', () {
      final ParsedMediaName ja = FilenameParser.parse('Show 12話.mkv');
      expect(ja.title, 'Show');
      expect(ja.episode, 12);
      final ParsedMediaName zh = FilenameParser.parse('某番 08集.mp4');
      expect(zh.title, '某番');
      expect(zh.episode, 8);
    });

    test('EP 与数字间可有空格（Ep 3）', () {
      final ParsedMediaName p = FilenameParser.parse('Show Ep 3.mkv');
      expect(p.title, 'Show');
      expect(p.episode, 3);
    });

    test('第N巻 卷号当集数（OVA/光盘）', () {
      expect(FilenameParser.parse('OVA 第2巻.mkv').episode, 2);
      expect(FilenameParser.parse('[组名] 某作品 [第3巻].mkv').episode, 3);
    });

    test('年份连写不受 N話 简写误伤', () {
      // `2016年12話数` 这类连写：`年` 不是分隔边界，不得把 12 当集数。
      final ParsedMediaName p = FilenameParser.parse('某番 2016年12話数解说.mkv');
      expect(p.episode, isNull);
    });
  });

  group('扩展名剥离与导入共用 kVideoExtensions（G10 第一步）', () {
    test('导入认的每个扩展名刮削端都能剥掉（.rmvb 不再留在标题里）', () {
      for (final String ext in kVideoExtensions) {
        final ParsedMediaName p = FilenameParser.parse('孤独のグルメ$ext');
        expect(p.title, '孤独のグルメ', reason: '$ext 是可导入的视频扩展名，刮削剥不掉会拉低搜索相似度');
      }
    });

    test('扩展名大小写不敏感', () {
      expect(FilenameParser.parse('タイトル.MKV').title, 'タイトル');
      expect(FilenameParser.parse('タイトル.Rmvb').title, 'タイトル');
    });
  });
}
