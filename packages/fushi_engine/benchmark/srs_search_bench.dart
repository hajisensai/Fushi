// Anki 搜索三条路径的耗时（手动跑，不进 CI）：浏览页搜索、统计页筛选、AnkiConnect 查重。
//
// 在 packages/fushi_engine 下：
//   FUSHI_FSRS_LIB=<fushi_fsrs.dll 绝对路径> dart run benchmark/srs_search_bench.dart [卡数 ...]
//
// 合成集合：每条笔记两张卡，Lapis 形状的 13 个字段；Glossary 是 Yomitan 释义 HTML，
// [_inlineStyleRate] 的笔记内联 1～3 部词典的 `<style>`（2～40 KB，未经样式去重的旧卡 / 导入卡），
// 其余是去重后的引用行。
import 'dart:async';
import 'dart:math';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_srs/fushi_srs.dart';

const double _inlineStyleRate = 0.15;
const String _profile = '01928c3e-0000-7000-8000-0000000000b5';

const List<String> _fieldNames = <String>[
  'Expression',
  'ExpressionFurigana',
  'ExpressionReading',
  'ExpressionAudio',
  'SelectionText',
  'MainDefinition',
  'Sentence',
  'SentenceFurigana',
  'SentenceAudio',
  'Picture',
  'Glossary',
  'MiscInfo',
  'Frequency',
];

const List<String> _kana = <String>[
  'あ', 'い', 'う', 'え', 'お', 'か', 'き', 'く', 'け', 'こ', 'さ', 'し', 'す', //
  'た', 'ち', 'つ', 'て', 'と', 'な', 'に', 'の', 'は', 'ま', 'み', 'る', 'れ',
];
const List<String> _kanji = <String>[
  '食', '語', '見', '行', '来', '話', '読', '書', '聞', '学', '生', '日', '本', //
  '人', '大', '小', '山', '川', '水', '火', '木', '金', '土', '電', '車', '気',
];
const List<String> _english = <String>[
  'to eat', 'to see', 'language', 'to go', 'to come', 'to speak', 'to read', //
  'to write', 'to hear', 'study', 'life', 'sun', 'book', 'person', 'big',
];

/// 一部词典的 CSS：[bytes] 字节左右的规则堆（Yomitan 结构化内容的样子）。
String _css(int dict, int bytes) {
  final StringBuffer b = StringBuffer();
  int i = 0;
  while (b.length < bytes) {
    b.write(
      '.yomitan-glossary [data-dictionary="Dict$dict"] '
      '[data-sc-content="c$i"] { margin-left: ${i % 7}px; '
      'font-size: ${80 + i % 40}%; color: #${(i * 2654435761 % 0xffffff).toRadixString(16).padLeft(6, '0')}; }\n',
    );
    i++;
  }
  return b.toString();
}

class _Corpus {
  _Corpus(
    this.cards,
    this.noteTypes,
    this.notes,
    this.tree,
    this.day,
    this.now,
  );

  final List<SrsCardSearchSubject> cards;
  final List<SrsNoteTypeView> noteTypes;
  final Map<String, SrsNoteView> notes;
  final SrsDeckTree tree;
  final SrsDayContext day;
  final int now;

  late final List<SrsCardCacheRow> rows = <SrsCardCacheRow>[
    for (final SrsCardSearchSubject c in cards) c.card,
  ];
}

SrsDeckView _deck(String id, String name, String? parent) => SrsDeckView(
  id: id,
  name: name,
  parentId: parent,
  ownParams: parent == null,
  newPerDay: 20,
  reviewsPerDay: 200,
  learnSteps: SrsDeckView.defaultLearnSteps,
  relearnSteps: SrsDeckView.defaultRelearnSteps,
  desiredRetention: 0.9,
  algorithmWire: 'fsrs7',
  algorithmAuto: false,
  fsrs6: null,
  fsrs7: null,
  autoOptimize: false,
  maxIntervalDays: 36500,
  optimizeBaselineAt: null,
  optimizeBaselineCount: null,
  deletedAt: null,
  builtinKey: null,
  createdAt: 0,
  edits: SrsEntityEdits(<String, SrsRegister>{}),
);

