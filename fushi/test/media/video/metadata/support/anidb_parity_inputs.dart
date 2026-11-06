// 确定性构造的对拍输入：AniDB 标题包 / 搜索查询 / 标题对 / 分集匹配场景。
//
// 标题归一化、相似度、AniDB 目录解析与搜索、TMDB 分集匹配从 Dart 搬进 Rust
// （native/fushi_compute）时，先用**旧 Dart 实现**跑这里生成的输入，把输出摘要冻结成
// anidb_native_parity_test.dart 里的常量，再删掉 Dart 实现。改这个文件的任何生成逻辑
// 都会让常量失效——那就不再是对拍了，别改。
import 'dart:math';
import 'dart:typed_data';

/// 64 位 FNV-1a over UTF-16 码元（输出摘要用）。
int fnv64(String s, [int hash = 0xcbf29ce484222325]) {
  for (int i = 0; i < s.length; i++) {
    final int u = s.codeUnitAt(i);
    hash ^= u & 0xff;
    hash *= 0x100000001b3;
    hash ^= u >> 8;
    hash *= 0x100000001b3;
  }
  return hash;
}

/// double 的位模式（十六进制）。
String doubleBits(double v) {
  final ByteData data = ByteData(8)..setFloat64(0, v);
  return data.getUint64(0).toRadixString(16).padLeft(16, '0');
}

const List<String> _romaji = <String>[
  'ka',
  'ki',
  'ku',
  'ke',
  'ko',
  'sa',
  'shi',
  'su',
  'se',
  'so',
  'ta',
  'chi',
  'tsu',
  'te',
  'to',
  'na',
  'ni',
  'nu',
  'ne',
  'no',
  'ha',
  'hi',
  'fu',
  'he',
  'ho',
  'ma',
  'mi',
  'mu',
  'me',
  'mo',
  'ya',
  'yu',
  'yo',
  'ra',
  'ri',
  'ru',
  're',
  'ro',
  'wa',
  'n',
  'ga',
  'gi',
  'zu',
  'de',
  'bo',
  'pa',
  'kyo',
  'ryu',
];
const String _kanji =
    '無職転生戰鬥學園魔法少女進撃巨人鬼滅刃葬送冒険物語異世界王国騎士龍竜機動戦士'
    '銀河英雄伝説時計島恋愛學校夢幻劍風傳奇東京喰種黒執事桜花雪月花';
const String _kana =
    'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん'
    'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンー';
const List<String> _english = <String>[
  'the',
  'of',
  'and',
  'in',
  'a',
  'to',
  'world',
  'girl',
  'boy',
  'magic',
  'war',
  'love',
  'school',
  'dragon',
  'star',
  'night',
  'blade',
  'sky',
  'sea',
  'dream',
  'story',
  'legend',
  'king',
  'queen',
  'hero',
  'online',
  'season',
];
const List<String> _decor = <String>[
  '!',
  '?',
  ':',
  '~',
  '～',
  '・',
  '「',
  '」',
  '【',
  '】',
  '☆',
  '♪',
  '-',
  '&',
  '(',
  ')',
  '.',
  ',',
  "'",
  '"',
  '…',
  '°',
  '/',
];
const List<String> _suffix = <String>[
  '2nd Season',
  'Season 2',
  'II',
  'Ⅱ',
  '第2期',
  '第二季',
  'The Movie',
  'OVA',
  'Specials',
  '(2011)',
  'Final Season',
  'Shin',
  '续篇',
  'S2',
  '3',
];

String _word(Random rnd) {
  switch (rnd.nextInt(10)) {
    case 0:
    case 1:
    case 2:
      final int n = 1 + rnd.nextInt(4);
      final StringBuffer b = StringBuffer();
      for (int i = 0; i < n; i++) {
        b.write(_romaji[rnd.nextInt(_romaji.length)]);
      }
      final String w = b.toString();
      return rnd.nextBool() ? '${w[0].toUpperCase()}${w.substring(1)}' : w;
    case 3:
    case 4:
      return _english[rnd.nextInt(_english.length)];
    case 5:
      final int n = 1 + rnd.nextInt(5);
      return String.fromCharCodes(<int>[
        for (int i = 0; i < n; i++)
          _kanji.codeUnitAt(rnd.nextInt(_kanji.length)),
      ]);
    case 6:
      final int n = 2 + rnd.nextInt(6);
      return String.fromCharCodes(<int>[
        for (int i = 0; i < n; i++) _kana.codeUnitAt(rnd.nextInt(_kana.length)),
      ]);
    case 7:
      return _suffix[rnd.nextInt(_suffix.length)];
    case 8:
      return <String>[
        'Ångström',
        'Café',
        'Σοφία',
        'Москва',
        'Ⅲ',
        '86',
        'Ｚ',
        'ＩＩ',
        'İzmir',
        'Straße',
      ][rnd.nextInt(10)];
    default:
      return '${rnd.nextInt(30)}';
  }
}

