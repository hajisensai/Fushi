import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/nyaa_literature_classifier.dart';

/// `classifyNyaaLiterature` 的规则表语料（设计稿
/// `docs/specs/2026-09-08-nyaa-novel-discovery-filters.md` 第 3 节）。
///
/// 正例/反例取自调研样本；每条都写明期望值背后的信号，改规则时先对着这张表。
void main() {
  const int mib = 1024 * 1024;

  group('classifyNyaaLiterature 语料表', () {
    final List<({String title, int? size, DiscoveryContentHint want})> cases =
        <({String title, int? size, DiscoveryContentHint want})>[
      // (Digital) 强漫画 + 1r0n 漫画专属组。
      (
        title: 'Sousou no Frieren v01-14 (Digital) (1r0n)',
        size: null,
        want: DiscoveryContentHint.manga,
      ),
      // Yen Press 强小说 + 尾部连续方括号。
      (
        title: 'Re:ZERO v01-29 [Yen Press] [Stick]',
        size: null,
        want: DiscoveryContentHint.novel,
      ),
      // Stick 两种都发（0 分），只能靠 (Digital)。
      (
        title: 'Kemono Jihen v01-21 (Digital) (Stick)',
        size: null,
        want: DiscoveryContentHint.manga,
      ),
      // chaptr 语料把它错标成 LN——发布组名不是信号，(2024-2025) (Digital) 才是。
      (
        title: 'Youjo Senki v24-27 (2024-2025) (Digital) (Ushi)',
        size: null,
        want: DiscoveryContentHint.manga,
      ),
      // BookWalker 只是弱小说 +1，压不过 (Digital) +3。
      (
        title: 'Gundam The Origin v01-24 (Digital) (BookWalker) (JP)',
        size: null,
        want: DiscoveryContentHint.manga,
      ),
      // 出版社 + 电子书格式。
      (
        title: '[Yen Press] Mushoku Tensei v01-26 EPUB',
        size: null,
        want: DiscoveryContentHint.novel,
      ),
      // 日文生肉：一般コミック。
      (
        title: '一般コミック [作者] 葬送のフリーレン 第01-13巻',
        size: null,
        want: DiscoveryContentHint.manga,
      ),
      // 日文生肉：ライトノベル。
      (
        title: 'ライトノベル 薬屋のひとりごと 第01-15巻',
        size: null,
        want: DiscoveryContentHint.novel,
      ),
      // 有声书单独一档，不参与判定。
      (
        title: 'Title (Audiobook) [M4B]',
        size: null,
        want: DiscoveryContentHint.audiobook,
      ),
      // 没有任何信号：保留显示。
      (
        title: 'Some Title v01',
        size: null,
        want: DiscoveryContentHint.undecided,
      ),
      // `Graphic Novel` 不算小说词，(Digital) 判漫画。
      (
        title: 'Some Title Graphic Novel (Digital)',
        size: null,
        want: DiscoveryContentHint.manga,
      ),
      // 三位数章节区间是强漫画；年份区间不是。
      (
        title: '[Group] Some Title 101-150',
        size: null,
        want: DiscoveryContentHint.manga,
      ),
      (
        title: 'Some Title (2020-2023) [Yen Press] [Stick]',
        size: null,
        want: DiscoveryContentHint.novel,
      ),
      // 容器名 / 图片格式。
      (
        title: 'Some Title v01-03 cbz',
        size: null,
        want: DiscoveryContentHint.manga,
      ),
      // HTML 实体先反转义：`&amp;` 不能把 `[Yen Press]` 切坏。
      (
        title: 'Foo &amp; Bar v01 [Yen Press] [Stick]',
        size: null,
        want: DiscoveryContentHint.novel,
      ),
      // 体积规则：5 卷 50 MiB → 每卷 10 MiB → 小说 +2。
      (
        title: 'Some Title v01-05',
        size: 50 * mib,
        want: DiscoveryContentHint.novel,
      ),
      // 体积规则：5 卷 1 GiB → 每卷 200 MiB → 漫画 +3。
      (
        title: 'Some Title v01-05',
        size: 1024 * mib,
        want: DiscoveryContentHint.manga,
      ),
      // 重叠区 30–60 MiB/卷 不给分。
      (
        title: 'Some Title v01-02',
        size: 90 * mib,
        want: DiscoveryContentHint.undecided,
      ),
      // 合集跳过体积规则。
      (
        title: 'Some Title Collection v01-05',
        size: 1024 * mib,
        want: DiscoveryContentHint.undecided,
      ),
    ];

    for (final ({String title, int? size, DiscoveryContentHint want}) c
        in cases) {
      test('${c.title}${c.size == null ? '' : ' @${c.size! ~/ mib} MiB'}', () {
        final NyaaLiteratureScore score = scoreNyaaLiterature(
          title: c.title,
          sizeBytes: c.size,
        );
        expect(
          classifyNyaaLiterature(title: c.title, sizeBytes: c.size),
          c.want,
          reason: '$score',
        );
      });
    }
  });

  test('打分门槛：差 1 分是 undecided，差 2 分才定性', () {
    // (Digital) +3 vs BookWalker +1 = 差 2 → manga（上表已覆盖）；
    // 这里造一条 PDF(+1) + BookWalker(+1) vs 年份括号(+2) → 0 差 → undecided。
    expect(
      classifyNyaaLiterature(title: 'Some Title (2021) (BookWalker) PDF'),
      DiscoveryContentHint.undecided,
    );
    final NyaaLiteratureScore score =
        scoreNyaaLiterature(title: 'Some Title (2021) (BookWalker) PDF');
    expect(score.manga, 2);
    expect(score.novel, 2);
  });

  test('分类 2_x（Audio）直接判 audiobook；3_x 不影响打分', () {
    expect(
      classifyNyaaLiterature(title: 'Some Title v01', categoryId: '2_0'),
      DiscoveryContentHint.audiobook,
    );
    expect(
      classifyNyaaLiterature(title: 'Some Title v01', categoryId: '3_1'),
      DiscoveryContentHint.undecided,
    );
    expect(
      classifyNyaaLiterature(title: 'Some Title v01', categoryId: '3_3'),
      DiscoveryContentHint.undecided,
    );
  });

  test('发布组名 LuCaZ / Stick / Ushi / Oak / nao 恒 0 分', () {
    for (final String group in <String>[
      'LuCaZ',
      'Stick',
      'Ushi',
      'Oak',
      'nao'
    ]) {
      final NyaaLiteratureScore score =
          scoreNyaaLiterature(title: 'Some Title v01 ($group)');
      expect(score.manga, 0, reason: group);
      expect(score.novel, 0, reason: group);
    }
  });

  test('同一判据只记一次：两个 (Digital) 不叠加', () {
    final NyaaLiteratureScore once =
        scoreNyaaLiterature(title: 'Some Title v01 (Digital)');
    final NyaaLiteratureScore twice =
        scoreNyaaLiterature(title: 'Some Title v01 (Digital) (Digital)');
    expect(twice.manga, once.manga);
  });
}
