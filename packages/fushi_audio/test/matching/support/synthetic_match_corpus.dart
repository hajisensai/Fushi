import 'package:fushi_audio/fushi_audio.dart';

/// 匹配器对拍用的确定性合成语料。
///
/// 回归夹具 `fixtures/epub_srt_matcher_golden.json` 记的是**旧 Dart 实现**
/// （搬进 native/fushi_compute 之前）在这批语料上的逐位输出；本文件按种子重建同一批
/// 输入，测试比对新实现与夹具。改这里的生成规则会让 [inputHash] 对不上夹具，测试会
/// 先报「语料漂移」而不是假装算法变了——那种情况只能用旧实现重新生成夹具。
///
/// 覆盖面：精确 / 模糊 / 读音轨（ruby，含小書き仮名）/ 跨节 / 恢复扫描（长段非正文、
/// 跳读整段）/ 起点检测（片头念到书尾版权页的出版社名）/ 超短 cue / `＊` 旁白 /
/// 尾巴回吃（BUG-2204 的切句漂移）/ 代理对（CJK 扩展 B）。
class SyntheticMatchCase {
  SyntheticMatchCase(this.seed, this.sections, this.cues);

  final int seed;
  final List<EpubSection> sections;
  final List<AudioCue> cues;

  /// 输入的 FNV-1a 64 位指纹（十六进制），夹具据此确认语料没漂。
  String get inputHash {
    int h = 0xcbf29ce484222325;
    void mix(int v) {
      h ^= v & 0xFFFFFFFF;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }

    void mixString(String s) {
      mix(s.length);
      for (int i = 0; i < s.length; i++) {
        mix(s.codeUnitAt(i));
      }
    }

    for (final EpubSection s in sections) {
      mix(s.index);
      mixString(s.href);
      mixString(s.text);
      mix(s.rubies.length);
      for (final EpubRubySpan r in s.rubies) {
        mix(r.start);
        mix(r.end);
        mixString(r.reading);
      }
    }
    for (final AudioCue c in cues) {
      mix(c.sentenceIndex);
      mixString(c.text);
    }
    return h.toUnsigned(64).toRadixString(16);
  }
}

/// 32 位 xorshift：不依赖 `dart:math` 的 Random 实现细节。
class _Rng {
  _Rng(int seed) : _s = (seed * 2654435761 + 12345) & 0xFFFFFFFF {
    if (_s == 0) _s = 1;
    for (int i = 0; i < 8; i++) {
      next();
    }
  }

  int _s;

  int next() {
    int x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x & 0xFFFFFFFF;
    return _s;
  }

  int nextInt(int n) => next() % n;

  bool chance(int percent) => nextInt(100) < percent;

  T pick<T>(List<T> xs) => xs[nextInt(xs.length)];
}

const List<String> _kana = <String>[
  'あ', 'い', 'う', 'え', 'お', 'か', 'き', 'く', 'け', 'こ', 'さ', 'し', //
  'す', 'せ', 'そ', 'た', 'ち', 'つ', 'て', 'と', 'な', 'に', 'ぬ', 'ね',
  'の', 'は', 'ひ', 'ふ', 'へ', 'ほ', 'ま', 'み', 'む', 'め', 'も', 'や',
  'ゆ', 'よ', 'ら', 'り', 'る', 'れ', 'ろ', 'わ', 'を', 'ん', 'が', 'だ',
  'ぁ', 'っ', 'ゃ', 'ょ', 'ゅ', 'ぃ',
];
const List<String> _katakana = <String>[
  'ア', 'イ', 'シ', 'ル', 'フ', 'ー', 'ド', 'オ', 'レ', 'ン', 'ィ', 'ッ', //
  'ャ', 'ュ', 'ョ', 'ヴ',
];
const List<String> _kanji = <String>[
  '私', '彼', '子', '友', '達', '素', '敵', '目', '配', '息', '中', '家', //
  '帰', '周', '世', '界', '本', '気', '魔', '術', '剣', '神', '父', '母',
  '学', '校', '先', '生', '時', '間', '日', '月', '年', '人', '言', '見',
  '々', '〇',
];
const List<String> _other = <String>[
  '、', '。', '「', '」', '！', '？', '…', ' ', '　', 'A', 'b', '3', '９', //
  'Ｚ', '・', '\u{2000B}', '\u{20B9F}',
];