String makeTitle(Random rnd) {
  final int words = 1 + rnd.nextInt(5);
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < words; i++) {
    if (i > 0) {
      b.write(rnd.nextInt(6) == 0 ? _decor[rnd.nextInt(_decor.length)] : ' ');
      if (rnd.nextInt(8) == 0) b.write(' ');
    }
    b.write(_word(rnd));
  }
  if (rnd.nextInt(10) == 0) b.write(_decor[rnd.nextInt(_decor.length)]);
  return b.toString();
}

String _escape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// 合成标题包：[animeCount] 部，系列名在多部之间共享（造出前缀命中、近重复与打平）。
({String xml, List<String> titles}) buildCatalogXml({
  int animeCount = 3000,
  int seed = 1,
}) {
  final Random rnd = Random(seed);
  final List<String> series = <String>[
    for (int i = 0; i < 400; i++) makeTitle(rnd),
  ];
  const List<String> types = <String>[
    'main',
    'official',
    'syn',
    'short',
    'synonym',
    'kana',
    'Official',
    ' syn ',
  ];
  const List<String> langs = <String>[
    'x-jat',
    'en',
    'ja',
    'zh-Hans',
    'zh-Hant',
    'ko',
    'fr',
    'x-other',
  ];
  final StringBuffer xml = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8"?>\n<animetitles>\n',
  );
  final List<String> titles = <String>[];
  int aid = 0;
  for (int i = 0; i < animeCount; i++) {
    aid += 1 + rnd.nextInt(3);
    xml.write('  <anime aid="$aid">\n');
    final String base = series[rnd.nextInt(series.length)];
    final int n = 1 + rnd.nextInt(8);
    for (int k = 0; k < n; k++) {
      final String value = switch (rnd.nextInt(6)) {
        0 => base,
        1 => '$base ${_suffix[rnd.nextInt(_suffix.length)]}',
        2 => base.toUpperCase(),
        3 => makeTitle(rnd),
        4 => '$base: ${makeTitle(rnd)}',
        _ => k == 0 ? base : makeTitle(rnd),
      };
      titles.add(value);
      final String type = k == 0 ? 'main' : types[rnd.nextInt(types.length)];
      final String lang = langs[rnd.nextInt(langs.length)];
      final String body = rnd.nextInt(15) == 0
          ? '<![CDATA[$value]]>'
          : _escape(value);
      xml.write('    <title type="$type" xml:lang="$lang">$body</title>\n');
      if (rnd.nextInt(12) == 0) {
        // 同值同类型同语言的重复项：构建器要去重。
        xml.write('    <title type="$type" xml:lang="$lang">$body</title>\n');
      }
    }
    xml.write('  </anime>\n');
  }
  xml.write('</animetitles>\n');
  return (xml: xml.toString(), titles: titles);
}

String _fuzz(String s) {
  if (s.length < 6) return '$s x';
  final int cut = s.length ~/ 2;
  return '${s.substring(0, cut)}${s.substring(cut + 1)} 2nd season';
}

String _fullwidth(String s) => String.fromCharCodes(<int>[
  for (final int r in s.runes)
    if (r >= 0x21 && r <= 0x7E) r + 0xFEE0 else r,
]);

/// 搜索查询（精确 / 前缀 / 模糊 / 文件名式 / 全角 / 大小写 / 短串）。
List<String> buildQueries(List<String> titles, {int seed = 2}) {
  final Random rnd = Random(seed);
  String pick() => titles[rnd.nextInt(titles.length)];
  return <String>[
    for (int i = 0; i < 80; i++) pick(),
    for (int i = 0; i < 80; i++) _fuzz(pick()),
    for (int i = 0; i < 60; i++)
      '[Group] ${_fuzz(pick())} - 0${rnd.nextInt(10)} (1080p)',
    for (int i = 0; i < 40; i++)
      () {
        final List<int> r = pick().runes.toList();
        return String.fromCharCodes(r.take(1 + rnd.nextInt(min(5, r.length))));
      }(),
    for (int i = 0; i < 30; i++) pick().toUpperCase(),
    for (int i = 0; i < 30; i++) _fullwidth(pick()),
    for (int i = 0; i < 40; i++) makeTitle(rnd),
    '無職転生',
    '无职转生 第二季',
    'a',
    'the',
    'no',
    '!!!',
    '☆',
    'Ⅱ',
    '86',
    'ka',
  ];
}

