import 'dart:io';

import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_models.dart';
import 'package:test/test.dart';

List<BookArtCandidate> _fixtureCandidates(String name) => parseMangaBakaSearch(
  File('test/fixtures/mangabaka/$name').readAsStringSync(),
).items.map(mangaBakaCandidate).toList();

Set<num> _range(int from, int to) => <num>{for (int i = from; i <= to; i++) i};

List<num> _list(int from, int to) => _range(from, to).toList();

BookArtCandidate _c(
  String id,
  String title,
  BookArtCandidateKind kind, {
  List<String> authors = const <String>[],
  num? finalVolume,
}) => BookArtCandidate(
  source: 'mangabaka',
  id: id,
  displayTitle: title,
  titles: <String>[title],
  kind: kind,
  authors: authors,
  finalVolume: finalVolume,
);

void main() {
  group('严格 / 宽松归一化', () {
    test('保留 + ≡ △ ×，去掉分隔标点、空白与全角', () {
      expect(strictBookTitleKey('citrus+'), 'citrus+');
      expect(strictBookTitleKey('呪術廻戦≡'), '呪術廻戦≡');
      expect(strictBookTitleKey('ゆるキャン△'), 'ゆるキャン△');
      expect(strictBookTitleKey('ＳＰＹ×ＦＡＭＩＬＹ'), 'spy×family');
      expect(strictBookTitleKey('ソードアート・オンライン'), 'ソードアートオンライン');
      expect(strictBookTitleKey('86―エイティシックス―'), '86エイティシックス');
      expect(strictBookTitleKey('A 〜 B'), 'ab');
      expect(looseBookTitleKey('citrus+'), 'citrus');
      expect(looseBookTitleKey('呪術廻戦≡'), '呪術廻戦');
    });
  });

  group('标题档位', () {
    test('前缀 + 副标题', () {
      expect(
        compareBookTitles('キノの旅', 'キノの旅-the Beautiful World-'),
        BookArtTitleTier.prefixSubtitle,
      );
      expect(
        compareBookTitles('キノの旅-the Beautiful World-', 'キノの旅'),
        BookArtTitleTier.localExtends,
      );
    });

    test('citrus 与 citrus+ 只到宽松档', () {
      expect(compareBookTitles('citrus', 'citrus+'), BookArtTitleTier.loose);
      expect(compareBookTitles('citrus', 'citrus'), BookArtTitleTier.strict);
    });

    test('全角 / 半角混写的 SPY×FAMILY 严格相等', () {
      expect(
        compareBookTitles('ＳＰＹ×ＦＡＭＩＬＹ', 'SPY×FAMILY'),
        BookArtTitleTier.strict,
      );
    });

    test('衍生作品与外传判拒', () {
      expect(
        compareBookTitles('とある魔術の禁書目録', '創約 とある魔術の禁書目録'),
        BookArtTitleTier.none,
      );
      expect(
        compareBookTitles('ソードアート・オンライン', 'ソードアート・オンライン プログレッシブ'),
        BookArtTitleTier.none,
      );
      expect(compareBookTitles('安達としまむら', '安達としまむらSS'), BookArtTitleTier.none);
      expect(compareBookTitles('呪術廻戦', '呪術廻戦 番外編'), BookArtTitleTier.none);
      expect(
        compareBookTitles('citrus', 'citrus コミックアンソロジー'),
        BookArtTitleTier.none,
      );
    });

    test('前缀里含代理对（补充平面字符）时分隔符与副标题仍按边界切', () {
      expect(
        compareBookTitles('𠮷野家の𩸽', '𠮷野家の𩸽 -the Beautiful World-'),
        BookArtTitleTier.prefixSubtitle,
      );
      expect(
        compareBookTitles('𠮷野家の𩸽 -the Beautiful World-', '𠮷野家の𩸽'),
        BookArtTitleTier.localExtends,
      );
      expect(compareBookTitles('𠮷野家の𩸽', '𠮷野家の𩸽𩸽'), BookArtTitleTier.none);
    });

    test('拉丁衍生词按整词比：副标题里的 class 不算 ss', () {
      expect(
        compareBookTitles('Assassination', 'Assassination - the classroom'),
        BookArtTitleTier.prefixSubtitle,
      );
    });

    // 只有日文原名的候选（Bangumi）对双语书名原来是 none、连候选都进不了。
    test('双语书名任一段对得上：最多 localExtends（待确认），不抬成自动采用', () {
      expect(
        localBookTitleTier('Horimiya ホリミヤ', <String>['ホリミヤ']),
        BookArtTitleTier.localExtends,
      );
      expect(
        localBookTitleTier('Horimiya ホリミヤ', <String>['Horimiya']),
        BookArtTitleTier.localExtends,
      );
      expect(
        localBookTitleTier('Horimiya ホリミヤ', <String>['ホリミヤ番外編']),
        BookArtTitleTier.none,
      );
      expect(
        localBookTitleTier('Horimiya ホリミヤ', <String>['堀さんと宮村くん']),
        BookArtTitleTier.none,
      );
      // 整名本来就对得上的不受影响。
      expect(
        localBookTitleTier('ホリミヤ', <String>['ホリミヤ']),
        BookArtTitleTier.strict,
      );
    });
  });

  group('作者证据', () {
    test('罗马字作者与日文作者无法比较 → unknown', () {
      expect(
        compareBookAuthors('芥見下々', <String>['Gege Akutami']),
        BookArtAuthorEvidence.unknown,
      );
    });

    test('拉丁名按词集合比，顺序无关', () {
      expect(
        compareBookAuthors('Akutami Gege', <String>['Gege Akutami']),
        BookArtAuthorEvidence.match,
      );
      expect(
        compareBookAuthors('Someone Else', <String>['Gege Akutami']),
        BookArtAuthorEvidence.mismatch,
      );
    });

    test('CJK 名去空白比（Bangumi infobox 是日文）', () {
      expect(
        compareBookAuthors('仲谷 鳰', <String>['仲谷鳰']),
        BookArtAuthorEvidence.match,
      );
      expect(
        compareBookAuthors('谷川流', <String>['仲谷鳰']),
        BookArtAuthorEvidence.mismatch,
      );
    });
  });

  group('decideBookArtMatch（候选取自真实搜索响应）', () {
    test('呪術廻戦 本地 1–30：第一条 ≡ 只有 3 卷，选第二条 6199', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: BookArtLocalSeries(
          seriesTitle: '呪術廻戦',
          kind: BookArtLocalKind.manga,
          volumes: _list(1, 30),
          author: '芥見下々',
        ),
        candidates: _fixtureCandidates('mb_search_jujutsu.json'),
        volumeIndexes: <String, Set<num>>{
          '410304': _range(1, 3),
          '6199': _range(0, 30),
          '30480': <num>{1},
        },
      );
      expect(r.decision, BookArtDecision.accepted);
      expect(r.best!.candidate.id, '6199');
    });

    test('citrus 本地 1–10：选 citrus（8940），但成人向只到待确认', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: BookArtLocalSeries(
          seriesTitle: 'citrus',
          kind: BookArtLocalKind.manga,
          volumes: _list(1, 10),
        ),
        candidates: _fixtureCandidates('mb_search_citrus.json'),
        volumeIndexes: <String, Set<num>>{
          '7457': _range(1, 7),
          '8940': _range(1, 10),
        },
      );
      expect(r.best!.candidate.id, '8940');
      expect(r.decision, BookArtDecision.needsConfirm);
    });

    test('本地只有 citrus 1–3、候选里只有 citrus+：待确认，不自动采用', () {
      final List<BookArtCandidate> onlyPlus = _fixtureCandidates(
        'mb_search_citrus.json',
      ).where((BookArtCandidate c) => c.id == '7457').toList();
      final BookArtMatchResult r = decideBookArtMatch(
        local: BookArtLocalSeries(
          seriesTitle: 'citrus',
          kind: BookArtLocalKind.manga,
          volumes: _list(1, 3),
        ),
        candidates: onlyPlus,
        volumeIndexes: <String, Set<num>>{'7457': _range(1, 7)},
      );
      expect(r.decision, BookArtDecision.needsConfirm);
      expect(r.best!.candidate.id, '7457');
    });

    test('ハルヒ 文字 EPUB：小说 85371 自动采用，同名漫画 81540 不抢', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: BookArtLocalSeries(
          seriesTitle: '涼宮ハルヒ',
          kind: BookArtLocalKind.text,
          volumes: _list(1, 3),
        ),
        candidates: <BookArtCandidate>[
          _c('85371', '涼宮ハルヒ', BookArtCandidateKind.novel),
          _c('81540', '涼宮ハルヒ', BookArtCandidateKind.manga),
        ],
        volumeIndexes: <String, Set<num>>{
          '85371': _range(1, 11),
          '81540': _range(1, 20),
        },
      );
      expect(r.decision, BookArtDecision.accepted);
      expect(r.best!.candidate.id, '85371');
    });

    test('狼と香辛料：漫画排第一，文字书选第二条小说 84752', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: BookArtLocalSeries(
          seriesTitle: '狼と香辛料',
          kind: BookArtLocalKind.text,
          volumes: _list(1, 5),
        ),
        candidates: <BookArtCandidate>[
          _c('10803', '狼と香辛料', BookArtCandidateKind.manga),
          _c('84752', '狼と香辛料', BookArtCandidateKind.novel),
        ],
        volumeIndexes: <String, Set<num>>{
          '10803': _range(1, 16),
          '84752': _range(1, 24),
        },
      );
      expect(r.best!.candidate.id, '84752');
      expect(r.decision, BookArtDecision.accepted);
    });

    test('漫画 EPUB（format=epub）只有漫画候选：不硬过滤，进待确认', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: BookArtLocalSeries(
          seriesTitle: 'ONE PIECE',
          kind: BookArtLocalKind.text,
          volumes: _list(1, 5),
        ),
        candidates: <BookArtCandidate>[
          _c('377', 'ONE PIECE', BookArtCandidateKind.manga),
        ],
        volumeIndexes: <String, Set<num>>{'377': _range(1, 115)},
      );
      expect(r.decision, BookArtDecision.needsConfirm);
      expect(r.best!.candidate.id, '377');
    });

    test('format=manga 配到小说系列：判拒', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: BookArtLocalSeries(
          seriesTitle: '狼と香辛料',
          kind: BookArtLocalKind.manga,
          volumes: _list(1, 3),
        ),
        candidates: <BookArtCandidate>[
          _c('84752', '狼と香辛料', BookArtCandidateKind.novel),
        ],
        volumeIndexes: <String, Set<num>>{'84752': _range(1, 24)},
      );
      expect(r.decision, BookArtDecision.rejected);
    });

    test('ONE PIECE 115 卷全覆盖；小数卷 28.5 能覆盖', () {
      expect(bookArtCoverage(_list(1, 115), _range(1, 115)), 1.0);
      expect(bookArtCoverage(<num>[28, 28.5, 29], <num>{28, 28.5, 29}), 1.0);
      expect(bookArtCoverage(<num>[28.5], <num>{28}), 0.0);
    });

    test('作者能比较且对不上：判拒', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: BookArtLocalSeries(
          seriesTitle: 'Bloom Into You',
          kind: BookArtLocalKind.manga,
          volumes: _list(1, 3),
          author: 'Someone Else',
        ),
        candidates: <BookArtCandidate>[
          _c(
            '21567',
            'Bloom Into You',
            BookArtCandidateKind.manga,
            authors: <String>['Nio Nakatani'],
          ),
        ],
        volumeIndexes: <String, Set<num>>{'21567': _range(1, 8)},
      );
      expect(r.decision, BookArtDecision.rejected);
    });

    test('单卷、作者无法比较：只到待确认', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: const BookArtLocalSeries(
          seriesTitle: 'やがて君になる',
          kind: BookArtLocalKind.manga,
          volumes: <num>[3],
          author: '仲谷鳰',
        ),
        candidates: <BookArtCandidate>[
          _c(
            '21567',
            'やがて君になる',
            BookArtCandidateKind.manga,
            authors: <String>['Nio Nakatani'],
          ),
        ],
        volumeIndexes: <String, Set<num>>{'21567': _range(1, 8)},
      );
      expect(r.decision, BookArtDecision.needsConfirm);
    });

    test('单本无卷号：作者对得上且候选只有 1 卷才自动采用，否则不配', () {
      const BookArtLocalSeries single = BookArtLocalSeries(
        seriesTitle: '画集',
        kind: BookArtLocalKind.manga,
        volumes: <num>[1],
        author: '仲谷鳰',
        singleUnnumbered: true,
      );
      final BookArtMatchResult ok = decideBookArtMatch(
        local: single,
        candidates: <BookArtCandidate>[
          _c(
            '1',
            '画集',
            BookArtCandidateKind.manga,
            authors: <String>['仲谷鳰'],
            finalVolume: 1,
          ),
        ],
        volumeIndexes: <String, Set<num>>{
          '1': <num>{1},
        },
      );
      expect(ok.decision, BookArtDecision.accepted);
      final BookArtMatchResult multi = decideBookArtMatch(
        local: single,
        candidates: <BookArtCandidate>[
          _c(
            '2',
            '画集',
            BookArtCandidateKind.manga,
            authors: <String>['仲谷鳰'],
            finalVolume: 8,
          ),
        ],
        volumeIndexes: <String, Set<num>>{'2': _range(1, 8)},
      );
      expect(multi.decision, BookArtDecision.rejected);
    });

    test('自动结论与追踪 auto 链接不一致：降为待确认', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: BookArtLocalSeries(
          seriesTitle: '呪術廻戦',
          kind: BookArtLocalKind.manga,
          volumes: _list(1, 30),
        ),
        candidates: _fixtureCandidates('mb_search_jujutsu.json'),
        volumeIndexes: <String, Set<num>>{'6199': _range(1, 30)},
        linkedId: '410304',
      );
      expect(r.decision, BookArtDecision.needsConfirm);
      expect(r.best!.candidate.id, '6199');
    });
  });

  group('resolveLocalVolumes', () {
    test('单本无卷号 → 第 1 卷且标记 singleUnnumbered', () {
      final r = resolveLocalVolumes(<String, num?>{'a': null});
      expect(r.volumes, <String, num>{'a': 1});
      expect(r.singleUnnumbered, isTrue);
    });

    test('多卷里唯一无卷号、没有第 1 卷 → 第 1 卷', () {
      final r = resolveLocalVolumes(<String, num?>{'a': null, 'b': 2, 'c': 3});
      expect(r.volumes, <String, num>{'a': 1, 'b': 2, 'c': 3});
      expect(r.singleUnnumbered, isFalse);
    });

    test('已有第 1 卷 / 多本无卷号：无卷号的不配（不按序号兜底）', () {
      expect(
        resolveLocalVolumes(<String, num?>{'a': null, 'b': 1}).volumes,
        <String, num>{'b': 1},
      );
      expect(
        resolveLocalVolumes(<String, num?>{
          'a': null,
          'b': null,
          'c': 3,
        }).volumes,
        <String, num>{'c': 3},
      );
    });
  });

  group('decideBookArtMatch 的防误配', () {
    const BookArtLocalSeries local = BookArtLocalSeries(
      seriesTitle: 'ルキナ',
      kind: BookArtLocalKind.manga,
      volumes: <num>[1, 2],
    );

    test('有严格同名的主系列（没有日文卷封面）时，前缀 + 副标题的衍生作只能待确认', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: local,
        candidates: <BookArtCandidate>[
          _c('1', 'ルキナ', BookArtCandidateKind.manga),
          _c('2', 'ルキナ 星の章', BookArtCandidateKind.manga),
        ],
        volumeIndexes: <String, Set<num>>{
          '1': <num>{},
          '2': <num>{1, 2},
        },
      );
      expect(r.decision, BookArtDecision.needsConfirm);
      expect(r.best!.candidate.id, '2');
      // Bangumi 补卷看的也是这个标志：同名衍生作不能借补卷混进来。
      expect(r.best!.titleAutoOk, isFalse);
    });

    test('没有严格同名候选时，前缀 + 副标题照常可自动采用', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: local,
        candidates: <BookArtCandidate>[
          _c('2', 'ルキナ 星の章', BookArtCandidateKind.manga),
        ],
        volumeIndexes: <String, Set<num>>{
          '2': <num>{1, 2},
        },
      );
      expect(r.decision, BookArtDecision.accepted);
      expect(r.best!.titleAutoOk, isTrue);
    });

    test('作者无法比较时「至少 2 卷」按不同卷号计：同卷两个版本不算', () {
      final BookArtMatchResult r = decideBookArtMatch(
        local: const BookArtLocalSeries(
          seriesTitle: 'ルキナ',
          kind: BookArtLocalKind.manga,
          volumes: <num>[1, 1],
          author: '山田太郎',
        ),
        candidates: <BookArtCandidate>[
          _c(
            '1',
            'ルキナ',
            BookArtCandidateKind.manga,
            authors: <String>['Taro Yamada'],
          ),
        ],
        volumeIndexes: <String, Set<num>>{
          '1': <num>{1},
        },
      );
      expect(r.decision, BookArtDecision.needsConfirm);
    });
  });
}
