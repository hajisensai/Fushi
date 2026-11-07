import 'package:test/test.dart';
import 'package:fushi_engine/media/audiobook/audiobook_subtitle_pick.dart';

/// 有声书字幕文件名级唯一规则：Audiobookshelf、下载包分类、本机同名扫描共用。
void main() {
  String? pick(
    List<String> audio,
    List<String> subtitles, {
    String? title,
    String langCode = 'ja',
    bool strict = false,
  }) {
    final AudiobookSubtitlePick? picked = pickAudiobookSubtitle(
      audioNames: audio,
      subtitleNames: subtitles,
      title: title,
      langCode: langCode,
      strictPerAudio: strict,
    );
    return picked == null ? null : subtitles[picked.index];
  }

  group('splitAudiobookSubtitleName', () {
    test('拆出主干与语言标记', () {
      expect(splitAudiobookSubtitleName('Book.ja.srt'), (
        stem: 'book',
        lang: 'ja',
      ));
      expect(splitAudiobookSubtitleName('Book.ja-JP.srt'), (
        stem: 'book',
        lang: 'ja-jp',
      ));
      expect(splitAudiobookSubtitleName('dir\\Sub/Book.srt'), (
        stem: 'book',
        lang: null,
      ));
    });
  });

  group('pickAudiobookSubtitle', () {
    test('日语别名与地区变体都算学习语言', () {
      for (final String tag in <String>['ja', 'jp', 'jpn', 'JA', 'ja-JP']) {
        expect(
          pick(<String>['book.mp3'], <String>['book.en.srt', 'book.$tag.srt']),
          'book.$tag.srt',
          reason: tag,
        );
      }
    });

    test('学习语言 > 无标记；别的语言不挂', () {
      expect(
        pick(<String>['book.mp3'], <String>['book.srt', 'book.jpn.vtt']),
        'book.jpn.vtt',
      );
      expect(
        pick(<String>['book.mp3'], <String>['book.en.srt', 'book.vtt']),
        'book.vtt',
      );
      expect(pick(<String>['book.mp3'], <String>['book.en.srt']), isNull);
    });

    test('langCode 为空 = 没有语言偏好，别的语言也挂', () {
      expect(
        pick(<String>['book.mp3'], <String>['book.en.srt'], langCode: ''),
        'book.en.srt',
      );
    });

    test('同一主干按格式优先级 srt > vtt > ass > ssa > lrc', () {
      expect(
        pick(
          <String>['book.mp3'],
          <String>['book.lrc', 'book.ssa', 'book.ass', 'book.vtt', 'book.srt'],
        ),
        'book.srt',
      );
      expect(
        pick(<String>['book.mp3'], <String>['book.lrc', 'book.ssa']),
        'book.ssa',
      );
    });

    test('音频整名里带点：Book.Vol.mp3 认 Book.Vol.srt 与 Book.Vol.ja.srt', () {
      expect(
        pick(<String>['Book.Vol.mp3'], <String>['Book.Vol.srt']),
        'Book.Vol.srt',
      );
      expect(
        pick(
          <String>['Book.Vol.mp3'],
          <String>['Book.Vol.srt', 'Book.Vol.ja.srt'],
        ),
        'Book.Vol.ja.srt',
      );
    });

    test('严格模式只认与音频同主干的，不退让到别的文件', () {
      expect(
        pick(
          <String>['ep02.mp3'],
          <String>['ep01.srt', 'ep03.srt'],
          strict: true,
        ),
        isNull,
      );
      expect(
        pick(<String>['ep02.mp3'], <String>['ep01.srt'], strict: true),
        isNull,
      );
      expect(
        pick(
          <String>['ep02.mp3'],
          <String>['ep01.srt', 'ep02.ja.srt'],
          strict: true,
        ),
        'ep02.ja.srt',
      );
    });

    test('整本书：同名音轨 → 标题 → 唯一主干的全部字幕', () {
      expect(
        pick(
          <String>['01.mp3', '02.mp3'],
          <String>['My Book.srt'],
          title: 'My Book',
        ),
        'My Book.srt',
      );
      expect(
        pick(
          <String>['01.mp3', '02.mp3'],
          <String>['other.srt', 'my book.srt'],
          title: 'My Book',
        ),
        'my book.srt',
      );
      expect(pick(<String>['01.mp3'], <String>['whole.srt']), 'whole.srt');
    });

    test('分属不同主干（每个音轨一份 / 互不相干）挑不准返回 null', () {
      expect(
        pick(
          <String>['part1.mp3', 'part2.mp3'],
          <String>['part1.srt', 'part2.srt'],
        ),
        isNull,
      );
      expect(pick(<String>['01.mp3'], <String>['a.srt', 'b.srt']), isNull);
    });

    test('多音轨：只和其中一条同名的分轨字幕不当整本书的时间轴', () {
      const List<String> tracks = <String>['part1.mp3', 'part2.mp3'];
      expect(pick(tracks, <String>['part1.srt']), isNull);
      expect(pick(tracks, <String>['part2.ja.srt', 'part2.srt']), isNull);
      // 分轨字幕剔掉后，标题同名的整本字幕照常挑中。
      expect(
        pick(tracks, <String>['part1.srt', 'My Book.srt'], title: 'My Book'),
        'My Book.srt',
      );
    });

    test('置信度：兜底且多音轨只算推荐，其余可直接挂', () {
      AudiobookSubtitlePick? raw(
        List<String> audio,
        List<String> subtitles, {
        String? title,
      }) => pickAudiobookSubtitle(
        audioNames: audio,
        subtitleNames: subtitles,
        title: title,
        langCode: 'ja',
      );
      final AudiobookSubtitlePick? bonus = raw(
        <String>['part1.mp3', 'part2.mp3'],
        <String>['Bonus.srt'],
      );
      expect(bonus?.basis, AudiobookSubtitleBasis.onlyStem);
      expect(bonus?.confident, isFalse);
      expect(
        raw(<String>['book.mp3'], <String>['Bonus.srt'])?.confident,
        isTrue,
      );
      expect(
        raw(<String>['book.mp3'], <String>['book.srt'])?.basis,
        AudiobookSubtitleBasis.audioName,
      );
      final AudiobookSubtitlePick? byTitle = raw(
        <String>['01.mp3', '02.mp3'],
        <String>['My Book.srt'],
        title: 'My Book',
      );
      expect(byTitle?.basis, AudiobookSubtitleBasis.title);
      expect(byTitle?.confident, isTrue);
    });

    test('不是有声书字幕格式的文件一律忽略', () {
      expect(
        pick(<String>['book.mp3'], <String>['book.txt', 'book.srt']),
        'book.srt',
      );
      expect(pick(<String>['book.mp3'], <String>['book.txt', 'notes']), isNull);
    });
  });
}