_Corpus _generate(int cardCount, {int seed = 42}) {
  final Random rng = Random(seed);
  final List<String> styles = <String>[
    for (final (int i, int kb) in <(int, int)>[
      (0, 2),
      (1, 5),
      (2, 8),
      (3, 15),
      (4, 25),
      (5, 40),
    ])
      _css(i, kb * 1024),
  ];
  final List<SrsFieldDef> fields = <SrsFieldDef>[
    for (int i = 0; i < _fieldNames.length; i++)
      SrsFieldDef(id: 'f$i', name: _fieldNames[i], ord: i),
  ];
  final SrsNoteTypeView type = SrsNoteTypeView(
    id: 'nt-lapis',
    ankiNum: 1,
    kind: SrsNoteTypeKind.standard,
    name: 'Lapis',
    fields: fields,
    templates: const <SrsTemplateDef>[
      SrsTemplateDef(
        id: 't0',
        name: 'Mining Card',
        ord: 0,
        front: '',
        back: '',
      ),
      SrsTemplateDef(id: 't1', name: 'Reverse', ord: 1, front: '', back: ''),
    ],
    css: '',
    termFieldId: 'f0',
    deletedAt: null,
    builtinKey: null,
    edits: SrsEntityEdits(<String, SrsRegister>{}),
  );
  final List<SrsDeckView> decks = <SrsDeckView>[
    _deck('d-jp', 'Japanese', null),
    _deck('d-mining', 'Mining', 'd-jp'),
    _deck('d-core', 'Core', 'd-jp'),
    for (int n = 1; n <= 5; n++) _deck('d-n$n', 'N$n', 'd-core'),
    _deck('d-default', 'Default', null),
  ];
  final SrsDeckTree tree = SrsDeckTree(decks);
  final List<String> deckIds = <String>[
    'd-mining',
    'd-mining',
    'd-mining',
    for (int n = 1; n <= 5; n++) 'd-n$n',
    'd-default',
  ];
  const List<String> tagPool = <String>[
    'n5', 'n4', 'n3', 'verb::ichidan', 'verb::godan', 'adj', 'fushi', //
    'leech', 'marked', 'anime::jjk', 'novel::mushoku',
  ];
  const SrsDayContext day = SrsDayContext(utcOffsetMin: 540, rolloverHour: 4);
  final int now = DateTime.utc(2026, 10, 18, 3).millisecondsSinceEpoch;
  final int today = day.dayIndexOf(now);

  String word(int len, List<String> alphabet) => <String>[
    for (int i = 0; i < len; i++) alphabet[rng.nextInt(alphabet.length)],
  ].join();

  final Map<String, SrsNoteView> notes = <String, SrsNoteView>{};
  final List<SrsCardSearchSubject> cards = <SrsCardSearchSubject>[];
  final int noteCount = (cardCount / 2).ceil();
  for (int i = 0; i < noteCount; i++) {
    final String expr =
        '${word(1 + rng.nextInt(2), _kanji)}${word(1 + rng.nextInt(2), _kana)}$i';
    final String reading = word(3 + rng.nextInt(3), _kana);
    final String gloss = _english[rng.nextInt(_english.length)];
    final StringBuffer glossary = StringBuffer();
    final int dicts = 1 + rng.nextInt(3);
    final bool inline = rng.nextDouble() < _inlineStyleRate;
    for (int d = 0; d < dicts; d++) {
      final int k = rng.nextInt(styles.length);
      if (inline) {
        glossary.write('<style>${styles[k]}</style>');
      } else {
        glossary.write(
          '<link rel="stylesheet" href="_fushi_style_${k.toRadixString(16).padLeft(40, '0')}.css">',
        );
      }
      glossary.write(
        '<div style="text-align: left;" class="yomitan-glossary"><ol>'
        '<li data-dictionary="Dict$k"><i>(Dict$k)</i> <span>'
        '<ul data-sc-content="glossary"><li>$gloss</li><li>${_english[rng.nextInt(_english.length)]}; '
        '${word(4, _kanji)}</li></ul></span></li></ol></div>',
      );
    }
    final Map<String, String> values = <String, String>{
      'f0': rng.nextDouble() < 0.2 ? '<b>$expr</b>' : expr,
      'f1': '$expr[$reading]',
      'f2': reading,
      'f3': '[sound:fushi_$i.mp3]',
      'f4': '',
      'f5': '<div>$gloss</div>',
      'f6': '${word(6, _kana)}<b>$expr</b>${word(8, _kana)}。',
      'f7': '${word(6, _kana)}<b>$expr[$reading]</b>${word(8, _kana)}。',
      'f8': '[sound:fushi_s_$i.mp3]',
      'f9': rng.nextDouble() < 0.3 ? '<img src="fushi_$i.webp">' : '',
      'f10': glossary.toString(),
      'f11': 'Anime ${rng.nextInt(40)} · ep ${rng.nextInt(24)}',
      'f12': '<ul><li>JPDB: ${rng.nextInt(50000)}</li></ul>',
    };
    final String noteId = 'note-$i';
    final SrsNoteView note = SrsNoteView(
      id: noteId,
      noteTypeId: type.id,
      guid: 'g$i',
      createdAt: now - rng.nextInt(400) * 86400000,
      fields: values,
      tags: <String>[
        for (final String t in tagPool)
          if (rng.nextDouble() < 0.15) t,
      ],
      source: null,
      deckId: null,
      deletedAt: null,
      edits: SrsEntityEdits(<String, SrsRegister>{}),
    );
    notes[noteId] = note;
    final String deck = deckIds[rng.nextInt(deckIds.length)];
    for (int t = 0; t < 2 && cards.length < cardCount; t++) {
      final double r = rng.nextDouble();
      final String queue = r < 0.3
          ? 'new'
          : (r < 0.4 ? 'learning' : (r < 0.95 ? 'review' : 'relearning'));
      final bool fresh = queue == 'new';
      final SrsCardCacheRow row = SrsCardCacheRow(
        id: 'card-$i-$t',
        profileUid: _profile,
        noteId: noteId,
        templateId: 't$t',
        clozeOrd: 0,
        deckId: deck,
        suspended: rng.nextDouble() < 0.05,
        buriedUntilDay: rng.nextDouble() < 0.02 ? today + 1 : null,
        flag: rng.nextDouble() < 0.1 ? 1 + rng.nextInt(7) : 0,
        hidden: false,
        queue: queue,
        dueDay: queue == 'review' ? today + rng.nextInt(60) - 10 : null,
        dueAt: queue == 'learning' || queue == 'relearning'
            ? now + rng.nextInt(7200000) - 3600000
            : null,
        scheduledDays: fresh ? 0 : rng.nextInt(400),
        reps: fresh ? 0 : 1 + rng.nextInt(30),
        lapses: fresh ? 0 : rng.nextInt(5),
        stability: fresh ? null : rng.nextDouble() * 300,
        difficulty: fresh ? null : 1 + rng.nextDouble() * 9,
        scheduler: 'fsrs',
        noteCreatedAt: note.createdAt,
      );
      cards.add(
        SrsCardSearchSubject(
          note: note,
          noteType: type,
          card: row,
          deckName: tree.fullName(deck),
          day: day,
          nowMs: now,
          todayDayIndex: today,
        ),
      );
    }
  }
  return _Corpus(cards, <SrsNoteTypeView>[type], notes, tree, day, now);
}

