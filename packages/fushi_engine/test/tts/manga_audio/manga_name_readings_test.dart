import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/web_search.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/manga_audio/manga_name_readings.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

/// 漫画有声「查人名读法」（拍板 TW9ete_FHX 第三期）：只收页面印着的注音 / 搜索结果
/// 写明的读法，出处只作建议，待复核条目不生效。

MokuroBlock _v(
  double l,
  double t,
  double r,
  double b,
  List<String> lines, {
  double fontSize = 40,
}) => MokuroBlock(
  rectangle: MokuroRect.fromLTRB(l, t, r, b),
  isVertical: true,
  fontSize: fontSize,
  zIndex: 0,
  lines: lines,
);

/// 竖排一列「豊川祥子です」（6 字、字距 40），右侧注音「とがわさきこ」盖住前四个字。
List<MokuroBlock> _introPage() => <MokuroBlock>[
  _v(600, 100, 640, 340, <String>['豊川祥子です']),
  _v(642, 100, 660, 260, <String>['とがわさきこ'], fontSize: 18),
];

/// 没有注音、只出现「祥子ちゃん」的页。
List<MokuroBlock> _plainPage() => <MokuroBlock>[
  _v(600, 100, 640, 300, <String>['祥子ちゃん']),
];

const CastNameEvidence _rubyA = CastNameEvidence(
  origin: CastNameEvidenceOrigin.ruby,
  reading: 'さきこ',
  page: 3,
  volume: '1巻',
);