/// 标题对（随机对 / 变形对 / 大小写对 / 长串对，长串走编辑距离 DP 路径）。
List<(String, String)> buildPairs(List<String> titles, {int seed = 3}) {
  final Random rnd = Random(seed);
  String pick() => titles[rnd.nextInt(titles.length)];
  return <(String, String)>[
    for (int i = 0; i < 1500; i++) (pick(), pick()),
    for (int i = 0; i < 1000; i++)
      () {
        final String t = pick();
        return (t, _fuzz(t));
      }(),
    for (int i = 0; i < 300; i++)
      () {
        final String t = pick();
        return (t, t.toUpperCase());
      }(),
    for (int i = 0; i < 150; i++)
      (
        '${pick()} ${pick()} ${pick()} ${pick()}',
        '${pick()} ${pick()} ${pick()}',
      ),
    for (int i = 0; i < 300; i++) (makeTitle(rnd), makeTitle(rnd)),
    ('', ''),
    ('', 'a'),
    ('☆', '★'),
    ('\u{D800}x', 'x\u{DC00}'),
    ('𠮷野家', '𠮷野屋'),
  ];
}

/// TMDB 分集匹配场景：返回（正片来源, 特典来源, 候选集, 别名）。来源 = (集号, 标题, 播出日)。
typedef MatcherScenario = ({
  List<(int, List<String>, String?)> sources,
  List<(int, List<String>, String?)> specials,
  List<(int, int, String, String?)> episodes,
  Map<(int, int), List<String>> aliases,
});

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

List<MatcherScenario> buildMatcherScenarios({int count = 300, int seed = 4}) {
  final Random rnd = Random(seed);
  final List<MatcherScenario> out = <MatcherScenario>[];
  for (int s = 0; s < count; s++) {
    final List<(int, int, String, String?)> episodes =
        <(int, int, String, String?)>[];
    final Map<(int, int), List<String>> aliases = <(int, int), List<String>>{};
    DateTime date = DateTime.utc(
      2000 + rnd.nextInt(20),
      1 + rnd.nextInt(12),
      1 + rnd.nextInt(28),
    );
    final int seasons = 1 + rnd.nextInt(3);
    for (int season = rnd.nextBool() ? 0 : 1; season <= seasons; season++) {
      final int n = 2 + rnd.nextInt(season == 0 ? 5 : 20);
      for (int e = 1; e <= n; e++) {
        final String title = rnd.nextInt(10) == 0
            ? 'Episode $e'
            : makeTitle(rnd);
        episodes.add((
          season,
          e,
          title,
          rnd.nextInt(8) == 0 ? null : _date(date),
        ));
        if (rnd.nextInt(4) == 0) {
          aliases[(season, e)] = <String>[makeTitle(rnd), title.toUpperCase()];
        }
        date = date.add(
          Duration(days: 7 + (rnd.nextInt(5) == 0 ? rnd.nextInt(60) : 0)),
        );
      }
    }
    List<(int, List<String>, String?)> sources(bool specials) {
      final List<(int, int, String, String?)> eligible =
          <(int, int, String, String?)>[
            for (final (int, int, String, String?) e in episodes)
              if ((e.$1 == 0) == specials) e,
          ];
      final List<(int, List<String>, String?)> list =
          <(int, List<String>, String?)>[];
      int number = 1;
      for (final (int _, int _, String title, String? air) in eligible) {
        if (rnd.nextInt(5) == 0) continue;
        String? airDate = air;
        if (airDate != null && rnd.nextInt(3) == 0) {
          airDate = _date(
            DateTime.parse(airDate).add(Duration(days: rnd.nextInt(7) - 3)),
          );
        } else if (rnd.nextInt(6) == 0) {
          airDate = null;
        }
        list.add((
          number,
          <String>[
            switch (rnd.nextInt(6)) {
              0 => title,
              1 => _fuzz(title),
              2 => title.toUpperCase(),
              3 => makeTitle(rnd),
              4 => 'Episode $number',
              _ =>
                title.length > 4 ? title.substring(0, title.length - 2) : title,
            },
            if (rnd.nextBool()) makeTitle(rnd),
            if (rnd.nextInt(3) == 0) _fullwidth(title),
          ],
          airDate,
        ));
        number += rnd.nextInt(6) == 0 ? 2 : 1;
      }
      list.shuffle(rnd);
      return list;
    }

    episodes.shuffle(rnd);
    out.add((
      sources: sources(false),
      specials: sources(true),
      episodes: episodes,
      aliases: aliases,
    ));
  }
  return out;
}