const List<String> _browseQueries = <String>[
  '食',
  '"Glossary:*to eat*"',
  'deck:Japanese::Mining tag:verb*',
  're:食[あいう]',
  'is:due -is:suspended prop:ivl>=7',
  '"Expression:*語*" OR "Sentence:*語*"',
];

/// 首次搜索分别量的查询：只看状态、限定小字段（Yomitan 查重形状）、限定大字段、未限定字段。
const List<String> _firstQueries = <String>[
  'is:new',
  '"Expression:語12"',
  '"Glossary:*to eat*"',
  '食',
];

/// AnkiConnect 查重（_dupeOrEmpty 第一次请求的路径）：全部笔记首字段一次批量算规范形
/// （之后的请求只重算原文变了的笔记），候选单独算一次，然后整串比较。
int _dupeScan(_Corpus c, String candidate) {
  final List<String> norms = srsDupeNormBatch(<String>[
    for (final SrsNoteView n in c.notes.values) n.field('f0'),
  ]);
  final String first = srsDupeNormBatch(<String>[candidate]).single;
  int hits = 0;
  for (final String n in norms) {
    if (n == first) hits++;
  }
  return hits;
}

int _ms(Stopwatch sw) => sw.elapsedMilliseconds;

/// 量 await 期间当前 isolate 的事件循环最长被占住多久（= 界面卡住的最长一段）。
class _StallProbe {
  final Stopwatch _sw = Stopwatch();
  Timer? _timer;
  int _last = 0;
  int _worst = 0;

