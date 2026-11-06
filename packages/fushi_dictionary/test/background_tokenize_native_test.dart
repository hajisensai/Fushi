import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_dictionary/src/language/implementations/japanese_language.dart';

/// HBK-AUDIT-009：生产的后台分词路径（[FushiDicts.tokenizeWithReadingsInBackground] /
/// [JapaneseLanguage.textsToWordsWithReadingsInBackground]）在真原生库上的端到端。
///
/// [background_borrow_test] 用假句柄钉 Dart 侧次序、ctest `handle_lifecycle_concurrency_test`
/// 用真线程钉原生引用计数；这一组补上两者之间的那段：后台 isolate 里重建绑定、带库路径、
/// 闭包只捕获地址——这些改坏了前两组照样全绿。
///
/// 需要构建好的 fushidicts_ffi 动态库：设 `FUSHI_DICTS_LIB=<绝对路径>`（与
/// packages/fushi_server/test/dictionary_host_test.dart 同一个变量），没有时整组 skip
/// 并说明原因。变形表从仓库 `fushi/assets/transforms` 读。
void main() {
  final String? lib = Platform.environment['FUSHI_DICTS_LIB'];
  final bool haveLib = lib != null && lib.isNotEmpty && File(lib).existsSync();

  group(
    '后台分词（真原生库）',
    () {
      late Directory root;
      late String dictDir;
      late String text;

      setUpAll(() async {
        FushiDicts.nativeLibraryPath = lib;
        await FushiDicts.preloadTransformsFrom(
          (String key) => File('../../fushi/$key').readAsString(),
        );
        root = Directory.systemTemp.createTempSync('fushi_bg_tokenize');
        final List<String> words = <String>[
          for (int i = 0; i < 200; i++)
            '漢${String.fromCharCode(0x3042 + i % 80)}'
                '${String.fromCharCode(0x3042 + (i * 7) % 80)}',
        ];
        final Archive archive = Archive();
        void add(String name, String content) {
          final List<int> bytes = utf8.encode(content);
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }

        add('index.json', '{"title":"BgTokenize","format":3,"revision":"1"}');
        add(
          'term_bank_1.json',
          jsonEncode(<Object>[
            for (final String w in words)
              <Object>[
                w,
                'よみ',
                '',
                '',
                0,
                <String>['g'],
                0,
                '',
              ],
          ]),
        );
        final File zip = File('${root.path}/d.zip')
          ..writeAsBytesSync(ZipEncoder().encode(archive)!);
        final FushiImportResult imported = await FushiDicts.importDictionary(
          zip.path,
          '${root.path}/out',
        );
        expect(imported.success, isTrue, reason: imported.error);
        dictDir = '${root.path}/out/${imported.title}';
        FushiDicts.initializeTyped(termPaths: <String>[dictDir]);
        final StringBuffer sb = StringBuffer();
        for (int i = 0; sb.length < 8000; i++) {
          sb
            ..write(words[(i * 37) % words.length])
            ..write('は');
        }
        text = sb.toString();
      });

      tearDownAll(() {
        FushiDicts.disposeInstance();
        try {
          root.deleteSync(recursive: true);
        } on FileSystemException {
          // 临时目录清理失败不影响结论。
        }
      });

      test('后台结果与同步切分逐位相同，且在命名的后台 isolate 上算', () async {
        final List<int> sync = FushiDicts.instance.tokenizeLengths(text)!;
        FushiDicts.initializeTyped(termPaths: <String>[dictDir]); // 冷缓存
        final List<({List<int> lengths, List<String> readings})?>? bg =
            await FushiDicts.instance.tokenizeWithReadingsInBackground(<String>[
              text,
              '',
              '漢',
            ]);
        expect(bg![0]!.lengths, sync);
        expect(bg[0]!.readings, hasLength(sync.length));
        expect(bg[0]!.readings.where((String r) => r == 'よみ'), isNotEmpty);
        expect(bg[1]!.lengths, isEmpty);
        expect(bg[2]!.lengths, <int>[1]);
        expect(
          debugLastBackgroundTokenizeIsolate,
          kBackgroundTokenizeIsolateName,
        );

        final List<List<({String text, String reading})>> words =
            await JapaneseLanguage.instance
                .textsToWordsWithReadingsInBackground(<String>[
                  text.substring(0, 30),
                ]);
        expect(words.single.map((s) => s.text).join(), text.substring(0, 30));
      });

      test('分词在飞时重载（旧实例 dispose）结果照样正确', () async {
        final List<int> sync = FushiDicts.instance.tokenizeLengths(text)!;
        for (int round = 0; round < 5; round++) {
          final Future<List<({List<int> lengths, List<String> readings})?>?> f =
              FushiDicts.instance.tokenizeWithReadingsInBackground(<String>[
                text,
              ]);
          FushiDicts.initializeTyped(termPaths: <String>[dictDir]);
          expect((await f)![0]!.lengths, sync, reason: 'round $round');
        }
      });

      test('已 dispose 的实例借不到句柄，返回 null', () async {
        final FushiDicts old = FushiDicts.instance;
        FushiDicts.initializeTyped(termPaths: <String>[dictDir]);
        expect(
          await old.tokenizeWithReadingsInBackground(<String>[text]),
          isNull,
        );
      });

      test('释放映射要等后台借用归还（BUG-1756）', () async {
        final File mapped = File('$dictDir/hash.table');
        final List<int> bytes = mapped.readAsBytesSync();
        final Future<Object?> inFlight = FushiDicts.instance
            .tokenizeWithReadingsInBackground(<String>[text]);
        // 借用在上面那次调用里已同步 retain：旧句柄此刻必然还映射着文件。
        FushiDicts.releaseAllMappings();
        if (Platform.isWindows) {
          expect(
            () => mapped.writeAsBytesSync(bytes),
            throwsA(isA<FileSystemException>()),
            reason: 'retired-but-borrowed handle still maps the file',
          );
        }
        await inFlight;

        FushiDicts.initializeTyped(termPaths: <String>[dictDir]);
        final Future<Object?> again = FushiDicts.instance
            .tokenizeWithReadingsInBackground(<String>[text]);
        await FushiDicts.withMappingsReleased(() async {
          mapped.writeAsBytesSync(bytes); // 映射已解除：覆盖写成功
        });
        await again;
      });

      test('作用域内排期 + 查词不会把词典装回引擎；作用域结束后照常结算', () async {
        final File mapped = File('$dictDir/hash.table');
        final List<int> bytes = mapped.readAsBytesSync();
        FushiDicts.initializeTyped(termPaths: <String>[dictDir]);
        final List<int> loaded = FushiDicts.instance.tokenizeLengths(text)!;
        await FushiDicts.withMappingsReleased(() async {
          // 元数据写入在删 / 覆盖途中排期，紧接着一次查词：以前这里就把词典装回来了。
          FushiDicts.scheduleTyped(termPaths: <String>[dictDir]);
          expect(
            FushiDicts.instance.tokenizeLengths(text),
            isNot(loaded),
            reason: '作用域内引擎必须保持为空',
          );
          await Future<void>.delayed(Duration.zero);
          mapped.writeAsBytesSync(bytes); // Windows：装回来的话这里撞 1224
        });
        expect(FushiDicts.hasPendingDicts, isTrue);
        expect(FushiDicts.instance.tokenizeLengths(text), loaded);
      });
    },
    skip: haveLib ? false : '没有 fushidicts_ffi 动态库（设 FUSHI_DICTS_LIB 指向构建好的库）',
  );

  _backgroundLookupGroup(lib, haveLib);
  _redirectFlagMigrationGroup(lib, haveLib);
}

