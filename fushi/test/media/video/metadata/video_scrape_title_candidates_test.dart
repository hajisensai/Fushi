import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';

void main() {
  group('isEpisodeLabelTitle', () {
    for (final String label in <String>[
      '01',
      '02',
      '第01集',
      '第01话',
      'S01E01',
      'E05',
      // 两位纯数字文件名的常见含义就是集号；番名「86」靠目录名候选兜住
      // （见下面 videoScrapeTitleCandidates 的用例）。
      '86',
    ]) {
      test('"$label" is an episode label, not a title', () {
        expect(isEpisodeLabelTitle(label), isTrue, reason: label);
      });
    }

    for (final String title in <String>[
      '葬送的芙莉莲',
      'Sousou no Frieren',
      '1917',
      '2001',
      'Oshi no Ko S2',
      '',
    ]) {
      test('"$title" stays a searchable title', () {
        expect(isEpisodeLabelTitle(title), isFalse, reason: title);
      });
    }
  });

  group('videoScrapeTitleCandidates', () {
    test('drops file-derived episode labels but keeps directory names', () {
      final List<String> candidates = videoScrapeTitleCandidates(
        workTitle: '01',
        parsedSeries: '01',
        videoPath: r'D:\Videos\动漫\葬送的芙莉莲\01.mp4',
      );
      expect(candidates, isNot(contains('01')));
      expect(candidates.first, '葬送的芙莉莲');
      expect(candidates, contains('动漫'));
    });

    // 目录名的取法必须**平台无关**：这些路径是纯文本输入（DB 里存的 videoPath），
    // 用 package:path 的顶层函数会按跑测试的那台机器的分隔符解析 —— Windows 上
    // 全绿、CI Linux 上 dirname 给出 '.'，候选里混进一个字面量点（实发生过，
    // develop@60e3964a 的单测门）。两种分隔符都必须给出同一个目录名。
    test('directory names are taken the same way on both separator styles', () {
      for (final String path in <String>[
        r'D:\Videos\86\86 - 01.mkv',
        '/home/u/Videos/86/86 - 01.mkv',
      ]) {
        final List<String> candidates = videoScrapeTitleCandidates(
          workTitle: '86',
          parsedSeries: '86',
          videoPath: path,
        );
        expect(candidates, contains('86'), reason: path);
        expect(candidates, isNot(contains('.')), reason: path);
      }
    });

    // 上一条行为断言只在 **POSIX 平台**咬得住：package:path 的 Windows context
    // 同时接受 \\ 和 /，所以旧实现在 Windows 上两种路径都对，本机变异
    // 实测看不出差别（真红只发生在 CI Linux）。这条源码断言补上那半边 ——
    // 任何平台都咬得住：这个函数取目录名不得再走平台上下文的 path API。
    test('the candidate builder never uses platform-context path APIs', () {
      // 路径跟着代码搬：coordinator 已从 fushi/lib/src 移入引擎包。写死旧路径的
      // 后果是 PathNotFoundException（硬红，不是静默放行）——这条守卫因此还活着。
      final String source = File(
        '../packages/fushi_engine/lib/media/video/metadata/'
        'video_source_scrape_coordinator.dart',
      ).readAsStringSync();
      const String marker = 'List<String> videoScrapeTitleCandidates(';
      final int start = source.indexOf(marker);
      expect(start, isNonNegative, reason: '函数被改名了？同步更新本守卫的锚点');
      // 收尾必须从**签名之后**找起：这个函数是具名参数，签名自己就以 `}) {`
      // 收口，直接 indexOf('\\n}') 会停在参数列表那一行 —— 切出来的
      // 「函数体」只剩签名四行，函数体里的违规写法整个落在窗口之外，守卫
      // 静默放行（实际踩过：变异把 _pathSegmentFromEnd 换回 p.dirname，守卫
      // 照样绿）。
      final int open = source.indexOf(') {', start);
      expect(open, greaterThan(start));
      final int end = source.indexOf('\n}', open);
      expect(end, greaterThan(open));
      final String body = source.substring(open, end);
      // 窗口自校验：切出来的必须真是函数体。锚点再塌就当场报错，
      // 而不是变成一个恒真的空断言。
      expect(
        body,
        contains('directoryDerived'),
        reason: '切出来的窗口不含函数体标记 —— 锚点失效了，本守卫已经什么都没在守',
      );
      expect(
        RegExp(r'\bp\.(dirname|basename)\s*\(').hasMatch(body),
        isFalse,
        reason: 'p.dirname / p.basename 按**跑代码那台机器**的分隔符解析；'
            '这里的 videoPath 是 DB 里存的纯文本，可能带另一种风格的分隔符。'
            '自己切（见 _pathSegmentFromEnd），别把平台差异带进刮削候选。',
      );
    });

    test('a directory literally named after a numeric title is kept', () {
      final List<String> candidates = videoScrapeTitleCandidates(
        workTitle: '86',
        parsedSeries: '86',
        videoPath: r'D:\Videos\86\86 - 01.mkv',
      );
      // 文件派生的「86」被剔除，目录名「86」仍进候选。
      expect(candidates, contains('86'));
    });

    test('keeps the cleaned title ahead of the raw directory block', () {
      final List<String> candidates = videoScrapeTitleCandidates(
        workTitle: 'Sousou no Frieren',
        parsedSeries: 'Sousou no Frieren',
        videoPath:
            r'D:\Videos\[Sakurato] Sousou no Frieren [01-28][1080p]\[Sakurato] Sousou no Frieren [01][1080p].mp4',
      );
      expect(candidates.first, 'Sousou no Frieren');
      expect(
        candidates,
        contains('[Sakurato] Sousou no Frieren [01-28][1080p]'),
      );
      expect(candidates.toSet().length, candidates.length);
    });
  });
}