void main() {
  group('CastTextSubstitution evidence', () {
    test('JSON 往返保留出处；改写法时出处作废', () {
      const CastTextSubstitution e = CastTextSubstitution.name(
        written: '祥子',
        reading: '',
        character: '豊川祥子',
        evidence: <CastNameEvidence>[
          _rubyA,
          CastNameEvidence(
            origin: CastNameEvidenceOrigin.official,
            reading: 'サキコ',
            url: 'https://example.com/chara',
            byAi: true,
          ),
        ],
      );
      final CastTextSubstitution back = CastTextSubstitution.fromJson(
        e.toJson(),
      )!;
      expect(
        back.evidence.map((CastNameEvidence x) => x.key).toList(),
        <String>[for (final CastNameEvidence x in e.evidence) x.key],
      );
      expect(back.evidence.last.byAi, isTrue);
      expect(back.copyWith(enabled: false).evidence, hasLength(2));
      expect(back.copyWith(source: '祥').evidence, isEmpty);
    });

    test('出处一致（平 / 片假名不算差别）给建议；冲突不给建议', () {
      const CastTextSubstitution agree = CastTextSubstitution.name(
        written: '祥子',
        reading: '',
        evidence: <CastNameEvidence>[
          _rubyA,
          CastNameEvidence(
            origin: CastNameEvidenceOrigin.official,
            reading: 'サキコ',
            url: 'https://example.com/a',
          ),
        ],
      );
      expect(agree.suggestedReading, 'さきこ');
      expect(agree.hasConflictingEvidence, isFalse);

      final CastTextSubstitution conflict = agree.copyWith(
        evidence: <CastNameEvidence>[
          _rubyA,
          const CastNameEvidence(
            origin: CastNameEvidenceOrigin.ruby,
            reading: 'しょうこ',
            page: 9,
            volume: '2巻',
          ),
        ],
      );
      expect(conflict.suggestedReading, isNull);
      expect(conflict.hasConflictingEvidence, isTrue);
      expect(conflict.evidenceReadings, <String>['さきこ', 'しょうこ']);
    });

    test('有建议但没采用的条目不进合成；采用后才念读法', () {
      const CastTextSubstitution pending = CastTextSubstitution.name(
        written: '祥子',
        reading: '',
        evidence: <CastNameEvidence>[_rubyA],
      );
      expect(
        applyCastSpokenSubstitutions('祥子ちゃん', <CastTextSubstitution>[pending]),
        '祥子ちゃん',
      );
      final CastTextSubstitution accepted = pending.copyWith(
        replacement: pending.suggestedReading,
      );
      expect(
        applyCastSpokenSubstitutions('祥子ちゃん', <CastTextSubstitution>[accepted]),
        'さきこちゃん',
      );
      // 显示层仍是原文。
      expect(
        applyCastSubstitutions('祥子ちゃん', <CastTextSubstitution>[accepted]),
        '祥子ちゃん',
      );
    });

    test('evidenceForReading 只认与当前读法一致的出处（手填别的读法不挂出处）', () {
      const CastTextSubstitution pending = CastTextSubstitution.name(
        written: '祥子',
        reading: '',
        evidence: <CastNameEvidence>[_rubyA],
      );
      expect(pending.evidenceForReading, isNull);
      expect(
        pending.copyWith(replacement: 'サキコ').evidenceForReading?.key,
        _rubyA.key,
      );
      expect(pending.copyWith(replacement: 'しょうこ').evidenceForReading, isNull);
    });

    test('normalizeCastNameReading 去空格与・，只收假名', () {
      expect(normalizeCastNameReading('とがわ さきこ'), 'とがわさきこ');
      expect(normalizeCastNameReading('トガワ・サキコ'), 'トガワサキコ');
      expect(normalizeCastNameReading('Sakiko'), isNull);
      expect(normalizeCastNameReading('祥子'), isNull);
      expect(normalizeCastNameReading(''), isNull);
    });
  });

  group('mergeCastNameEvidence', () {
    test('只并出处不动读法；角色表里的名字有出处才补成待复核条目', () {
      final ({List<CastTextSubstitution> table, int suggested}) r =
          mergeCastNameEvidence(
            table: const <CastTextSubstitution>[
              CastTextSubstitution(source: 'セーラー服', replacement: '制服'),
              CastTextSubstitution.name(written: '祥子', reading: ''),
              CastTextSubstitution.name(written: '燈', reading: 'ともり'),
            ],
            found: <String, List<CastNameEvidence>>{
              '祥子': <CastNameEvidence>[_rubyA, _rubyA],
              '燈': const <CastNameEvidence>[
                CastNameEvidence(
                  origin: CastNameEvidenceOrigin.ruby,
                  reading: 'ともり',
                  page: 1,
                  volume: '1巻',
                ),
              ],
              '豊川祥子': const <CastNameEvidence>[
                CastNameEvidence(
                  origin: CastNameEvidenceOrigin.ruby,
                  reading: 'とがわさきこ',
                  page: 3,
                  volume: '1巻',
                ),
              ],
            },
            addFrom: const <TtsCastCharacter>[
              TtsCastCharacter(name: '豊川祥子', aliases: <String>['祥子', '祥']),
            ],
          );
      expect(
        r.table.map((CastTextSubstitution e) => e.source).toList(),
        <String>['セーラー服', '祥子', '燈', '豊川祥子'],
      );
      // 「祥」没有出处，不补；重复的出处只记一次。
      expect(r.table[1].evidence, hasLength(1));
      expect(r.table[1].replacement, '');
      expect(r.table[1].suggestedReading, 'さきこ');
      expect(r.table[2].replacement, 'ともり');
      expect(r.table[3].isPendingName, isTrue);
      expect(r.table[3].character, '豊川祥子');
      // 新有建议的待复核条目：祥子、豊川祥子（燈已有读法不算）。
      expect(r.suggested, 2);
    });
  });

  group('页面注音', () {
    test('注音恰好注在写法上才算，记卷名与页码；别处出现不算', () {
      final Map<String, List<CastNameEvidence>> found =
          collectMangaNameRubyEvidence(
            volumes: <MangaNameReadingVolume>[
              (
                label: '1巻',
                pages: <List<MokuroBlock>>[_plainPage(), _introPage()],
              ),
            ],
            written: <String>['豊川祥子', '祥子'],
          );
      expect(found.keys, <String>['豊川祥子']);
      final CastNameEvidence ev = found['豊川祥子']!.single;
      expect(ev.origin, CastNameEvidenceOrigin.ruby);
      expect(ev.reading, 'とがわさきこ');
      expect(ev.page, 2);
      expect(ev.volume, '1巻');
      expect(ev.byAi, isFalse);
    });

    test('首次出现页按名字轮流取、去重升序', () {
      final Map<String, List<int>> first = mangaNameFirstPages(
        <List<MokuroBlock>>[_plainPage(), _introPage(), _plainPage()],
        <String>['祥子', '豊川祥子', '燈'],
      );
      expect(first, <String, List<int>>{
        '祥子': <int>[0, 1],
        '豊川祥子': <int>[1],
        '燈': <int>[],
      });
      expect(mangaNameReadingPages(first), <int>[0, 1]);
    });
  });

  group('parseMangaNameReadingReply', () {
    Map<String, List<CastNameEvidence>>? parse(String reply) =>
        parseMangaNameReadingReply(
          reply,
          names: <String>{'祥子', '祥', '燈'},
          sentPages: <int>{3},
          sentUrls: <String>{'https://example.com/chara'},
          volume: '2巻',
        );

    test('页码是发过的页 / URL 是发过的结果才收；猜的、编的都丢', () {
      final Map<String, List<CastNameEvidence>> got = parse('''
{"readings":[
  {"name":"祥子","reading":"さきこ","page":3},
  {"name":"祥","reading":"さき","url":"https://example.com/chara"},
  {"name":"燈","reading":"ともり","page":7},
  {"name":"燈","reading":"あかり","url":"https://fake.example/x"},
  {"name":"燈","reading":"ともり"},
  {"name":"立希","reading":"りっき","page":3},
  {"name":"祥子","reading":"Sakiko","page":3}
]}''')!;
      expect(got.keys, unorderedEquals(<String>['祥子', '祥']));
      final CastNameEvidence a = got['祥子']!.single;
      expect(a.origin, CastNameEvidenceOrigin.ruby);
      expect(a.page, 3);
      expect(a.volume, '2巻');
      expect(a.byAi, isTrue);
      final CastNameEvidence b = got['祥']!.single;
      expect(b.origin, CastNameEvidenceOrigin.official);
      expect(b.url, 'https://example.com/chara');
    });

    test('不是约定 JSON 返回 null；空列表返回空', () {
      expect(parse('sorry'), isNull);
      expect(parse('{"readings":[]}'), isEmpty);
    });
  });

  group('MangaNameReadingFinder', () {
    test('页面注音找到的名字不进 AI；AI 只看剩下的名字、带页图与搜索结果', () async {
      final List<List<AiChatMessage>> asked = <List<AiChatMessage>>[];
      final List<int> loadedPages = <int>[];
      final List<String> queries = <String>[];
      final MangaNameReadingResult r = await MangaNameReadingFinder(
        workTitle: 'MyGO',
        names: const <MangaNameToRead>[
          (written: '豊川祥子', character: '豊川祥子'),
          (written: '祥子', character: '豊川祥子'),
        ],
        volumes: <MangaNameReadingVolume>[
          (label: '1巻', pages: <List<MokuroBlock>>[_plainPage(), _introPage()]),
        ],
        currentVolume: 0,
        ask: (List<AiChatMessage> messages) async {
          asked.add(messages);
          return '{"readings":[{"name":"祥子","reading":"さきこ","page":2},'
              '{"name":"豊川祥子","reading":"しょうこ","page":2}]}';
        },
        imageFor: (int page) async {
          loadedPages.add(page);
          return const AiChatImage(bytes: <int>[1], mimeType: 'image/jpeg');
        },
        search: (String query) async {
          queries.add(query);
          return <WebSearchHit>[
            WebSearchHit(
              title: '豊川祥子 | MyGO',
              url: Uri.parse('https://example.com/chara'),
              snippet: '豊川祥子（とがわ さきこ）',
            ),
          ];
        },
      ).run();
      expect(asked, hasLength(1));
      final String user = asked.single.last.content;
      expect(user, contains('"祥子"'));
      expect(user, isNot(contains('- "豊川祥子"')));
      expect(user, contains('https://example.com/chara'));
      expect(loadedPages, <int>[0, 1]);
      expect(queries, <String>['MyGO 豊川祥子 読み方']);
      // 豊川祥子 来自 OCR 注音（AI 回的同名条目不在待查名单里，被丢弃）。
      expect(r.evidence['豊川祥子']!.single.byAi, isFalse);
      expect(r.evidence['豊川祥子']!.single.reading, 'とがわさきこ');
      expect(r.evidence['祥子']!.single.byAi, isTrue);
      expect(r.failure, isNull);
    });

    test('没配 AI 只做页面注音；AI 失败保留页面注音结果并带短码', () async {
      final MangaNameReadingResult noAi = await MangaNameReadingFinder(
        workTitle: 'MyGO',
        names: const <MangaNameToRead>[
          (written: '豊川祥子', character: null),
          (written: '祥子', character: null),
        ],
        volumes: <MangaNameReadingVolume>[
          (label: '1巻', pages: <List<MokuroBlock>>[_introPage()]),
        ],
        currentVolume: 0,
      ).run();
      expect(noAi.evidence.keys, <String>['豊川祥子']);
      expect(noAi.failure, isNull);

      final MangaNameReadingResult failed = await MangaNameReadingFinder(
        workTitle: 'MyGO',
        names: const <MangaNameToRead>[
          (written: '豊川祥子', character: null),
          (written: '祥子', character: null),
        ],
        volumes: <MangaNameReadingVolume>[
          (label: '1巻', pages: <List<MokuroBlock>>[_plainPage(), _introPage()]),
        ],
        currentVolume: 0,
        ask: (List<AiChatMessage> messages) async =>
            throw const AiChatFailure('http_401'),
        imageFor: (int page) async =>
            const AiChatImage(bytes: <int>[1], mimeType: 'image/jpeg'),
      ).run();
      expect(failed.evidence.keys, <String>['豊川祥子']);
      expect(failed.failure, 'http_401');
    });
  });
}