String _token(_Rng r, int kind) {
  switch (kind) {
    case 0:
      return r.pick(_kana);
    case 1:
      return r.pick(_katakana);
    case 2:
      return r.pick(_kanji);
    default:
      return r.pick(_other);
  }
}

/// 一句正文：小字表（易撞 bigram）+ 偶发标点 / 字母 / 扩展 B。
String _sentence(_Rng r, int minLen, int maxLen) {
  final int len = minLen + r.nextInt(maxLen - minLen + 1);
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < len; i++) {
    final int roll = r.nextInt(100);
    b.write(
      _token(
        r,
        roll < 55
            ? 0
            : roll < 68
            ? 1
            : roll < 92
            ? 2
            : 3,
      ),
    );
  }
  b.write(r.chance(70) ? '。' : '」');
  return b.toString();
}

String _reading(_Rng r, int len) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < len; i++) {
    b.write(r.pick(_kana));
  }
  return b.toString();
}

/// 听写式变形：替换 / 删除 / 插入 1~3 处。
String _mutate(_Rng r, String s) {
  final List<String> chars = s.split('');
  final int edits = 1 + r.nextInt(3);
  for (int e = 0; e < edits && chars.isNotEmpty; e++) {
    final int at = r.nextInt(chars.length);
    switch (r.nextInt(3)) {
      case 0:
        chars[at] = r.pick(_kana);
      case 1:
        chars.removeAt(at);
      default:
        chars.insert(at, r.pick(_kana));
    }
  }
  return chars.join();
}

AudioCue _cue(int idx, String text) => AudioCue()
  ..bookKey = 'synthetic'
  ..chapterHref = ''
  ..sentenceIndex = idx
  ..textFragmentId = ''
  ..text = text
  ..startMs = idx * 1000
  ..endMs = idx * 1000 + 900
  ..audioFileIndex = 0;

