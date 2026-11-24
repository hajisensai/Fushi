// 拍板 hSZjfrcejt：存量小说出处坐标的一次性后台迁移——按书分批、写完一本记一本（中断后
// 从下一本续跑）、做完不再扫描；制卡历史与 Fushi 复习笔记（链接 href + 结构化出处）都改。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/card_source_relocation_migration.dart';
import 'package:fushi/src/reader/reader_source_relocation.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import '../srs/srs_test_support.dart';

const String _sourceId = '11111111-1111-4111-8111-111111111111';
const String _otherSourceId = '22222222-2222-4222-8222-222222222222';

// 反馈原例：ＳＯＳ 之后的句子。旧（匹配）坐标 (4, 9)，学习单位坐标 (2, 9)。
const String _chapterBody = '<p>ＳＯＳだ。</p><p>もとから鼻白む話だ。『ふざけるな』</p>';

EpubBook _book() => EpubBook(
  title: 'b',
  chapters: <EpubChapter>[
    EpubChapter(
      id: 'c0',
      href: 'c0.xhtml',
      mediaType: 'application/xhtml+xml',
      html: '<html><body>$_chapterBody</body></html>',
    ),
  ],
);

/// 假「后台 isolate」：解压目录 → 内存书。
Future<List<ReaderSourceRelocation>> _relocate(
  String dir,
  List<ReaderSourceRelocationRequest> requests,
) async => relocateReaderSourceSpansInBook(_book(), requests);

CardSourceLink _link({String sourceId = _sourceId, int offset = 4}) =>
    CardSourceLink(
      kind: CardSourceKind.book,
      uid: 'book-1',
      bookKey: 'Book',
      sourceId: sourceId,
      chapterIndex: 0,
      charOffset: offset,
      charLength: 9,
    );

CardSourceRelocationStateFile _stateFile() {
  final Directory dir = Directory.systemTemp.createTempSync('fushi_reloc_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return CardSourceRelocationStateFile(
    File('${dir.path}/$kCardSourceRelocationStateFileName'),
  );
}

