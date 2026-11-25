import 'package:test/test.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_ass_style_transfer.dart';

/// 字幕组 ASS 的缩影：对白样式 + 乐队歌词样式（红色副色）+ 罗马音卡拉 OK 特效。
///
/// 13:20.97–13:26.11 一段歌：英文译文行（`Afterglow`，`\fad`）+ kara-templater
/// 生成的逐音节罗马音 fx 行（带 `\move`，Effect = fx）。
String _reference() {
  final StringBuffer b = StringBuffer()
    ..writeln('[Script Info]')
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
      'Style: Dialogue,Gandhi Sans,75,&H00FFFFFF,&H00C8CABF,&H000A051E,'
      '&H780C0C29,-1,0,0,0,100,100,0,0,1,3,1,2,150,150,55,1',
    )
    ..writeln(
      'Style: Afterglow,Iwata Gyousho Pro-Kami B,60,&H00000000,&H000000FF,'
      '&H00FFFFFF,&H00687EFF,0,0,0,0,100,100,0,0,1,3,0,3,30,30,10,1',
    )
    ..writeln(
      'Style: Afterglow - Romaji,Iwata Gyousho Pro-Kami B,60,&H00000000,'
      '&H000000FF,&H004D35FF,&H00687EFF,0,0,0,0,100,100,0,0,1,3,0,7,30,30,10,1',
    )
    ..writeln()
    ..writeln('[Events]')
    ..writeln(
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
      'Effect, Text',
    );
  // 普通对白，凑够参考的最少事件数。
  for (int i = 0; i < 12; i++) {
    final String t = '0:0${i ~/ 6}:${(i % 6 * 10).toString().padLeft(2, '0')}';
    b.writeln('Dialogue: 0,$t.00,$t.90,Dialogue,,0,0,0,,Line $i');
  }
  b
    ..writeln(
      r'Dialogue: 0,0:13:20.97,0:13:26.11,Afterglow,,0,0,0,,'
      r'{\fad(100,100)}I look back many times, but I run looking only forward',
    )
    ..writeln(
      r'Comment: 0,0:13:20.97,0:13:26.11,Afterglow - Romaji,,0,0,0,'
      r'template syl,{\pos($x,$y)}',
    )
    ..writeln(
      r'Dialogue: 1,0:13:20.97,0:13:21.80,Afterglow - Romaji,,0,0,0,fx,'
      r'{\move(100,40,110,40)\t(0,200,\fscx120)}fu',
    )
    ..writeln(
      r'Dialogue: 1,0:13:21.70,0:13:24.00,Afterglow - Romaji,,0,0,0,fx,'
      r'{\move(150,40,160,40)\t(0,200,\fscx120)}ri',
    )
    ..writeln(
      r'Dialogue: 1,0:13:23.90,0:13:26.11,Afterglow - Romaji,,0,0,0,fx,'
      r'{\move(200,40,210,40)\t(0,200,\fscx120)}ka',
    );
  return b.toString();
}

const int _songStart = 13 * 60000 + 20970;
const int _songEnd = 13 * 60000 + 26110;

AssStyleReference _ref([String? content]) =>
    parseAssStyleReference(content ?? _reference(), label: 'en')!;

/// 每字 [stepMs] 一个，从 [firstMs] 起依次排开。
List<AssCharTime> _even(String text, {int firstMs = 0, int stepMs = 200}) =>
    <AssCharTime>[
      for (int i = 0; i < text.runes.length; i++)
        (startMs: firstMs + i * stepMs, endMs: firstMs + (i + 1) * stepMs),
    ];

List<String> _dialogue(String ass) =>
    ass.split('\n').where((String l) => l.startsWith('Dialogue:')).toList();

/// `{\kNN}` / `{\kfNN}` 的累计结束时刻（厘秒）序列。
List<int> _karaokeCumulative(String line) {
  int t = 0;
  return <int>[
    for (final RegExpMatch m in RegExp(r'\\kf?(\d+)').allMatches(line))
      t += int.parse(m.group(1)!),
  ];
}