SyntheticMatchCase buildSyntheticMatchCase(int seed) {
  final _Rng r = _Rng(seed);
  final int sectionCount = 1 + r.nextInt(5);
  final bool useRuby = r.chance(60);
  final List<EpubSection> sections = <EpubSection>[];
  // (节, 句文本, 该句里各 ruby 的 (句内起点, 终点, 读音))，供生成 cue。
  final List<(int, String, List<(int, int, String)>)> sentences =
      <(int, String, List<(int, int, String)>)>[];
  const String publisher = '株式会社カドカワ出版';
  final List<String> pool = <String>[];
  for (int si = 0; si < sectionCount; si++) {
    final StringBuffer text = StringBuffer();
    final List<EpubRubySpan> rubies = <EpubRubySpan>[];
    final int count = 4 + r.nextInt(30);
    for (int k = 0; k < count; k++) {
      // 偶尔复用前面的句子：制造多处精确出现与歧义。
      final String s = pool.isNotEmpty && r.chance(6)
          ? r.pick(pool)
          : _sentence(r, 3, 28);
      pool.add(s);
      final int base = text.length;
      final List<(int, int, String)> local = <(int, int, String)>[];
      if (useRuby) {
        int i = 0;
        while (i < s.length) {
          final int c = s.codeUnitAt(i);
          final bool isKanji = c >= 0x4E00 && c <= 0x9FFF;
          if (isKanji && r.chance(40)) {
            int j = i + 1;
            while (j < s.length &&
                j - i < 3 &&
                s.codeUnitAt(j) >= 0x4E00 &&
                s.codeUnitAt(j) <= 0x9FFF) {
              j++;
            }
            final String reading = r.chance(10)
                ? '・'
                : _reading(r, 1 + r.nextInt(4));
            local.add((i, j, reading));
            rubies.add(
              EpubRubySpan(start: base + i, end: base + j, reading: reading),
            );
            i = j;
          } else {
            i++;
          }
        }
      }
      text.write(s);
      if (r.chance(15)) text.write('\n');
      sentences.add((si, s, local));
    }
    if (si == sectionCount - 1 && r.chance(50)) {
      text.write('発行所$publisher。');
    }
    sections.add(
      EpubSection(
        index: si,
        href: 'ch$si.xhtml',
        text: text.toString(),
        rubies: rubies,
      ),
    );
  }

  final List<String> cueTexts = <String>[];
  // 片头：念到书尾版权页的出版社名 / 正文里没有的登场人物页。
  if (r.chance(30)) cueTexts.add(publisher);
  if (r.chance(30)) {
    final int junk = 5 + r.nextInt(30);
    for (int k = 0; k < junk; k++) {
      cueTexts.add(_sentence(r, 6, 20));
    }
  }
  int k = 0;
  while (k < sentences.length) {
    final (int _, String s, List<(int, int, String)> rubies) = sentences[k];
    final int roll = r.nextInt(100);
    if (roll < 3 && sentences.length - k > 30) {
      // 跳读一大段（逼出恢复扫描）。
      k += 10 + r.nextInt(20);
      continue;
    }
    if (roll < 6) {
      // 音频独有的一串旁白。
      final int junk = 3 + r.nextInt(25);
      for (int j = 0; j < junk; j++) {
        cueTexts.add(_sentence(r, 4, 18));
      }
    } else if (roll < 10) {
      cueTexts.add(r.pick(<String>['うん', 'はい', 'え', 'ああ', '一']));
    } else if (roll < 13) {
      cueTexts.add('＊$s');
      k++;
      continue;
    }
    final int mode = r.nextInt(100);
    if (mode < 50) {
      cueTexts.add(s);
    } else if (mode < 66) {
      cueTexts.add(_mutate(r, s));
    } else if (mode < 76 && rubies.isNotEmpty) {
      // 听写かな：ruby 基底换成读音（小書き仮名改成並字 / 反之）。
      final StringBuffer b = StringBuffer();
      int at = 0;
      for (final (int i, int j, String reading) in rubies) {
        b.write(s.substring(at, i));
        b.write(r.chance(50) ? reading : reading.replaceAll('つ', 'っ'));
        at = j;
      }
      b.write(s.substring(at));
      cueTexts.add(b.toString());
    } else if (mode < 84 && s.length > 8) {
      // 一句切成两条。
      final int cut = 3 + r.nextInt(s.length - 6);
      cueTexts.add(s.substring(0, cut));
      cueTexts.add(s.substring(cut));
    } else if (mode < 90 && k + 1 < sentences.length) {
      // 切句漂移：前句多带了下一句的首字（BUG-2204）。
      final String next = sentences[k + 1].$2;
      cueTexts.add(s + next.substring(0, 1));
      cueTexts.add(next.substring(1));
      k += 2;
      continue;
    } else if (mode < 95 && k + 1 < sentences.length) {
      cueTexts.add(s + sentences[k + 1].$2);
      k += 2;
      continue;
    } else {
      cueTexts.add(_mutate(r, _mutate(r, s)));
    }
    k++;
  }
  if (r.chance(30)) cueTexts.add('');
  final List<AudioCue> cues = <AudioCue>[
    for (int i = 0; i < cueTexts.length; i++) _cue(i, cueTexts[i]),
  ];
  return SyntheticMatchCase(seed, sections, cues);
}

/// 每个合成用例跑的匹配参数：(窗口, 阈值, 连续 miss 上限)。
List<(int, double, int)> syntheticMatchConfigs(int seed) {
  final _Rng r = _Rng(seed ^ 0x5bd1e995);
  return <(int, double, int)>[
    (200, 0.8, 20),
    (r.pick(<int>[20, 50, 350]), r.pick(<double>[0.6, 0.7]), 20),
    (r.pick(<int>[50, 200]), 0.8, r.pick(<int>[3, 5, 8])),
  ];
}

/// 合成用例的种子范围（夹具按这个顺序记）。
const int kSyntheticMatchCaseCount = 160;
