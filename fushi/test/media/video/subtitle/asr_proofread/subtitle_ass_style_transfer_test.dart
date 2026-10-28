import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_ass_style_transfer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:path/path.dart' as p;

/// 一份典型的中文字幕组 ASS：对白样式 + 顶部样式 + 招牌（\pos）+ 卡拉 OK + 绘图。
String _referenceAss({int extraLines = 10}) {
  final StringBuffer b = StringBuffer()
    ..writeln('﻿[Script Info]')
    ..writeln('Title: 测试字幕组')
    ..writeln('ScriptType: v4.00+')
    ..writeln('PlayResX: 1920')
    ..writeln('PlayResY: 1080')
    ..writeln()
    ..writeln('[V4+ Styles]')
    ..writeln(
      'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
      'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, '
      'ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, '
      'MarginL, MarginR, MarginV, Encoding',
    )
    ..writeln(
      'Style: Dial,Noto Sans,70,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,'
      '0,0,0,0,100,100,0,0,1,3,0,2,10,10,40,1',
    )
    ..writeln(
      'Style: Top,Noto Sans,70,&H0000FFFF,&H000000FF,&H00000000,&H00000000,'
      '0,0,0,0,100,100,0,0,1,3,0,8,10,10,40,1',
    )
    ..writeln(
      'Style: Sign,Noto Sans,50,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,'
      '0,0,0,0,100,100,0,0,1,0,0,5,10,10,10,1',
    )
    ..writeln()
    ..writeln('[Events]')
    ..writeln(
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
      'Effect, Text',
    )
    // 0:01–0:03 普通对白
    ..writeln('Dialogue: 0,0:00:01.00,0:00:03.00,Dial,唯,0,0,0,,你好，世界')
    // 0:04–0:06 顶部、带颜色覆盖与淡入
    ..writeln(
      r'Dialogue: 1,0:00:04.00,0:00:06.00,Top,,0,0,25,,{\an8\c&H0080FF&\fad(100,200)}在上面',
    )
    // 0:04–0:06 同时段的招牌（\pos）：不该抢走对白
    ..writeln(
      r'Dialogue: 2,0:00:04.00,0:00:06.00,Sign,,0,0,0,,{\pos(300,200)\frz5}咖啡店',
    )
    // 0:07–0:09 只有招牌：退而继承它的位置
    ..writeln(
      r'Dialogue: 2,0:00:07.00,0:00:09.00,Sign,,0,0,0,,{\pos(960,100)}标题',
    )
    // 0:10–0:12 卡拉 OK + \t：这些标签不继承
    ..writeln(
      r'Dialogue: 0,0:00:10.00,0:00:12.00,Dial,,0,0,0,,{\an2\k20\t(0,500,\fscx120)}啦{\k30}啦',
    )
    // 绘图与 Comment 不算对白
    ..writeln(
      r'Dialogue: 0,0:00:13.00,0:00:15.00,Sign,,0,0,0,,{\p1}m 0 0 l 100 0 100 100',
    )
    ..writeln('Comment: 0,0:00:13.00,0:00:15.00,Dial,,0,0,0,,注释');
  for (int i = 0; i < extraLines; i++) {
    final int s = 100 + i * 3;
    b.writeln(
      'Dialogue: 0,0:01:${(s % 60).toString().padLeft(2, '0')}.00,'
      '0:01:${(s % 60 + 2).toString().padLeft(2, '0')}.00,Dial,,0,0,0,,第$i句',
    );
  }
  b
    ..writeln()
    ..writeln('[Fonts]')
    ..writeln('fontname: x.ttf');
  return b.toString();
}

/// [_referenceAss] 末尾再追加一段 `[Events]`，多一条 `Dialogue: [dialogue]`。
String _withExtraEvent(String dialogue) =>
    '${_referenceAss()}[Events]\n'
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
    'Effect, Text\n'
    'Dialogue: $dialogue\n';

List<String> _dialogues(String ass) => <String>[
  for (final String l in ass.split('\n'))
    if (l.startsWith('Dialogue:')) l.trimRight(),
];

/// 识别器替身：固定给一份稿。
class _FakeRecognizer implements VideoSubtitleRecognizer {
  _FakeRecognizer(this.drafts);

  final List<SubtitleDraftCue> drafts;

  @override
  String get id => 'fake';

  @override
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
  }) async => drafts;
}

