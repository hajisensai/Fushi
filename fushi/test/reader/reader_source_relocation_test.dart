// 拍板 hSZjfrcejt：BUG-5049 修复（6463f4cf00）之前制的小说卡，出处存的是音频匹配坐标
// （拉丁 / 全角字母逐字母计），回看按学习单位落位就错位。按卡上句子在原章里核对 / 重定位。
import 'package:fushi/src/reader/reader_audio_position.dart';
import 'package:fushi/src/reader/reader_source_relocation.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:test/test.dart';

ReaderAudioPositionIndex _chapter(String body) =>
    ReaderAudioPositionIndex.fromChapterHtml('<html><body>$body</body></html>');

ReaderSourceRelocationRequest _req(
  int offset,
  int? length,
  List<String> texts, {
  int chapter = 0,
}) => ReaderSourceRelocationRequest(
  chapterIndex: chapter,
  offset: offset,
  length: length,
  texts: texts,
);

void main() {
  // 反馈原例：ＳＯＳ 之后的句子，旧坐标漏掉句首「もと」、末尾多划到下一句的「『ふざ」。
  const String sosChapter = '<p>ＳＯＳだ。</p><p>もとから鼻白む話だ。『ふざけるな』</p>';
  const List<String> sosCard = <String>['もとから鼻白む話だ。', '鼻白む'];

  test('old matchable coordinates after full-width Latin are converted', () {
    final ReaderAudioPositionIndex chapter = _chapter(sosChapter);
    // 匹配坐标：ｓｏｓ 3 + だ 1 = 4；学习单位：ＳＯＳ 1 + だ 1 = 2。
    expect(chapter.matchableTextForStudySpan(4, 9), 'から鼻白む話だふざ');
    expect(
      relocateReaderSourceSpan(chapter, _req(4, 9, sosCard)),
      const ReaderSourceRelocation.relocated(offset: 2, length: 9),
    );
  });

  test('study coordinates verify, so a second pass changes nothing', () {
    final ReaderAudioPositionIndex chapter = _chapter(sosChapter);
    expect(chapter.matchableTextForStudySpan(2, 9), 'もとから鼻白む話だ');
    expect(
      relocateReaderSourceSpan(chapter, _req(2, 9, sosCard)),
      const ReaderSourceRelocation.verified(),
    );
    // 选区回退（只存了词）也算对。
    expect(
      relocateReaderSourceSpan(chapter, _req(6, 3, sosCard)),
      const ReaderSourceRelocation.verified(),
    );
  });

  test('without Latin before the sentence both coordinates agree', () {
    final ReaderAudioPositionIndex chapter = _chapter('<p>猫だ。犬だ。</p>');
    expect(
      relocateReaderSourceSpan(chapter, _req(2, 2, <String>['犬だ。'])),
      const ReaderSourceRelocation.verified(),
    );
  });

  test('a repeated sentence keeps the occurrence the old offset named', () {
    final ReaderAudioPositionIndex chapter = _chapter(
      '<p>ABC猫だ。</p><p>DEF猫だ。</p>',
    );
    // 匹配坐标：abc 0-2 猫3 だ4 def 5-7 猫8 だ9；学习单位：ABC0 猫1 だ2 DEF3 猫4 だ5。
    expect(
      relocateReaderSourceSpan(chapter, _req(8, 2, <String>['猫だ。'])),
      const ReaderSourceRelocation.relocated(offset: 4, length: 2),
    );
    expect(
      relocateReaderSourceSpan(chapter, _req(3, 2, <String>['猫だ。'])),
      const ReaderSourceRelocation.relocated(offset: 1, length: 2),
    );
  });

  test('ruby readings are not part of either coordinate', () {
    final ReaderAudioPositionIndex chapter = _chapter(
      '<p>ＡＢ<ruby>鼻白<rt>はなじろ</rt></ruby>む。</p>',
    );
    expect(
      relocateReaderSourceSpan(chapter, _req(2, 3, <String>['鼻白む。'])),
      const ReaderSourceRelocation.relocated(offset: 1, length: 3),
    );
  });

  test('neither coordinate fits: search the card text, nearest wins', () {
    final ReaderAudioPositionIndex chapter = _chapter(
      '<p>猫だ。</p><p>序章。</p><p>猫だ。</p>',
    );
    // 学习单位：猫0 だ1 序2 章3 猫4 だ5。旧起点 50 离第二处更近。
    expect(
      relocateReaderSourceSpan(chapter, _req(50, null, <String>['猫だ。'])),
      const ReaderSourceRelocation.relocated(offset: 4, length: 2),
    );
    expect(
      relocateReaderSourceSpan(chapter, _req(0, 0, <String>['猫だ。'])),
      const ReaderSourceRelocation.relocated(offset: 0, length: 2),
    );
  });

  test('text that is not in the chapter keeps the stored value', () {
    final ReaderAudioPositionIndex chapter = _chapter('<p>猫だ。</p>');
    expect(
      relocateReaderSourceSpan(chapter, _req(5, 2, <String>['犬が走る。', '犬'])),
      const ReaderSourceRelocation.notLocated(),
    );
    expect(
      relocateReaderSourceSpan(chapter, _req(0, 2, <String>['', '。'])),
      const ReaderSourceRelocation.notLocated(),
    );
    expect(
      relocateReaderSourceSpan(null, _req(0, 2, <String>['猫だ'])),
      const ReaderSourceRelocation.notLocated(),
    );
  });

  test('a book batch indexes each chapter once and handles a lost one', () {
    final EpubBook book = EpubBook(
      title: 'b',
      chapters: <EpubChapter>[
        EpubChapter(
          id: 'c0',
          href: 'c0.xhtml',
          mediaType: 'application/xhtml+xml',
          html: '<html><body>$sosChapter</body></html>',
        ),
      ],
    );
    expect(
      relocateReaderSourceSpansInBook(book, <ReaderSourceRelocationRequest>[
        _req(4, 9, sosCard),
        _req(2, 9, sosCard),
        _req(4, 9, sosCard, chapter: 3),
      ]),
      const <ReaderSourceRelocation>[
        ReaderSourceRelocation.relocated(offset: 2, length: 9),
        ReaderSourceRelocation.verified(),
        ReaderSourceRelocation.notLocated(),
      ],
    );
  });
}
