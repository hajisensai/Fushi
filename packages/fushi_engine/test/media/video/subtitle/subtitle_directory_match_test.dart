import 'package:test/test.dart';

import 'package:fushi_engine/media/video/subtitle/subtitle_directory_match.dart';

/// 反馈 0PZAhFd1RO：记住的字幕文件夹里按集号给当前视频挑字幕。
void main() {
  const String video12 = '/videos/Title/[SubGroup] Title - 12 [1080p][x264].mkv';

  SubtitleDirectoryMatch match(
    String videoPath,
    List<String> names, {
    String langCode = 'ja',
    String? template,
  }) => matchEpisodeSubtitleInDirectory(
    videoPath: videoPath,
    fileNames: names,
    langCode: langCode,
    templateFileName: template,
  );

  test('字幕与视频不同名：按集号认领同一集', () {
    final SubtitleDirectoryMatch m = match(video12, <String>[
      '[Other] Title - 11.ass',
      '[Other] Title - 12.ass',
      '[Other] Title - 13.ass',
    ]);
    expect(m.status, SubtitleDirectoryMatchStatus.matched);
    expect(m.fileName, '[Other] Title - 12.ass');
  });

  test('非字幕文件不参与匹配', () {
    final SubtitleDirectoryMatch m = match(video12, <String>[
      '[Other] Title - 12.mkv',
      '[Other] Title - 12.txt',
    ]);
    expect(m.status, SubtitleDirectoryMatchStatus.notFound);
  });

  test('文件夹里没有这一集 → notFound', () {
    final SubtitleDirectoryMatch m = match(video12, <String>[
      '[Other] Title - 01.ass',
      '[Other] Title - 02.ass',
    ]);
    expect(m.status, SubtitleDirectoryMatchStatus.notFound);
    expect(m.fileName, isNull);
  });

  test('视频认不出集号 → noEpisodeNumber', () {
    final SubtitleDirectoryMatch m = match('/videos/Some Film.mkv', <String>[
      '[Other] Title - 12.ass',
    ]);
    expect(m.status, SubtitleDirectoryMatchStatus.noEpisodeNumber);
  });

  test('同集多语言：学习语言标记优先于其它语言', () {
    final SubtitleDirectoryMatch m = match(video12, <String>[
      '[Other] Title - 12.zh.ass',
      '[Other] Title - 12.ja.ass',
    ]);
    expect(m.status, SubtitleDirectoryMatchStatus.matched);
    expect(m.fileName, '[Other] Title - 12.ja.ass');
  });

  test('学习语言同义标记（jpn / chs&jpn）也算学习语言', () {
    expect(
      match(video12, <String>[
        '[Other] Title - 12.eng.srt',
        '[Other] Title - 12.jpn.srt',
      ]).fileName,
      '[Other] Title - 12.jpn.srt',
    );
    expect(
      match(video12, <String>[
        '[Other] Title - 12.eng.srt',
        '[Other] Title - 12.chs&jpn.srt',
      ]).fileName,
      '[Other] Title - 12.chs&jpn.srt',
    );
  });

  test('不同字幕组打平手 → ambiguous，交给用户手选', () {
    final SubtitleDirectoryMatch m = match(video12, <String>[
      '[A] Title - 12.ass',
      '[B] Title - 12.ass',
    ]);
    expect(m.status, SubtitleDirectoryMatchStatus.ambiguous);
    expect(
      m.candidates,
      unorderedEquals(<String>['[A] Title - 12.ass', '[B] Title - 12.ass']),
    );
  });

  test('有模板（上次选的那份）时按同一套命名挑出', () {
    final SubtitleDirectoryMatch m = match(
      video12,
      <String>['[A] Title - 12.ass', '[B] Title - 12.ass'],
      template: '[B] Title - 01.ass',
    );
    expect(m.status, SubtitleDirectoryMatchStatus.matched);
    expect(m.fileName, '[B] Title - 12.ass');
  });

  test('模板的语言标记优先于学习语言', () {
    final SubtitleDirectoryMatch m = match(
      video12,
      <String>['[A] Title - 12.ja.ass', '[A] Title - 12.zh.ass'],
      template: '[B] Other Name 01.zh.srt',
    );
    expect(m.fileName, '[A] Title - 12.zh.ass');
  });

  test('同一份字幕多种格式：无模板 srt 优先，有模板跟模板格式', () {
    const List<String> names = <String>[
      '[A] Title - 12.ass',
      '[A] Title - 12.srt',
    ];
    expect(match(video12, names).fileName, '[A] Title - 12.srt');
    expect(
      match(video12, names, template: '[A] Title - 01.ass').fileName,
      '[A] Title - 12.ass',
    );
  });

  test('SxxEyy：季号都已知时必须同季', () {
    final SubtitleDirectoryMatch m = match(
      '/videos/Title.S02E05.1080p.WEB-DL.mkv',
      <String>['Title.S01E05.srt', 'Title.S02E05.srt', 'Title.S02E06.srt'],
    );
    expect(m.status, SubtitleDirectoryMatchStatus.matched);
    expect(m.fileName, 'Title.S02E05.srt');
  });

  test('不补零的整季命名靠兄弟差分定号（BUG-2369 同一判据）', () {
    final SubtitleDirectoryMatch m = match(
      '/videos/[SubGroup] Show - 03 [1080p].mkv',
      <String>[
        for (int i = 1; i <= 12; i++) 'Show $i.srt',
      ],
    );
    expect(m.status, SubtitleDirectoryMatchStatus.matched);
    expect(m.fileName, 'Show 3.srt');
  });
}