/// 畸形 / 边界标题包（明文 XML）。
const Map<String, String> malformedCatalogs = <String, String>{
  'doctype':
      '<!DOCTYPE animetitles [<!ENTITY x "y">]><animetitles><anime aid="1"><title type="main" xml:lang="en">A</title></anime></animetitles>',
  'root':
      '<root><anime aid="1"><title type="main" xml:lang="en">A</title></anime></root>',
  'mismatch':
      '<animetitles><anime aid="1"><title type="main" xml:lang="en">A</anime></title></animetitles>',
  'unexpected_close': '</animetitles>',
  'missing_close':
      '<animetitles><anime aid="1"><title type="main" xml:lang="en">A</title>',
  'truncated_tag':
      '<animetitles><anime aid="1"><title type="main" xml:lang="en">A</title></anime',
  'garbage': '<animetitles><1abc></animetitles>',
  'empty_root': '<animetitles/>',
  'no_root_text': 'hello world',
  'builder_then_mismatch': '<animetitles><bad></animetitles>',
  'unclosed_comment':
      '<animetitles><anime aid="25"><title type="main" xml:lang="en">z</title></anime><!-- never closed',
};

String _hex64(int v) => v.toUnsigned(64).toRadixString(16);

/// 新旧实现共用的摘要计算（catalog 用 dynamic：新旧 `AniDbTitleCatalog` 公共 API 同形）。
/// [matchScenario] 返回一个场景的匹配结果的规范字符串。
Future<Map<String, String>> parityDigests({
  required String Function(String) normalize,
  required List<String> Function(String) tokens,
  required double Function(String, String) similarity,
  required double Function(String, String) similarityNormalized,
  required Future<dynamic> Function(String xml) openCatalog,
  required String Function(MatcherScenario) matchScenario,
}) async {
  final ({String xml, List<String> titles}) built = buildCatalogXml();
  final dynamic catalog = await openCatalog(built.xml);
  final StringBuffer records = StringBuffer();
  int recordCount = 0;
  for (int aid = 1; aid <= 10000; aid++) {
    final dynamic r = await catalog.findByAnimeId(aid);
    if (r == null) continue;
    recordCount++;
    records.write('$aid');
    for (final dynamic t in r.titles) {
      records.write(
        '|${t.value}\u0001${t.type}\u0001${t.language}\u0001${t.normalizedValue}',
      );
    }
    records.write('\n');
  }
  final StringBuffer search = StringBuffer();
  int hits = 0;
  final List<String> queries = buildQueries(built.titles);
  for (int i = 0; i < queries.length; i++) {
    final int limit = i % 7 == 0 ? 3 : (i % 11 == 0 ? 40 : 15);
    final List<dynamic> results = await catalog.search(
      queries[i],
      limit: limit,
    );
    search.write('${queries[i]}\u0002');
    for (final dynamic r in results) {
      hits++;
      search.write(
        '${r.record.animeId}\u0001${r.matchedTitle.value}\u0001'
        '${r.matchedTitle.type}\u0001${(r.kind as Enum).index}\u0001'
        '${doubleBits(r.similarity as double)}|',
      );
    }
    search.write('\n');
  }
  catalog.close();
  final StringBuffer text = StringBuffer();
  int pairs = 0;
  for (final (String a, String b) in buildPairs(built.titles)) {
    pairs++;
    final String na = normalize(a);
    final String nb = normalize(b);
    text
      ..write(na)
      ..write('\u0001')
      ..write(nb)
      ..write('\u0001')
      ..write(tokens(na).join('\u0003'))
      ..write('\u0001')
      ..write(doubleBits(similarity(a, b)))
      ..write('\u0001')
      ..write(doubleBits(similarityNormalized(na, nb)))
      ..write('\n');
  }
  final StringBuffer matcher = StringBuffer();
  final List<MatcherScenario> scenarios = buildMatcherScenarios();
  for (final MatcherScenario scenario in scenarios) {
    matcher
      ..write(matchScenario(scenario))
      ..write('\n');
  }
  return <String, String>{
    'records': '$recordCount:${_hex64(fnv64(records.toString()))}',
    'search': '${queries.length}/$hits:${_hex64(fnv64(search.toString()))}',
    'text': '$pairs:${_hex64(fnv64(text.toString()))}',
    'matcher': '${scenarios.length}:${_hex64(fnv64(matcher.toString()))}',
  };
}