/// [FushiDicts.ensureRedirectFlags]：存量词典补写 redirect_glossary.flag。真原生库，
/// 缺库直接失败（需要带 `fushidicts_ensure_redirect_flag` 导出的新库）。
void _redirectFlagMigrationGroup(String? lib, bool haveLib) {
  group('redirect 标记迁移（真原生库）', () {
    // 可空而非 late：缺库时 setUpAll 第一行就失败，tearDownAll 照样会跑，读未初始化的
    // late 会抛 LateInitializationError，把真正的失败原因（缺库）盖在后面。
    Directory? root;
    late String withRedirect;
    late String plain;

    String row(String expr, Object glossary) =>
        jsonEncode(<Object>[expr, '', '', '', 0, glossary, 0, '']);

    Future<String> importBank(String title, List<String> rows) async {
      final Archive archive = Archive();
      void add(String name, String content) {
        final List<int> bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add('index.json', '{"title":"$title","format":3,"revision":"1"}');
      add('term_bank_1.json', '[${rows.join(',')}]');
      final String base = root!.path;
      final File zip = File('$base/$title.zip')
        ..writeAsBytesSync(ZipEncoder().encode(archive)!);
      final FushiImportResult imported = await FushiDicts.importDictionary(
        zip.path,
        '$base/out',
      );
      expect(imported.success, isTrue, reason: imported.error);
      return '$base/out/${imported.title}';
    }

    File flagOf(String dir) => File('$dir/redirect_glossary.flag');

    setUpAll(() async {
      expect(
        haveLib,
        isTrue,
        reason: '需要 fushidicts_ffi 动态库：设 FUSHI_DICTS_LIB 指向构建好的库',
      );
      FushiDicts.nativeLibraryPath = lib;
      root = Directory.systemTemp.createTempSync('fushi_redirect_flag');
      withRedirect = await importBank('RedirectDict', <String>[
        row('instead of somebody', <String>['definition']),
        row('instead of', <Object>[
          <Object>[
            'instead of somebody',
            <String>['Redirected from instead of'],
          ],
        ]),
      ]);
      plain = await importBank('PlainDict', <String>[
        row('instead', <String>['definition']),
      ]);
    });

    tearDownAll(() {
      try {
        root?.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录清理失败不影响结论。
      }
    });

    test('缺标记的存量词典被补写；已有有效标记的不重写', () async {
      final int redirectSize = File('$withRedirect/blobs.bin').lengthSync();
      final int plainSize = File('$plain/blobs.bin').lengthSync();
      // 模拟导入端还不写标记时代的存量词典。
      flagOf(withRedirect).deleteSync();
      flagOf(plain).deleteSync();

      final FushiRedirectFlagReport first =
          await FushiDicts.ensureRedirectFlags(<String>[
            withRedirect,
            plain,
            '${root!.path}/out/NoSuchDict',
          ]);
      expect(first.results, <String, int>{
        withRedirect: 1,
        plain: 0,
      }, reason: '不存在的目录跳过，不进结果');
      expect(first.deferred, isEmpty);
      expect(flagOf(withRedirect).readAsStringSync(), '1 $redirectSize\n');
      expect(flagOf(plain).readAsStringSync(), '0 $plainSize\n');

      final DateTime stamp = flagOf(withRedirect).lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final FushiRedirectFlagReport second =
          await FushiDicts.ensureRedirectFlags(<String>[withRedirect]);
      expect(second.results, <String, int>{withRedirect: 1});
      expect(
        flagOf(withRedirect).lastModifiedSync(),
        stamp,
        reason: '已有与 blobs.bin 大小一致的标记：原生侧直接读，不重扫、不重写',
      );
    });

    test('与删 / 覆盖词典串行：作用域等在跑的扫描结束；作用域内不开新扫描', () async {
      flagOf(withRedirect).deleteSync();
      bool scanDone = false;
      final Future<FushiRedirectFlagReport> scanning =
          FushiDicts.ensureRedirectFlags(<String>[withRedirect]).then((
            FushiRedirectFlagReport r,
          ) {
            scanDone = true;
            return r;
          });
      // 等扫描真正登记进账本（前面有一次异步 exists 检查），再进映射释放作用域。
      while (FushiDicts.debugBackgroundBorrowsInFlight == 0 && !scanDone) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(scanDone, isFalse, reason: '整本扫描不可能在一次事件循环内跑完');
      await FushiDicts.withMappingsReleased(() async {
        expect(
          flagOf(withRedirect).existsSync(),
          isTrue,
          reason: '作用域开始前在跑的扫描必须已经结束（账本等到了它）',
        );
        final FushiRedirectFlagReport inside =
            await FushiDicts.ensureRedirectFlags(<String>[withRedirect, plain]);
        expect(inside.results, isEmpty);
        expect(inside.deferred, <String>[
          withRedirect,
          plain,
        ], reason: '删 / 覆盖进行中不开始新的扫描');
      });
      expect((await scanning).results, <String, int>{withRedirect: 1});
    });
  });
}

/// 后台查词（[FushiDicts.lookupInBackground]）在真原生库上的端到端：结果与旧的
/// UI isolate 同步路径逐字段相同、引擎换实例后后台缓存失效、在飞查询与重载并发、
/// 同 lane 未开始的请求被取代、释放映射要等后台查词归还句柄。
///
/// 与上一组不同，这一组**缺原生库直接失败**而不是 skip：查词热路径整个搬进了后台，
/// 这组没跑就等于后台路径完全没验证过。
void _backgroundLookupGroup(String? lib, bool haveLib) {
  group('后台查词（真原生库）', () {
    // 可空而非 late：同上一组，缺库时 tearDownAll 不能再抛 LateInitializationError。
    Directory? root;
    late String dictA;
    late String dictB;
    late String kanjiDict;

    Future<String> importDict(String title, Map<String, Object> banks) async {
      final Archive archive = Archive();
      void add(String name, String content) {
        final List<int> bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add(
        'index.json',
        jsonEncode(<String, Object>{
          'title': title,
          'format': 3,
          'revision': '1',
        }),
      );
      banks.forEach((String name, Object rows) => add(name, jsonEncode(rows)));
      final String base = root!.path;
      final File zip = File('$base/$title.zip')
        ..writeAsBytesSync(ZipEncoder().encode(archive)!);
      final FushiImportResult imported = await FushiDicts.importDictionary(
        zip.path,
        '$base/out',
      );
      expect(imported.success, isTrue, reason: imported.error);
      return '$base/out/${imported.title}';
    }

    List<Object> term(
      String expression,
      String reading,
      String rules,
      String gloss,
    ) => <Object>[
      expression,
      reading,
      'n',
      rules,
      0,
      <String>[gloss],
      0,
      '',
    ];

    void loadAll() => FushiDicts.initializeTyped(
      termPaths: <String>[dictA, dictB],
      kanjiPaths: <String>[kanjiDict],
    );

    /// 旧实现（app_model 的 UI isolate 同步路径）的原样复刻：同步 lookup → 汉字桶 →
    /// buildResultFromLookup → buildPopupJsonFromLookup → withKanjiResults；没有词条
    /// 时退成纯汉字结果。
    DictionarySearchResult? syncReference(FushiLookupRequest r) {
      final List<FushiKanjiResult> kanji = r.includeKanji
          ? FushiDicts.instance.queryKanji(r.text)
          : const <FushiKanjiResult>[];
      final List<FushiLookupResult> ffi = FushiDicts.instance.lookup(
        r.text,
        maxResults: r.maxResults,
      );
      DictionarySearchResult? result;
      if (ffi.isNotEmpty) {
        result = buildResultFromLookup(
          searchTerm: r.text,
          results: ffi,
          maximumTerms: r.maxResults,
          dictionaryOrder: r.dictionaryOrder,
          hiddenDictionaries: r.hiddenDictionaries,
        );
        result.popupJson = buildPopupJsonFromLookup(
          results: ffi,
          maximumTerms: r.maxResults,
          hiddenDictionaries: r.hiddenDictionaries,
          dictionaryOrder: r.dictionaryOrder,
        );
        result = result.withKanjiResults(kanji);
      }
      if (result != null && result.entries.isNotEmpty) return result;
      if (kanji.isNotEmpty) {
        return DictionarySearchResult(searchTerm: r.text, kanjiResults: kanji);
      }
      return null;
    }

    void expectSameResult(
      DictionarySearchResult? actual,
      DictionarySearchResult? expected,
      String reason,
    ) {
      if (expected == null) {
        expect(actual, isNull, reason: reason);
        return;
      }
      expect(actual, isNotNull, reason: reason);
      // toJson 覆盖 searchTerm / bestLength / truncated / headwordCount /
      // scrollPosition / 每条 entry 的全部字段（含 extra）/ 汉字结果。
      expect(actual!.toJson(), expected.toJson(), reason: reason);
      expect(actual.popupJson, expected.popupJson, reason: reason);
      expect(actual.entries.length, expected.entries.length, reason: reason);
    }

    setUpAll(() async {
      expect(
        haveLib,
        isTrue,
        reason: '后台查词需要 fushidicts_ffi 动态库：设 FUSHI_DICTS_LIB 指向构建好的库',
      );
      FushiDicts.nativeLibraryPath = lib;
      await FushiDicts.preloadTransformsFrom(
        (String key) => File('../../fushi/$key').readAsString(),
      );
      root = Directory.systemTemp.createTempSync('fushi_bg_lookup');
      dictA = await importDict('BgLookupA', <String, Object>{
        'term_bank_1.json': <Object>[
          term('食べる', 'たべる', 'v1', 'to eat (A)'),
          term('漢', 'かん', '', 'han (A)'),
          term('漢字', 'かんじ', '', 'kanji (A)'),
          for (int i = 0; i < 12; i++) term('語$i', 'ご', '', 'word $i (A)'),
          // 中文简繁回落：只有繁體词头。
          term('頭髮', 'tóufà', '', 'hair (A)'),
          term('我', 'wǒ', '', 'I (A)'),
          term('我們', 'wǒmen', '', 'we (A)'),
        ],
      });
      dictB = await importDict('BgLookupB', <String, Object>{
        'term_bank_1.json': <Object>[
          term('食べる', 'たべる', 'v1', 'eat (B)'),
          term('漢字', 'かんじ', '', 'kanji (B)'),
        ],
      });
      kanjiDict = await importDict('BgLookupKanji', <String, Object>{
        'kanji_bank_1.json': <Object>[
          <Object>[
            '漢',
            'カン',
            'から',
            '',
            <String>['China'],
            <String, String>{},
          ],
          <Object>[
            '字',
            'ジ',
            'あざ',
            '',
            <String>['letter'],
            <String, String>{},
          ],
        ],
      });
      loadAll();
    });

    tearDownAll(() async {
      TransformDescriptionCatalog.clear();
      FushiDicts.disposeInstance();
      await FushiDicts.shutdownBackgroundLookup();
      try {
        root?.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录清理失败不影响结论。
      }
    });

    setUp(() async {
      TransformDescriptionCatalog.clear();
      loadAll();
    });

    test('后台结果与旧同步路径逐字段相同，且在命名的后台 isolate 上算', () async {
      final List<({String text, bool kanji})> queries =
          <({String text, bool kanji})>[
            (text: '食べた', kanji: false),
            (text: '食べる', kanji: false),
            (text: '漢', kanji: true),
            (text: '字', kanji: true), // 只有汉字桶命中：纯汉字结果
            (text: '漢字を読むのは楽しいですがとても難しいです', kanji: false),
            (text: '語1', kanji: false),
            (text: 'ないない', kanji: false), // 无结果
          ];
      final List<({Set<String> hidden, List<String> order})> settings =
          <({Set<String> hidden, List<String> order})>[
            (hidden: const <String>{}, order: const <String>[]),
            (
              hidden: const <String>{'BgLookupB'},
              order: const <String>['BgLookupA', 'BgLookupB'],
            ),
            (
              hidden: const <String>{},
              order: const <String>['BgLookupB', 'BgLookupA'],
            ),
            (
              hidden: const <String>{'BgLookupA', 'BgLookupB'},
              order: const <String>[],
            ),
          ];
      for (final query in queries) {
        for (final setting in settings) {
          for (final int max in <int>[1, 10]) {
            final FushiLookupRequest request = FushiLookupRequest(
              text: query.text,
              maxResults: max,
              includeKanji: query.kanji,
              hiddenDictionaries: setting.hidden,
              dictionaryOrder: setting.order,
            );
            final String reason =
                '${query.text} max=$max hidden=${setting.hidden} order=${setting.order}';
            final FushiLookupOutcome outcome = (await FushiDicts.instance
                .lookupInBackground(request))!;
            final DictionarySearchResult? expected = syncReference(request);
            expectSameResult(outcome.result, expected, reason);
            expect(outcome.superseded, isFalse);
          }
        }
      }
      expect(debugLastBackgroundLookupIsolate, kBackgroundLookupIsolateName);
    });

    test('中文简繁回落：flag 经 FFI 到引擎，后台与同步同口径，关着时不命中', () async {
      List<String> words(List<FushiLookupResult> rs) =>
          rs.map((FushiLookupResult r) => r.term.expression).toList();

      final List<FushiLookupResult> on = FushiDicts.instance.lookup(
        '头发很长',
        maxResults: 10,
        chineseSimpToTrad: true,
      );
      // 一简多繁：发 → 發 / 髮，只取首选项会拼成不存在的「頭發」。
      expect(words(on), contains('頭髮'));
      expect(
        on
            .firstWhere((FushiLookupResult r) => r.term.expression == '頭髮')
            .matched,
        '头发',
      );
      expect(
        words(FushiDicts.instance.lookup('头发很长', maxResults: 10)),
        isNot(contains('頭髮')),
      );
      // 「我」原样就能命中，但更长的「我們」要排第一：回落不是零结果才触发。
      expect(
        FushiDicts.instance
            .lookup('我们是', maxResults: 10, chineseSimpToTrad: true)
            .first
            .term
            .expression,
        '我們',
      );
      // 带词频选项时同样认 flag（选项与 flag 一起走 with_flags 导出）。
      expect(
        words(
          FushiDicts.instance.lookup(
            '头发',
            maxResults: 10,
            frequencyOrder: FushiLookupFrequencyOrder.disabled,
            chineseSimpToTrad: true,
          ),
        ),
        contains('頭髮'),
      );

      for (final bool zh in <bool>[true, false]) {
        final FushiLookupRequest request = FushiLookupRequest(
          text: '头发很长',
          maxResults: 10,
          chineseSimpToTrad: zh,
        );
        final FushiLookupOutcome outcome = (await FushiDicts.instance
            .lookupInBackground(request))!;
        final List<FushiLookupResult> sync = FushiDicts.instance.lookup(
          '头发很长',
          maxResults: 10,
          chineseSimpToTrad: zh,
        );
        final DictionarySearchResult? expected = sync.isEmpty
            ? null
            : buildResultFromLookup(
                searchTerm: request.text,
                results: sync,
                maximumTerms: 10,
                dictionaryOrder: const <String>[],
                hiddenDictionaries: const <String>{},
              );
        expect(
          outcome.result?.entries.map((e) => e.word).toList() ?? <String>[],
          expected?.entries.map((e) => e.word).toList() ?? <String>[],
          reason: 'zh=$zh',
        );
        expect(
          outcome.result?.entries.any((e) => e.word == '頭髮') ?? false,
          zh,
          reason: 'zh=$zh',
        );
      }
    });

    test('popupOnly 与旧同步路径同口径（popupJson + 全部结果的 bestLength）', () async {
      for (final String text in <String>['食べた', '漢字を', 'ないない']) {
        for (final Set<String> hidden in <Set<String>>[
          const <String>{},
          const <String>{'BgLookupA', 'BgLookupB'},
        ]) {
          final List<FushiLookupResult> ffi = FushiDicts.instance.lookup(
            text,
            maxResults: 10,
          );
          final FushiLookupOutcome outcome = (await FushiDicts.instance
              .lookupInBackground(
                FushiLookupRequest(
                  text: text,
                  maxResults: 10,
                  popupOnly: true,
                  hiddenDictionaries: hidden,
                ),
              ))!;
          expect(outcome.result, isNull);
          if (ffi.isEmpty) {
            expect(outcome.popupJson, isNull, reason: text);
            continue;
          }
          expect(
            outcome.popupJson,
            buildPopupJsonFromLookup(
              results: ffi,
              maximumTerms: 10,
              hiddenDictionaries: hidden,
            ),
            reason: text,
          );
          int best = 0;
          for (final FushiLookupResult r in ffi) {
            if (r.matched.length > best) best = r.matched.length;
          }
          expect(outcome.bestLength, best, reason: text);
        }
      }
    });

    test('界面语言译文同步到后台：变形标签与 UI isolate 上同口径翻译', () async {
      final List<FushiLookupResult> ffi = FushiDicts.instance.lookup(
        '食べた',
        maxResults: 10,
      );
      final FushiTransformGroup step = ffi
          .expand((FushiLookupResult r) => r.trace)
          .firstWhere((FushiTransformGroup t) => t.description.isNotEmpty);
      TransformDescriptionCatalog.apply(
        localeTag: 'zz',
        translations: <String, String>{step.description: '译文-XLATED'},
      );
      const FushiLookupRequest request = FushiLookupRequest(
        text: '食べた',
        maxResults: 10,
      );
      final FushiLookupOutcome outcome = (await FushiDicts.instance
          .lookupInBackground(request))!;
      expect(outcome.result!.popupJson, contains('译文-XLATED'));
      expectSameResult(outcome.result, syncReference(request), 'translated');

      TransformDescriptionCatalog.clear();
      final FushiLookupOutcome cleared = (await FushiDicts.instance
          .lookupInBackground(request))!;
      expect(
        cleared.result!.popupJson,
        isNot(contains('译文-XLATED')),
        reason: '换回英文后后台必须跟上',
      );
    });

    test('后台缓存：同窗口命中；引擎换实例（词典变更）后失效', () async {
      const String head = '漢字を読むのは楽しいですがとても';
      expect(head.runes.length, 16);
      final FushiLookupOutcome first = (await FushiDicts.instance
          .lookupInBackground(
            const FushiLookupRequest(text: '$head難しい', maxResults: 10),
          ))!;
      expect(first.ffiCacheHit, isFalse);
      final FushiLookupOutcome sameWindow = (await FushiDicts.instance
          .lookupInBackground(
            const FushiLookupRequest(text: '$head難しくない', maxResults: 10),
          ))!;
      expect(sameWindow.ffiCacheHit, isTrue, reason: '前 17 码点相同：引擎结果相同，命中后台缓存');
      expect(
        sameWindow.result!.searchTerm,
        '$head難しくない',
        reason: '结果里的 searchTerm 仍是本次的完整查询串',
      );
      expectSameResult(
        sameWindow.result,
        syncReference(
          const FushiLookupRequest(text: '$head難しくない', maxResults: 10),
        ),
        'window hit',
      );
      final FushiLookupOutcome biggerMax = (await FushiDicts.instance
          .lookupInBackground(
            const FushiLookupRequest(text: '$head難しい', maxResults: 11),
          ))!;
      expect(biggerMax.ffiCacheHit, isFalse, reason: '上限不同不得命中（load-more）');

      // 词典变更：卸掉 A。旧实例里缓存的「漢 → han (A)」一条都不能再用。
      const FushiLookupRequest han = FushiLookupRequest(
        text: '漢字',
        maxResults: 10,
      );
      final FushiLookupOutcome before = (await FushiDicts.instance
          .lookupInBackground(han))!;
      expect(
        before.result!.entries.map((DictionaryEntry e) => e.dictionaryName),
        contains('BgLookupA'),
      );
      FushiDicts.initializeTyped(termPaths: <String>[dictB]);
      final FushiLookupOutcome after = (await FushiDicts.instance
          .lookupInBackground(han))!;
      expect(after.ffiCacheHit, isFalse);
      expect(
        after.result!.entries.map((DictionaryEntry e) => e.dictionaryName),
        everyElement('BgLookupB'),
      );
      expectSameResult(after.result, syncReference(han), 'after reload');
    });

    test('查询在飞时重载（旧实例 dispose）结果照样正确', () async {
      const FushiLookupRequest request = FushiLookupRequest(
        text: '食べた',
        maxResults: 10,
      );
      final DictionarySearchResult? expected = syncReference(request);
      for (int round = 0; round < 5; round++) {
        final Future<FushiLookupOutcome?> inFlight = FushiDicts.instance
            .lookupInBackground(request);
        loadAll();
        expectSameResult((await inFlight)!.result, expected, 'round $round');
      }
    });

    test('同 lane：未开始的旧请求被取代，在跑的与最新的照常返回', () async {
      final FushiDicts dicts = FushiDicts.instance;
      final Future<FushiLookupOutcome?> running = dicts.lookupInBackground(
        const FushiLookupRequest(
          text: '食べた',
          maxResults: 10,
          supersedeLane: 'hover',
        ),
      );
      final Future<FushiLookupOutcome?> stale = dicts.lookupInBackground(
        const FushiLookupRequest(
          text: '漢字',
          maxResults: 10,
          supersedeLane: 'hover',
        ),
      );
      final Future<FushiLookupOutcome?> other = dicts.lookupInBackground(
        const FushiLookupRequest(text: '語1', maxResults: 10),
      );
      final Future<FushiLookupOutcome?> latest = dicts.lookupInBackground(
        const FushiLookupRequest(
          text: '食べる',
          maxResults: 10,
          supersedeLane: 'hover',
        ),
      );
      final FushiLookupOutcome staleOutcome = (await stale)!;
      expect(staleOutcome.superseded, isTrue);
      expect(staleOutcome.result, isNull);
      expect((await running)!.result!.searchTerm, '食べた');
      expect((await latest)!.result!.searchTerm, '食べる');
      expect(
        (await other)!.result!.searchTerm,
        '語1',
        reason: '没声明 lane 的请求不会被取代',
      );
    });

    test('已 dispose 的实例借不到句柄，返回 null；关停后下一次查词重新拉起', () async {
      final FushiDicts old = FushiDicts.instance;
      loadAll();
      expect(
        await old.lookupInBackground(
          const FushiLookupRequest(text: '漢字', maxResults: 10),
        ),
        isNull,
      );
      await FushiDicts.shutdownBackgroundLookup();
      final FushiLookupOutcome again = (await FushiDicts.instance
          .lookupInBackground(
            const FushiLookupRequest(text: '漢字', maxResults: 10),
          ))!;
      expect(again.result, isNotNull);
    });

    test('释放映射要等后台查词归还句柄（BUG-1756）', () async {
      final File mapped = File('$dictA/hash.table');
      final List<int> bytes = mapped.readAsBytesSync();
      final Future<Object?> inFlight = FushiDicts.instance.lookupInBackground(
        const FushiLookupRequest(text: '食べた', maxResults: 10),
      );
      // 借用在上面那次调用里已同步 retain：旧句柄此刻必然还映射着文件。
      FushiDicts.releaseAllMappings();
      if (Platform.isWindows) {
        expect(
          () => mapped.writeAsBytesSync(bytes),
          throwsA(isA<FileSystemException>()),
          reason: 'retired-but-borrowed handle still maps the file',
        );
      }
      await inFlight;

      loadAll();
      final Future<Object?> again = FushiDicts.instance.lookupInBackground(
        const FushiLookupRequest(text: '食べた', maxResults: 10),
      );
      await FushiDicts.withMappingsReleased(() async {
        mapped.writeAsBytesSync(bytes); // 映射已解除：覆盖写成功
      });
      await again;
    });
  });
}