  void start() {
    _sw.start();
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final int now = _sw.elapsedMilliseconds;
      if (now - _last > _worst) _worst = now - _last;
      _last = now;
    });
  }

  int stop() {
    _timer?.cancel();
    final int now = _sw.elapsedMilliseconds;
    if (now - _last > _worst) _worst = now - _last;
    return _worst;
  }
}

Future<void> main(List<String> args) async {
  final List<int> sizes = args.isEmpty
      ? <int>[10000, 50000, 100000]
      : <int>[for (final String a in args) int.parse(a)];
  for (final int size in sizes) {
    final Stopwatch gen = Stopwatch()..start();
    final _Corpus c = _generate(size);
    print(
      '== $size cards / ${c.notes.length} notes '
      '(generated in ${_ms(gen)} ms)',
    );
    // 首次搜索（新快照，语料从零建）：各类查询分别量，每个都用全新的快照。
    // sync = 直接 query（字段文本在当前 isolate 上串行编码）；prepare = 浏览页的路径（先 await
    // prepare 并行编码，再 query），后一列是其中同步占住 UI isolate 的部分。
    for (final String q in _firstQueries) {
      final SrsBrowseSnapshot fresh = SrsBrowseSnapshot.fromCards(
        c.cards,
        c.noteTypes,
      );
      final Stopwatch sw = Stopwatch()..start();
      final int hits = (await fresh.query(query: q)).length;
      final int syncMs = _ms(sw);
      final SrsBrowseSnapshot fresh2 = SrsBrowseSnapshot.fromCards(
        c.cards,
        c.noteTypes,
      );
      final Stopwatch sw2 = Stopwatch()..start();
      final _StallProbe probe = _StallProbe()..start();
      await fresh2.prepare(q);
      final int prepMs = _ms(sw2);
      final int stallMs = probe.stop();
      final Stopwatch sw3 = Stopwatch()..start();
      final int hits2 = (await fresh2.query(query: q)).length;
      final int queryMs = _ms(sw3);
      print(
        'first   sync $syncMs ms | prepare $prepMs (UI isolate longest stall '
        '$stallMs) + query $queryMs = ${prepMs + queryMs} ms  '
        'hits=$hits/$hits2  $q',
      );
    }
    final SrsBrowseSnapshot snap = SrsBrowseSnapshot.fromCards(
      c.cards,
      c.noteTypes,
    );
    final Stopwatch build = Stopwatch()..start();
    await snap.query(query: 'is:new');
    print('browse  corpus build + first query: ${_ms(build)} ms');
    for (final String q in _browseQueries) {
      final List<int> runs = <int>[];
      int hits = 0;
      for (int r = 0; r < 3; r++) {
        final Stopwatch sw = Stopwatch()..start();
        hits = (await snap.query(query: q)).length;
        runs.add(_ms(sw));
      }
      print('browse  ${runs.join('/')} ms  hits=$hits  $q');
    }
    final List<int> runs = <int>[];
    int hits = 0;
    for (int r = 0; r < 3; r++) {
      final Stopwatch sw = Stopwatch()..start();
      hits = _dupeScan(c, '<b>語12</b>');
      runs.add(_ms(sw));
    }
    print('dupe    ${runs.join('/')} ms  hits=$hits  (one candidate)');
  }
}