void main() {
  test('歌词行（参考在这段时间有 fx 罗马音）拿到单调的 \\kf，改用克隆样式', () {
    const String text = '振り返る、何度と';
    final String ass = renderAssWithReferenceStyle(
      cues: <AssStyledCue>[
        AssStyledCue(
          startMs: _songStart,
          endMs: _songEnd,
          text: text,
          charTimes: _even(text, firstMs: 150, stepMs: 300),
        ),
      ],
      reference: _ref(),
    );
    final String line = _dialogue(ass).single;
    expect(line, contains(',Afterglow Kara,'));
    // 继承英文译文行的 \fad；行首空档写成空音节 \k15。
    expect(line, contains(r'{\fad(100,100)}{\k15}{\kf30}振'));
    // 标点粘在前一个字上，不单独计时；它占的那段时间成了空音节 \k30。
    expect(line, contains(r'{\kf30}る、{\k30}{\kf30}何'));
    expect(RegExp(r'\\kf').allMatches(line).length, 7);
    final List<int> cum = _karaokeCumulative(line);
    for (int i = 1; i < cum.length; i++) {
      expect(cum[i], greaterThanOrEqualTo(cum[i - 1]));
    }
    expect(cum.last, lessThanOrEqualTo((_songEnd - _songStart) ~/ 10));
  });

  test('克隆样式：未唱色 = 主色 + &H90 透明，追加在原样式之后，只追加一次', () {
    const String a = '夕焼けの';
    const String b = '空へ';
    final String ass = renderAssWithReferenceStyle(
      cues: <AssStyledCue>[
        AssStyledCue(
          startMs: _songStart,
          endMs: _songStart + 2500,
          text: a,
          charTimes: _even(a),
        ),
        AssStyledCue(
          startMs: _songStart + 2500,
          endMs: _songEnd,
          text: b,
          charTimes: _even(b),
        ),
      ],
      reference: _ref(),
    );
    final List<String> styles = ass
        .split('\n')
        .where((String l) => l.startsWith('Style:'))
        .toList();
    expect(
      styles.where((String l) => l.startsWith('Style: Afterglow Kara,')),
      <String>[
        'Style: Afterglow Kara,Iwata Gyousho Pro-Kami B,60,&H00000000,'
            '&H90000000,&H00FFFFFF,&H00687EFF,0,0,0,0,100,100,0,0,1,3,0,3,'
            '30,30,10,1',
      ],
    );
    // 原有样式行一字不改、顺序不变，克隆行排在它们后面。
    final List<String> original = _reference()
        .split('\n')
        .where((String l) => l.startsWith('Style:'))
        .map((String l) => l.trimRight())
        .toList();
    expect(styles.take(original.length).toList(), original);
    expect(styles.length, original.length + 1);
    expect(
      _dialogue(ass).every((String l) => l.contains(',Afterglow Kara,')),
      isTrue,
    );
  });

  test('对白行（参考这段时间没有歌词事件）有逐字时间也不加 \\kf', () {
    const String text = 'こんにちは';
    final String ass = renderAssWithReferenceStyle(
      cues: <AssStyledCue>[
        AssStyledCue(
          startMs: 0,
          endMs: 900,
          text: text,
          charTimes: _even(text, stepMs: 150),
        ),
      ],
      reference: _ref(),
    );
    final String line = _dialogue(ass).single;
    expect(line, isNot(contains(r'\k')));
    expect(line, contains(',Dialogue,'));
    expect(ass, isNot(contains('Kara')));
  });

  test('唱歌时说话（定位的主对白样式行压在歌词上）不加 \\kf', () {
    // 实测 S2E13 7:16：英文轨把观众台词写成 {\pos} 的 Dialogue 行，压在歌词上。
    final String content = _reference().replaceFirst(
      'Comment: 0,0:13:20.97',
      'Dialogue: 5,0:13:21.00,0:13:22.50,Dialogue,,0,0,0,,'
          r'{\pos(960,990)}It'
          "'s a good song.\n"
          'Comment: 0,0:13:20.97',
    );
    const String text = 'いい曲ね';
    final String ass = renderAssWithReferenceStyle(
      cues: <AssStyledCue>[
        AssStyledCue(
          startMs: _songStart,
          endMs: _songStart + 2000,
          text: text,
          charTimes: _even(text),
        ),
      ],
      reference: _ref(content),
    );
    expect(_dialogue(ass).single, isNot(contains(r'\k')));
    expect(ass, isNot(contains('Kara')));
  });

  test('歌词行但没有逐字时间（对齐质量差，上游给 null）→ 不加 \\kf、不克隆', () {
    final String ass = renderAssWithReferenceStyle(
      cues: <AssStyledCue>[
        const AssStyledCue(startMs: _songStart, endMs: _songEnd, text: '振り返る'),
      ],
      reference: _ref(),
    );
    final String line = _dialogue(ass).single;
    expect(line, isNot(contains(r'\k')));
    expect(line, contains(',Afterglow,'));
    expect(ass, isNot(contains('Afterglow Kara')));
  });

  test('逐字时间长度与正文码点数不符 → 当作没有', () {
    final String ass = renderAssWithReferenceStyle(
      cues: <AssStyledCue>[
        AssStyledCue(
          startMs: _songStart,
          endMs: _songEnd,
          text: '振り返る',
          charTimes: _even('振り'),
        ),
      ],
      reference: _ref(),
    );
    expect(_dialogue(ass).single, isNot(contains(r'\k')));
  });

  test('lyricsHint：参考里没有歌词事件也按歌词行出 \\kf', () {
    const String text = '♪ 明日へ';
    final String ass = renderAssWithReferenceStyle(
      cues: <AssStyledCue>[
        AssStyledCue(
          startMs: 0,
          endMs: 900,
          text: text,
          charTimes: _even(text, stepMs: 100),
          lyricsHint: true,
        ),
      ],
      reference: _ref(),
    );
    final String line = _dialogue(ass).single;
    // 行首的 ♪ 和空格粘到第一个字前面。
    expect(line, contains(r'{\k20}{\kf10}♪ 明'));
    expect(line, contains(',Dialogue Kara,'));
  });

  test('参考行的 \\2c 不继承到卡拉 OK 行（未唱色只认克隆样式）', () {
    final String content = _reference().replaceFirst(
      r'{\fad(100,100)}I look back',
      r'{\fad(100,100)\2c&H0000FF&}I look back',
    );
    const String text = '振り返る';
    final String ass = renderAssWithReferenceStyle(
      cues: <AssStyledCue>[
        AssStyledCue(
          startMs: _songStart,
          endMs: _songEnd,
          text: text,
          charTimes: _even(text),
        ),
      ],
      reference: _ref(content),
    );
    expect(_dialogue(ass).single, isNot(contains(r'\2c')));
  });

  test('isAssSongSpan：逐音节 fx 的重叠按并集算；对白时段不算', () {
    final AssStyleReference ref = _ref();
    expect(
      isAssSongSpan(startMs: _songStart, endMs: _songEnd, events: ref.events),
      isTrue,
    );
    expect(isAssSongSpan(startMs: 0, endMs: 900, events: ref.events), isFalse);
  });

  test('isAssSongEvent：\\k 标签、Effect fx / karaoke / template、样式名', () {
    AssReferenceEvent ev({
      String style = 'Default',
      String effect = '',
      String text = 'x',
    }) => AssReferenceEvent(
      layer: '0',
      startMs: 0,
      endMs: 1,
      style: style,
      name: '',
      marginL: '0',
      marginR: '0',
      marginV: '0',
      effect: effect,
      text: text,
    );
    expect(isAssSongEvent(ev(text: r'{\k20}ka{\k30}ra')), isTrue);
    expect(isAssSongEvent(ev(effect: 'fx')), isTrue);
    expect(isAssSongEvent(ev(effect: 'karaoke')), isTrue);
    expect(isAssSongEvent(ev(effect: 'template syl')), isTrue);
    expect(isAssSongEvent(ev(style: 'OP Romaji')), isTrue);
    expect(isAssSongEvent(ev(style: 'Dialogue')), isFalse);
    expect(isAssSongEvent(ev(effect: 'fxgroup')), isFalse);
  });
}