void main() {
  group('parseAssStyleReference', () {
    test('头部段原样保留（Script Info 在首、Fonts 也留着）；绘图 / Comment 不算对白', () {
      final AssStyleReference ref = parseAssStyleReference(
        _referenceAss(),
        label: 'ep01.zh.ass',
      )!;
      expect(ref.headerSections.first, startsWith('[Script Info]'));
      expect(ref.headerSections.first, contains('PlayResY: 1080'));
      expect(
        ref.headerSections.any((String s) => s.startsWith('[V4+ Styles]')),
        isTrue,
      );
      expect(
        ref.headerSections.any((String s) => s.startsWith('[Fonts]')),
        isTrue,
      );
      expect(ref.events.any((AssReferenceEvent e) => e.isDrawing), isFalse);
      expect(
        ref.events.any((AssReferenceEvent e) => e.plainText == '注释'),
        isFalse,
      );
      expect(ref.defaultStyle, 'Dial');
    });

    test('没有样式段 / 对白太少：不当参考', () {
      expect(
        parseAssStyleReference(
          _referenceAss().replaceAll('[V4+ Styles]', '[Other]'),
          label: 'x',
        ),
        isNull,
      );
      expect(
        parseAssStyleReference(_referenceAss(extraLines: 0), label: 'x'),
        isNull,
      );
    });
  });

  group('renderAssWithReferenceStyle', () {
    final AssStyleReference ref = parseAssStyleReference(
      _referenceAss(),
      label: 'ep01.zh.ass',
    )!;

    String render(List<AssStyledCue> cues) =>
        renderAssWithReferenceStyle(cues: cues, reference: ref);

    test('按时间继承样式、位置与颜色；招牌不抢对白', () {
      final List<String> lines = _dialogues(
        render(const <AssStyledCue>[
          AssStyledCue(startMs: 1100, endMs: 2900, text: 'こんにちは'),
          AssStyledCue(startMs: 4100, endMs: 5900, text: '上だよ'),
        ]),
      );
      expect(lines[0], 'Dialogue: 0,0:00:01.10,0:00:02.90,Dial,唯,0,0,0,,こんにちは');
      expect(
        lines[1],
        r'Dialogue: 1,0:00:04.10,0:00:05.90,Top,,0,0,25,,'
        r'{\an8\c&H0080FF&\fad(100,200)}上だよ',
      );
    });

    test(r'只有招牌（\pos）与之重叠：招牌不参与挑选，用默认对白样式、不加覆盖标签', () {
      expect(
        _dialogues(
          render(const <AssStyledCue>[
            AssStyledCue(startMs: 7000, endMs: 9000, text: 'タイトル'),
          ]),
        ).single,
        'Dialogue: 0,0:00:07.00,0:00:09.00,Dial,,0,0,0,,タイトル',
      );
      expect(
        pickAssReferenceEvent(startMs: 7000, endMs: 9000, events: ref.events),
        isNull,
      );
    });

    test(r'\move / \clip / \iclip 的事件同样不参与挑选（日语行不套招牌的定位 / 旋转 / 裁剪）', () {
      for (final String sign in <String>[
        r'{\move(0,0,100,100)\frz10}移动',
        r'{\clip(0,0,500,500)}裁剪',
        r'{\iclip(0,0,500,500)\fax0.2}反裁剪',
      ]) {
        final AssStyleReference r = parseAssStyleReference(
          _withExtraEvent('3,0:00:20.00,0:00:22.00,Sign,,0,0,0,,$sign'),
          label: 'x',
        )!;
        expect(
          _dialogues(
            renderAssWithReferenceStyle(
              cues: const <AssStyledCue>[
                AssStyledCue(startMs: 20000, endMs: 22000, text: '看板'),
              ],
              reference: r,
            ),
          ).single,
          'Dialogue: 0,0:00:20.00,0:00:22.00,Dial,,0,0,0,,看板',
          reason: sign,
        );
      }
    });

    /// 一份只有一条带 [tags] 的对白（0:20–0:22）+ 填充对白的参考。
    String renderWithTags(String tags) {
      final AssStyleReference r = parseAssStyleReference(
        _withExtraEvent('0,0:00:20.00,0:00:22.00,Dial,,0,0,0,,{$tags}台词'),
        label: 'x',
      )!;
      return _dialogues(
        renderAssWithReferenceStyle(
          cues: const <AssStyledCue>[
            AssStyledCue(startMs: 20000, endMs: 22000, text: 'セリフ'),
          ],
          reference: r,
        ),
      ).single;
    }

    test(r'alpha + \t 淡入：起点 \alpha&HFF& 不继承（否则去掉 \t 后日语行整行透明）', () {
      final String line = renderWithTags(
        r'\an8\alpha&HFF&\t(0,200,\alpha&H00&)',
      );
      expect(line, 'Dialogue: 0,0:00:20.00,0:00:22.00,Dial,,0,0,0,,{\\an8}セリフ');
      expect(line, isNot(contains(r'\alpha&HFF&')));
      for (final String a in <String>[r'\1a&HFF&', r'\3a&H80&']) {
        expect(
          renderWithTags('$a\\t(0,200,${a.substring(0, 3)}&H00&)'),
          isNot(contains(a)),
        );
      }
    });

    test(r'clip + \t 擦入：\clip 起点不继承（否则日语行被裁成 0 宽）', () {
      final String line = renderWithTags(
        r'\clip(0,0,0,1080)\t(0,500,\clip(0,0,1920,1080))\c&H00FFFF&',
      );
      expect(line, isNot(contains(r'\clip')));
      // 带 \clip 的事件整条不参与挑选（排版类），日语行走默认对白样式。
      expect(line, 'Dialogue: 0,0:00:20.00,0:00:22.00,Dial,,0,0,0,,セリフ');
    });

    test(r'白名单：颜色 / 字体 / 描边 / 淡入淡出保留；旋转 / 错切 / 原点 / 缩放 / \fade 丢弃', () {
      expect(
        renderWithTags(
          r'\an7\fad(120,80)\1c&HFFFFFF&\3c&H000000&\4c&H202020&'
          r'\fnNoto Serif\fs60\b1\i1\bord2.5\shad1\blur0.6\be1'
          r'\frz12\frx3\fry4\fax0.1\fay0.2\org(10,10)\fscx120\fscy90'
          r'\fade(255,0,255,0,100,200,300)\u1\s1',
        ),
        r'Dialogue: 0,0:00:20.00,0:00:22.00,Dial,,0,0,0,,'
        r'{\an7\fad(120,80)\1c&HFFFFFF&\3c&H000000&\4c&H202020&'
        r'\fnNoto Serif\fs60\b1\i1\bord2.5\shad1\blur0.6\be1}セリフ',
      );
    });

    test(r'卡拉 OK（\k）与 \t 不继承，\an 保留', () {
      expect(
        _dialogues(
          render(const <AssStyledCue>[
            AssStyledCue(startMs: 10000, endMs: 12000, text: 'ラララ'),
          ]),
        ).single,
        r'Dialogue: 0,0:00:10.00,0:00:12.00,Dial,,0,0,0,,{\an2}ラララ',
      );
    });

    test('时间上没有参考的行用最常用的对白样式；换行与花括号转义', () {
      expect(
        _dialogues(
          render(const <AssStyledCue>[
            AssStyledCue(startMs: 30000, endMs: 31000, text: '一行目\n{二行目}'),
          ]),
        ).single,
        r'Dialogue: 0,0:00:30.00,0:00:31.00,Dial,,0,0,0,,一行目\N｛二行目｝',
      );
    });

    test('重叠不足日语行时长的 30% 不继承', () {
      expect(
        pickAssReferenceEvent(startMs: 2800, endMs: 3800, events: ref.events),
        isNull,
      );
    });

    test('播放器的 ASS 解析器读得出继承来的位置、颜色与样式', () {
      final String out = render(const <AssStyledCue>[
        AssStyledCue(startMs: 1100, endMs: 2900, text: 'こんにちは'),
        AssStyledCue(startMs: 4100, endMs: 5900, text: '上だよ'),
        AssStyledCue(startMs: 7000, endMs: 9000, text: 'タイトル'),
      ]);
      final List<AudioCue> cues = AssParser.parseString(
        content: out,
        bookKey: 'b',
      );
      expect(cues.map((AudioCue c) => c.text), <String>[
        'こんにちは',
        '上だよ',
        'タイトル',
      ]);
      final SubtitleMarkup top = cues[1].markup!;
      expect(top.anchor?.vertical, SubtitleVAlign.top);
      expect(top.spans.any((SubtitleSpan s) => s.colorArgb != null), isTrue);
      expect(top.fade?.fadeInMs, 100);
      expect(top.playResY, 1080);
      expect(
        cues[2].markup?.posFraction,
        isNull,
        reason: '只和招牌重叠的行不继承招牌的 \\pos',
      );
      expect(cues[0].markup!.cueStyle, isNotNull);
    });

    test('输出能再被当作参考解析回来（结构完整）', () {
      final String out = render(<AssStyledCue>[
        for (int i = 0; i < 12; i++)
          const AssStyledCue(startMs: 1100, endMs: 2900, text: 'こんにちは'),
      ]);
      final AssStyleReference again = parseAssStyleReference(
        out,
        label: 'out',
      )!;
      expect(again.events, hasLength(12));
      expect(again.headerSections.first, contains('PlayResX: 1920'));
    });
  });

  group('管线导出', () {
    late Directory tmp;
    late String video;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ass_style_');
      video = p.join(tmp.path, 'ep01.mkv');
      File(video).writeAsBytesSync(<int>[1, 2, 3]);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    final List<SubtitleDraftCue> drafts = <SubtitleDraftCue>[
      const SubtitleDraftCue(startMs: 1100, endMs: 2900, text: 'こんにちは'),
      const SubtitleDraftCue(startMs: 4100, endMs: 5900, text: '上だよ'),
      const SubtitleDraftCue(startMs: 30000, endMs: 31000, text: 'またね'),
    ];
    const SubtitleWorkContext work = SubtitleWorkContext(
      workKey: 'w',
      title: 't',
    );

    VideoSubtitlePipeline pipeline({
      required List<bool Function(String)> ownChecks,
      String? referenceText,
    }) => VideoSubtitlePipeline(
      recognizer: _FakeRecognizer(drafts),
      jobsRoot: Directory(p.join(tmp.path, 'jobs')),
      displaySplitter: null,
      probeDurationMs: (String _) async => 1440000,
      styleReference:
          (String path, {required bool Function(String) isOwnOutput}) async {
            ownChecks.add(isOwnOutput);
            return referenceText == null
                ? null
                : parseAssStyleReference(referenceText, label: 'ep01.zh.ass');
          },
    );

    test('有参考：SRT 照出，另出 .ja.ass；结果带样式来源', () async {
      final List<bool Function(String)> checks = <bool Function(String)>[];
      final VideoSubtitlePipelineResult r = await pipeline(
        ownChecks: checks,
        referenceText: _referenceAss(),
      ).run(videoPaths: <String>[video], work: work);
      final VideoSubtitleEpisodeResult e = r.episodes.single;
      expect(e.status, VideoSubtitleEpisodeStatus.exported);
      expect(e.outputPath, p.join(tmp.path, 'ep01.ja.srt'));
      expect(e.styledOutputPath, p.join(tmp.path, 'ep01.ja.ass'));
      expect(e.styleReference, 'ep01.zh.ass');
      expect(File(e.outputPath!).existsSync(), isTrue);
      final String ass = File(e.styledOutputPath!).readAsStringSync();
      expect(ass, contains(r'{\an8\c&H0080FF&\fad(100,200)}上だよ'));

      // 重跑：上次写的 .ja.ass / .ja.srt 被认作自己的产物，不会拿来当参考；
      // 内容没变照样覆盖写。
      final VideoSubtitlePipelineResult again = await pipeline(
        ownChecks: checks,
        referenceText: _referenceAss(),
      ).run(videoPaths: <String>[video], work: work);
      expect(
        again.episodes.single.styledOutputPath,
        p.join(tmp.path, 'ep01.ja.ass'),
      );
      expect(checks.last(p.join(tmp.path, 'ep01.ja.ass')), isTrue);
      expect(checks.last(p.join(tmp.path, 'ep01.zh.ass')), isFalse);
    });

    test('没有参考：只出 SRT', () async {
      final VideoSubtitlePipelineResult r = await pipeline(
        ownChecks: <bool Function(String)>[],
      ).run(videoPaths: <String>[video], work: work);
      expect(r.episodes.single.styledOutputPath, isNull);
      expect(File(p.join(tmp.path, 'ep01.ja.ass')).existsSync(), isFalse);
    });

    test('上次导出过 .ja.ass、这次没参考：过期的 .ja.ass 删掉并报给调用方', () async {
      final String ass = p.join(tmp.path, 'ep01.ja.ass');
      await pipeline(
        ownChecks: <bool Function(String)>[],
        referenceText: _referenceAss(),
      ).run(videoPaths: <String>[video], work: work);
      expect(File(ass).existsSync(), isTrue);

      final VideoSubtitleEpisodeResult e = (await pipeline(
        ownChecks: <bool Function(String)>[],
      ).run(videoPaths: <String>[video], work: work)).episodes.single;
      expect(e.status, VideoSubtitleEpisodeStatus.exported);
      expect(e.styledOutputPath, isNull);
      expect(e.removedOutputPaths, <String>[ass]);
      expect(File(ass).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'ep01.ja.srt')).existsSync(), isTrue);

      // 再跑一次：记录已清，不会重复报删除。
      final VideoSubtitleEpisodeResult third = (await pipeline(
        ownChecks: <bool Function(String)>[],
      ).run(videoPaths: <String>[video], work: work)).episodes.single;
      expect(third.removedOutputPaths, isEmpty);
    });

    test('上次导出的 .ja.ass 被用户改过：这次没参考也不删', () async {
      final String ass = p.join(tmp.path, 'ep01.ja.ass');
      await pipeline(
        ownChecks: <bool Function(String)>[],
        referenceText: _referenceAss(),
      ).run(videoPaths: <String>[video], work: work);
      File(ass).writeAsStringSync('edited by user');
      final VideoSubtitleEpisodeResult e = (await pipeline(
        ownChecks: <bool Function(String)>[],
      ).run(videoPaths: <String>[video], work: work)).episodes.single;
      expect(e.removedOutputPaths, isEmpty);
      expect(File(ass).readAsStringSync(), 'edited by user');
    });

    test('ASS 阶段抛异常：本集照样导出 SRT，失败原因单独报，SRT 归属照常记下', () async {
      final String srt = p.join(tmp.path, 'ep01.ja.srt');
      final String ass = p.join(tmp.path, 'ep01.ja.ass');
      // 先有一份本管线写的 .ja.ass，确认失败后它也按过期清掉（不和新 SRT 错配）。
      await pipeline(
        ownChecks: <bool Function(String)>[],
        referenceText: _referenceAss(),
      ).run(videoPaths: <String>[video], work: work);
      final VideoSubtitlePipelineResult r = await VideoSubtitlePipeline(
        recognizer: _FakeRecognizer(drafts),
        jobsRoot: Directory(p.join(tmp.path, 'jobs')),
        displaySplitter: null,
        probeDurationMs: (String _) async => 1440000,
        styleReference:
            (String path, {required bool Function(String) isOwnOutput}) =>
                throw const FileSystemException('reference unreadable'),
      ).run(videoPaths: <String>[video], work: work);
      final VideoSubtitleEpisodeResult e = r.episodes.single;
      expect(e.status, VideoSubtitleEpisodeStatus.exported);
      expect(e.outputPath, srt);
      expect(e.styledOutputPath, isNull);
      expect(e.styledError, contains('reference unreadable'));
      expect(e.removedOutputPaths, <String>[ass]);
      expect(File(ass).existsSync(), isFalse);

      // SRT 的归属记录在：再跑一次仍覆盖写 .ja.srt，而不是当成别人的改写 .ja.asr.srt。
      final VideoSubtitleEpisodeResult again = (await pipeline(
        ownChecks: <bool Function(String)>[],
      ).run(videoPaths: <String>[video], work: work)).episodes.single;
      expect(again.status, VideoSubtitleEpisodeStatus.exported);
      expect(again.outputPath, srt);
      expect(again.styledError, isNull);
    });

    test('用户自己的 .ja.ass 不覆盖：改写 .ja.asr.ass', () async {
      File(p.join(tmp.path, 'ep01.ja.ass')).writeAsStringSync('mine');
      final VideoSubtitlePipelineResult r = await pipeline(
        ownChecks: <bool Function(String)>[],
        referenceText: _referenceAss(),
      ).run(videoPaths: <String>[video], work: work);
      expect(
        r.episodes.single.styledOutputPath,
        p.join(tmp.path, 'ep01.ja.asr.ass'),
      );
      expect(File(p.join(tmp.path, 'ep01.ja.ass')).readAsStringSync(), 'mine');
    });
  });
}