void main() {
  test('only the href with the same source ID is rewritten', () {
    final String field =
        '${_link().toHtml(label: '冬期限定')} 00:01 '
        '${_link(sourceId: _otherSourceId).toHtml()}';
    final String next = replaceCardSourceLinkHref(
      field,
      from: _link(),
      to: cardSourceLinkWithSpan(_link(), offset: 2, length: 9),
    );
    final List<CardSourceLink> links = CardSourceLink.fromHtml(next).toList();
    expect(links.map((CardSourceLink l) => l.charOffset), <int>[2, 4]);
    expect(links.first.uid, 'book-1');
    expect(links.first.bookKey, 'Book');
    expect(next, contains('>冬期限定</a> 00:01 '));
  });

  group('runCardSourceRelocationScope', () {
    CardSourceRelocationItem item(
      String? book,
      int offset,
      List<int> sink, {
      bool Function()? interrupted,
    }) => CardSourceRelocationItem(
      bookGroup: book,
      request: ReaderSourceRelocationRequest(
        chapterIndex: 0,
        offset: offset,
        length: 9,
        texts: const <String>['もとから鼻白む話だ。'],
      ),
      write: (int o, int l) async {
        if (interrupted?.call() ?? false) throw StateError('interrupted');
        sink.add(o);
        return true;
      },
    );

    test('resumes after the last finished book and then stays done', () async {
      final CardSourceRelocationStateFile state = _stateFile();
      final List<int> writes = <int>[];
      final List<String> asked = <String>[];
      bool interrupt = true;
      List<CardSourceRelocationItem> items() => <CardSourceRelocationItem>[
        item('/b', 4, writes, interrupted: () => interrupt),
        item('/a', 4, writes),
        item('/a', 2, writes),
        item(null, 4, writes),
      ];

      // 第一次在 /b 的写回上中断（库被关 / 进程被杀）。
      await expectLater(
        runCardSourceRelocationScope(
          scope: 's',
          stateFile: state,
          loadItems: () async => items(),
          relocate: (String dir, List<ReaderSourceRelocationRequest> r) {
            asked.add(dir);
            return _relocate(dir, r);
          },
        ),
        throwsStateError,
      );
      interrupt = false;
      expect(asked, <String>['/a', '/b']);
      expect(writes, <int>[2]);

      asked.clear();
      final CardSourceRelocationReport? report =
          await runCardSourceRelocationScope(
            scope: 's',
            stateFile: state,
            loadItems: () async => items(),
            relocate: (String dir, List<ReaderSourceRelocationRequest> r) {
              asked.add(dir);
              return _relocate(dir, r);
            },
          );
      expect(asked, <String>['/b']);
      expect(writes, <int>[2, 2]);
      expect(
        report,
        const CardSourceRelocationReport(
          relocated: 2,
          verified: 1,
          notLocated: 1,
        ),
      );

      bool loaded = false;
      expect(
        await runCardSourceRelocationScope(
          scope: 's',
          stateFile: state,
          loadItems: () async {
            loaded = true;
            return items();
          },
          relocate: _relocate,
        ),
        isNull,
      );
      expect(loaded, isFalse);
      // 别的范围（另一个 profile）各记各的。
      expect((await state.read('other')).done, isFalse);
    });

    test(
      'a book that fails to parse is skipped for good, not retried forever',
      () async {
        final CardSourceRelocationStateFile state = _stateFile();
        final List<int> writes = <int>[];
        final List<String> asked = <String>[];
        final List<String> failed = <String>[];
        Future<CardSourceRelocationReport?> run() =>
            runCardSourceRelocationScope(
              scope: 's',
              stateFile: state,
              loadItems: () async => <CardSourceRelocationItem>[
                item('/a', 4, writes),
                item('/b', 4, writes),
                item('/c', 4, writes),
              ],
              relocate: (String dir, List<ReaderSourceRelocationRequest> r) {
                asked.add(dir);
                if (dir == '/b') {
                  throw const FileSystemException('chapter file missing');
                }
                return _relocate(dir, r);
              },
              onBookError: (String book, Object e, StackTrace _) =>
                  failed.add(book),
            );

        // 坏掉的 /b 不挡住排在它后面的 /c。
        expect(
          await run(),
          const CardSourceRelocationReport(relocated: 2, notLocated: 1),
        );
        expect(asked, <String>['/a', '/b', '/c']);
        expect(failed, <String>['/b']);
        expect(writes, <int>[2, 2]);
        // 记为做完：下次启动不再重新解析它。
        asked.clear();
        expect(await run(), isNull);
        expect(asked, isEmpty);
      },
    );

    test(
      'a write refused by a concurrent edit counts as not located',
      () async {
        final CardSourceRelocationReport? report =
            await runCardSourceRelocationScope(
              scope: 's',
              stateFile: _stateFile(),
              loadItems: () async => <CardSourceRelocationItem>[
                CardSourceRelocationItem(
                  bookGroup: '/a',
                  request: const ReaderSourceRelocationRequest(
                    chapterIndex: 0,
                    offset: 4,
                    length: 9,
                    texts: <String>['もとから鼻白む話だ。'],
                  ),
                  write: (int o, int l) async => false,
                ),
              ],
              relocate: _relocate,
            );
        expect(report, const CardSourceRelocationReport(notLocated: 1));
      },
    );
  });

  test('mined sentence history is relocated once, then verifies', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    Future<void> add({required String source, int? offset, String? key}) =>
        db.addMinedSentence(
          source: source,
          dateKey: '2026-11-01',
          expression: '鼻白む',
          sentence: 'もとから鼻白む話だ。',
          bookKey: key,
          sectionIndex: offset == null ? null : 0,
          normCharOffset: offset,
          normCharLength: offset == null ? null : 9,
        );
    await add(source: kStatSourceBook, offset: 4, key: 'Book');
    await add(source: kStatSourceBook, offset: 4, key: 'Gone');
    await add(source: kStatSourceBook, key: 'Book');
    await add(source: 'video');

    Future<CardSourceRelocationReport?> run() => runCardSourceRelocationScope(
      scope: kCardSourceRelocationHistoryScope,
      stateFile: _stateFile(),
      loadItems: () => loadMinedSentenceRelocationItems(
        db,
        extractDirOf: (String key) async => key == 'Book' ? '/book' : null,
      ),
      relocate: _relocate,
    );

    expect(
      await run(),
      const CardSourceRelocationReport(relocated: 1, notLocated: 1),
    );
    final Map<String?, int?> offsets = <String?, int?>{
      for (final MinedSentenceRow r in await db.getAllMinedSentences())
        if (r.normCharOffset != null) r.bookKey: r.normCharOffset,
    };
    expect(offsets, <String?, int?>{'Book': 2, 'Gone': 4});
    // 新状态文件从头再跑：改过的那条核对通过，不再改。
    expect(
      await run(),
      const CardSourceRelocationReport(verified: 1, notLocated: 1),
    );
  });

  group('Fushi review notes', () {
    late FushiDatabase db;
    late SrsDbStore store;
    String fid(String key) => srsLapisFieldId(kSrsTestProfile, key);

    setUp(() async {
      (db, store) = await openSrsTestStore();
    });

    tearDown(() async {
      await db.close();
    });

    test('rewrites the link href and the structured source together', () async {
      final String deck = await store.createDeck('JP');
      final String note = await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        deckId: deck,
        fieldsById: <String, String>{
          fid('Expression'): '鼻白む',
          fid('Sentence'): 'もとから<b>鼻白む</b>話だ。',
          fid('MiscInfo'): _link().toHtml(label: '冬期限定'),
        },
        source: SrsSourceRef.book(
          bookKey: 'Book',
          sectionIndex: 0,
          charStart: 4,
          charLength: 9,
          title: '冬期限定',
        ),
      );
      // 不是书的出处不碰。
      await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        deckId: deck,
        fieldsById: <String, String>{fid('Expression'): 'kind=bookmark'},
      );

      Future<CardSourceRelocationReport?> run() => runCardSourceRelocationScope(
        scope: cardSourceRelocationSrsScope(store.profileUid),
        stateFile: _stateFile(),
        loadItems: () => loadSrsNoteRelocationItems(
          store,
          extractDirOf: (CardSourceLink link) async => '/book',
        ),
        relocate: _relocate,
      );

      expect(await run(), const CardSourceRelocationReport(relocated: 1));
      final SrsNoteView view = (await store.notes(<String>[note]))[note]!;
      final String misc = view.fields.entries
          .firstWhere((MapEntry<String, String> e) => e.value.contains('fushi'))
          .value;
      final CardSourceLink link = CardSourceLink.fromHtml(misc).single;
      expect(link.charOffset, 2);
      expect(link.charLength, 9);
      expect(link.sourceId, _sourceId);
      expect(misc, contains('>冬期限定</a>'));
      expect(view.source?.data['start'], 2);
      expect(view.source?.data['len'], 9);
      expect(view.source?.data['title'], '冬期限定');

      expect(await run(), const CardSourceRelocationReport(verified: 1));
    });

    // 同一字段里两条书籍出处：先改写的那条让字段变了，后一条仍要按自己的链接判、照样改写，
    // 不能因为「字段和扫描时不一样」被判成并发改动、永远留着旧坐标。
    test('every book link in one field is rewritten', () async {
      final String deck = await store.createDeck('JP');
      final String note = await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        deckId: deck,
        fieldsById: <String, String>{
          fid('Expression'): '鼻白む',
          fid('Sentence'): 'もとから<b>鼻白む</b>話だ。',
          fid('MiscInfo'):
              '${_link().toHtml(label: 'a')} '
              '${_link(sourceId: _otherSourceId).toHtml(label: 'b')} '
              '${_link().toHtml(label: 'a2')}',
        },
      );
      final CardSourceRelocationReport? report =
          await runCardSourceRelocationScope(
            scope: cardSourceRelocationSrsScope(store.profileUid),
            stateFile: _stateFile(),
            loadItems: () => loadSrsNoteRelocationItems(
              store,
              extractDirOf: (CardSourceLink link) async => '/book',
            ),
            relocate: _relocate,
          );
      // 重复的同一条链接只算一项、一次全换掉。
      expect(report, const CardSourceRelocationReport(relocated: 2));
      final SrsNoteView view = (await store.notes(<String>[note]))[note]!;
      final List<CardSourceLink> links = CardSourceLink.fromHtml(
        view.field(fid('MiscInfo')),
      ).toList();
      expect(links.map((CardSourceLink l) => l.charOffset), <int>[2, 2, 2]);
      expect(links.map((CardSourceLink l) => l.sourceId), <String>[
        _sourceId,
        _otherSourceId,
        _sourceId,
      ]);
    });

    test('a link edited after the scan is not overwritten', () async {
      final String deck = await store.createDeck('JP');
      final String note = await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        deckId: deck,
        fieldsById: <String, String>{
          fid('Sentence'): 'もとから<b>鼻白む</b>話だ。',
          fid('MiscInfo'): _link().toHtml(label: 'a'),
        },
      );
      final List<CardSourceRelocationItem> items =
          await loadSrsNoteRelocationItems(
            store,
            extractDirOf: (CardSourceLink link) async => '/book',
          );
      final String edited = _link(offset: 7).toHtml(label: 'a');
      await store.editFields(SrsEntityKind.note, note, <String, Object?>{
        SrsFieldKeys.noteField(fid('MiscInfo')): edited,
      });
      expect(await items.single.write(2, 9), isFalse);
      final SrsNoteView view = (await store.notes(<String>[note]))[note]!;
      expect(view.field(fid('MiscInfo')), edited);
    });
  });
}
