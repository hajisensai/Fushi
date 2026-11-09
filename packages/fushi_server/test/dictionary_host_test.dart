import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务端词典引擎（[ServerDictionaryHost]）+ 互联查词 / 历史 service。
///
/// 纯逻辑（分桶 / 清洗 / 路径定位）与「原生库缺失」路径在任何机器上都跑；真查词的
/// 端到端需要 libfushidicts_ffi：设 `FUSHI_DICTS_LIB=<.so 绝对路径>`（CI 的 linux-server
/// job 用随包那份），没有时整组 skip 并说明原因。
void main() {
  group('bucketDictPaths（服务端与 app 共用 fushi_dictionary 同一份）', () {
    DictPathEntry e(
      String type,
      String path, {
      bool exists = true,
      bool hidden = false,
      Map<String, String> metadata = const <String, String>{},
      int order = 0,
    }) => dictPathEntryOf(
      type: dictionaryTypeFromName(type),
      path: path,
      exists: exists,
      hidden: hidden,
      metadata: metadata,
      order: order,
    );

    test('隐藏的词典四种类型都不进桶（BUG-3454）；不存在的目录跳过；hasKanji 双桶', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e('term', 't1', hidden: true),
        e(
          'term',
          't2',
          metadata: const <String, String>{'hasKanji': 'true'},
          order: 1,
        ),
        e('term', 'gone', exists: false),
        e('frequency', 'f1', hidden: true),
        e('frequency', 'f2'),
        e('pitch', 'p1'),
        e('kanji', 'k1', order: 2),
      ]);
      expect(b.term, <String>['t2']);
      expect(b.freq, <String>['f2']);
      expect(b.pitch, <String>['p1']);
      expect(b.kanji, <String>['t2', 'k1']);
    });

    test('BUG-3573：混合词典的术语部分与汉字部分各按自己的开关装载', () {
      // 术语部分关、汉字部分开：只进汉字桶（以前服务端按整本 hidden，整本都不装）。
      final b1 = bucketDictPaths(<DictPathEntry>[
        e(
          'term',
          'mixed',
          hidden: true,
          metadata: const <String, String>{'hasKanji': 'true'},
        ),
      ]);
      expect(b1.term, isEmpty);
      expect(b1.kanji, <String>['mixed']);

      // 术语部分开、汉字部分关：只进术语桶。
      final b2 = bucketDictPaths(<DictPathEntry>[
        e(
          'term',
          'mixed',
          metadata: const <String, String>{
            'hasKanji': 'true',
            'kanjiHidden': 'true',
          },
        ),
      ]);
      expect(b2.term, <String>['mixed']);
      expect(b2.kanji, isEmpty);
    });

    test('汉字桶按「汉字」分区顺序（kanjiOrder，缺省退回 order）', () {
      final b = bucketDictPaths(<DictPathEntry>[
        e(
          'term',
          'mixed',
          metadata: const <String, String>{
            'hasKanji': 'true',
            'kanjiOrder': '0',
          },
          order: 5,
        ),
        e('kanji', 'KANJIDIC', order: 1),
      ]);
      expect(b.kanji, <String>['mixed', 'KANJIDIC']);
    });

    test('未知类型名按术语词典装', () {
      expect(dictionaryTypeFromName('???'), DictionaryType.term);
      expect(dictionaryTypeFromName('kanji'), DictionaryType.kanji);
    });
  });

  group('resolveServerDictionarySelection（请求方词典选择 → 本次生效的排序 / 排除）', () {
    const List<String> serverOrder = <String>['A', 'B', 'C'];
    const Set<String> serverHidden = <String>{'C', 'Freq'};

    test('没带选择 ⇒ 服务端自己的顺序与关掉名单（旧输出）', () {
      final ServerDictionarySelection s = resolveServerDictionarySelection(
        serverTermOrder: serverOrder,
        serverHidden: serverHidden,
      );
      expect(s.order, serverOrder);
      expect(s.excluded, serverHidden);
    });

    test('带选择 ⇒ order ∩ 服务端 term 词典在前，其余按服务端顺序追加；排除只认请求方', () {
      final ServerDictionarySelection s = resolveServerDictionarySelection(
        serverTermOrder: serverOrder,
        serverHidden: serverHidden,
        config: const RemoteLookupDictionaryConfig(
          excluded: <String>{'B', 'LocalOnly'},
          order: <String>['C', 'LocalOnly', 'A', 'C'],
        ),
      );
      // 服务端没有的名字丢掉、重复去重；B 没提到 ⇒ 追加在后（默认启用）。
      expect(s.order, <String>['C', 'A', 'B']);
      // 服务端的隐藏（C / Freq）不叠加：请求方的选择是唯一真相。
      expect(s.excluded, <String>{'B', 'LocalOnly'});
    });

    test('空选择 ⇒ 服务端顺序、什么都不排除（不是「没带」）', () {
      final ServerDictionarySelection s = resolveServerDictionarySelection(
        serverTermOrder: serverOrder,
        serverHidden: serverHidden,
        config: const RemoteLookupDictionaryConfig(
          excluded: <String>{},
          order: <String>[],
        ),
      );
      expect(s.order, serverOrder);
      expect(s.excluded, isEmpty);
    });
  });

  group('withoutExcludedDictionaryMeta', () {
    FushiLookupResult result() => const FushiLookupResult(
      matched: '食べる',
      deinflected: '食べる',
      trace: <FushiTransformGroup>[],
      preprocessorSteps: 0,
      term: FushiTermResult(
        expression: '食べる',
        reading: 'たべる',
        rules: 'v1',
        glossaries: <FushiGlossaryEntry>[
          FushiGlossaryEntry(
            dictName: 'D',
            glossary: 'to eat',
            definitionTags: '',
            termTags: '',
          ),
        ],
        frequencies: <FushiFrequencyEntry>[
          FushiFrequencyEntry(
            dictName: 'F1',
            frequencies: <FushiFrequency>[
              FushiFrequency(value: 1, displayValue: '1'),
            ],
          ),
          FushiFrequencyEntry(
            dictName: 'F2',
            frequencies: <FushiFrequency>[
              FushiFrequency(value: 2, displayValue: '2'),
            ],
          ),
        ],
        pitches: <FushiPitchEntry>[
          FushiPitchEntry(dictName: 'P1', pitchPositions: <int>[2]),
        ],
      ),
    );

    test('剔掉被排除词典的频率 / 音调，其余原样', () {
      final List<FushiLookupResult> out = withoutExcludedDictionaryMeta(
        <FushiLookupResult>[result()],
        <String>{'F1', 'P1'},
      );
      expect(
        out.single.term.frequencies.map((FushiFrequencyEntry f) => f.dictName),
        <String>['F2'],
      );
      expect(out.single.term.pitches, isEmpty);
      expect(out.single.term.glossaries.single.dictName, 'D');
      expect(out.single.matched, '食べる');
    });

    test('没有要剔的 ⇒ 原列表（同一实例）', () {
      final List<FushiLookupResult> input = <FushiLookupResult>[result()];
      expect(
        identical(withoutExcludedDictionaryMeta(input, <String>{}), input),
        isTrue,
      );
      expect(
        identical(withoutExcludedDictionaryMeta(input, <String>{'X'}), input),
        isTrue,
      );
    });
  });

  group('normalizeServerSearchTerm', () {
    test('换行折空格、首尾标点剥离、emoji 换空格', () {
      expect(normalizeServerSearchTerm('「食べた」'), '食べた');
      expect(normalizeServerSearchTerm('食べ\nた'), '食べ た');
      expect(normalizeServerSearchTerm('食😀べた'), '食 べた');
    });

    test('超长输入按码点截断', () {
      final String long = '字' * (kServerMaxLookupInputChars + 50);
      expect(
        normalizeServerSearchTerm(long).runes.length,
        kServerMaxLookupInputChars,
      );
    });
  });

  group('alignServerRubySpans（请求方原文振假名对齐到清洗后的查询串）', () {
    const FushiRubySpan busy = FushiRubySpan(start: 1, end: 2, reading: 'せわ');

    test('句首标点剥掉 ⇒ 区间平移', () {
      expect(
        alignServerRubySpans(
          raw: '「忙しい」',
          normalized: normalizeServerSearchTerm('「忙しい」'),
          spans: <FushiRubySpan>[busy],
        ),
        <FushiRubySpan>[const FushiRubySpan(start: 0, end: 1, reading: 'せわ')],
      );
    });

    test('无清洗 ⇒ 原样；越界 / 基字对不上 ⇒ 丢弃', () {
      const FushiRubySpan same = FushiRubySpan(start: 0, end: 1, reading: 'せわ');
      expect(
        alignServerRubySpans(
          raw: '忙しい',
          normalized: '忙しい',
          spans: <FushiRubySpan>[same],
        ),
        <FushiRubySpan>[same],
      );
      expect(
        alignServerRubySpans(
          raw: '忙しい',
          normalized: '忙しい',
          spans: <FushiRubySpan>[
            const FushiRubySpan(start: 2, end: 9, reading: 'x'),
          ],
        ),
        isEmpty,
      );
      // emoji（代理对）换成一个空格后长度变了，后面的基字对不上 ⇒ 宁可不用。
      expect(
        alignServerRubySpans(
          raw: '😀忙',
          normalized: normalizeServerSearchTerm('😀忙'),
          spans: <FushiRubySpan>[
            const FushiRubySpan(start: 2, end: 3, reading: 'せわ'),
          ],
        ),
        isEmpty,
      );
    });
  });

  group('原生库 / 变形表定位', () {
    test('FUSHI_DICTS_LIB 优先于 bundle 布局', () {
      expect(
        resolveFushiDictsLibraryPath(
          environment: <String, String>{
            kFushiDictsLibEnv: '/opt/x/libfushidicts_ffi.so',
          },
          executablePath: '/nonexistent/bin/fushi_server',
        ),
        '/opt/x/libfushidicts_ffi.so',
      );
    });

    test('bundle 的 bin/../lib/ 里有库就用它', () async {
      final Directory tmp = await Directory.systemTemp.createTemp(
        'fushi_dict_lib_',
      );
      addTearDown(() => tmp.delete(recursive: true));
      Directory(p.join(tmp.path, 'bin')).createSync();
      Directory(p.join(tmp.path, 'lib')).createSync();
      final File so = File(p.join(tmp.path, 'lib', 'libfushidicts_ffi.so'))
        ..writeAsStringSync('');
      expect(
        resolveFushiDictsLibraryPath(
          environment: const <String, String>{},
          executablePath: p.join(tmp.path, 'bin', 'fushi_server'),
        ),
        so.path,
      );
    }, testOn: 'linux');

    test(
      '变形表：环境变量 > bundle share/fushi/transforms；目录里要有 manifest.json',
      () async {
        final Directory tmp = await Directory.systemTemp.createTemp(
          'fushi_transforms_',
        );
        addTearDown(() => tmp.delete(recursive: true));
        final Directory share = Directory(
          p.join(tmp.path, 'share', 'fushi', 'transforms'),
        )..createSync(recursive: true);
        File(p.join(share.path, 'manifest.json')).writeAsStringSync('[]');
        Directory(p.join(tmp.path, 'bin')).createSync();
        final String exe = p.join(tmp.path, 'bin', 'fushi_server');
        expect(
          resolveTransformsDirectory(
            environment: const <String, String>{},
            executablePath: exe,
            scriptUri: Uri(),
          )?.path,
          share.path,
        );
        final Directory envDir = Directory(p.join(tmp.path, 'env'))
          ..createSync();
        File(p.join(envDir.path, 'manifest.json')).writeAsStringSync('[]');
        expect(
          resolveTransformsDirectory(
            environment: <String, String>{kFushiTransformsDirEnv: envDir.path},
            executablePath: exe,
            scriptUri: Uri(),
          )?.path,
          envDir.path,
        );
        expect(
          resolveTransformsDirectory(
            environment: const <String, String>{},
            executablePath: p.join(tmp.path, 'a', 'b', 'c', 'fushi_server'),
            scriptUri: Uri(),
          ),
          isNull,
        );
      },
    );
  });

  test('纯 Dart 宿主的变形表读取落到 stub（条件 import 没把 rootBundle 带进来）', () {
    // CI 的 server job 用 `flutter test` 跑本包，flutter_tester 带 dart:ui，条件 import 会选中
    // Flutter 分支；发布的 `dart build cli` 与 `dart test` 是纯 Dart VM，必须落到 stub。
    const bool hasDartUi = bool.fromEnvironment('dart.library.ui');
    expect(FushiDicts.transformAssetBackend, hasDartUi ? 'rootBundle' : 'none');
  });

  group('原生库缺失', () {
    test('start 返回 false 并给出原因；查词 / 媒体一律空，不抛', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final ServerDictionaryHost host = ServerDictionaryHost(
        db: db,
        dictionaryResourceRoot: Directory.systemTemp,
        libraryPath: '/nonexistent/libfushidicts_ffi.so',
        transformsDir: null,
      );
      // 绑定是进程级缓存：同一进程里别的用例先加载成功过就测不到「加载失败」。
      if (FushiDicts.isInitialized) {
        markTestSkipped('同进程已加载过 fushidicts，加载失败路径不可测');
        return;
      }
      expect(await host.start(), isFalse);
      expect(host.available, isFalse);
      expect(
        host.unavailableReason,
        contains('/nonexistent/libfushidicts_ffi.so'),
      );
      expect(host.search('食べる', maximumTerms: 10), isNull);
      expect(host.mediaFile('d', 'a.svg'), isNull);
      FushiDicts.nativeLibraryPath = null;
    });
  });

  group('查词历史 service', () {
    test('按词去重、保留最近 N 条；搜索词进 dictionary_media_type 历史', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final ServerRemoteHistoryService history = ServerRemoteHistoryService(
        db,
        maximumResults: 2,
      );
      DictionarySearchResult result(String term) => DictionarySearchResult(
        searchTerm: term,
        entries: <DictionaryEntry>[
          DictionaryEntry(
            dictionaryName: 'D',
            word: term,
            reading: '',
            meaning: 'm',
          ),
        ],
      );
      history.recordHistory(result('a'));
      history.recordHistory(result('b'));
      history.recordHistory(result('a'));
      history.recordHistory(result('c'));
      await history.idle;
      final List<String> terms = <String>[
        for (final DictionaryHistoryRow r in await db.getAllDictionaryHistory())
          (jsonDecode(r.resultJson) as Map)['searchTerm'] as String,
      ];
      expect(terms, <String>['a', 'c']);
      final List<String> searched = <String>[
        for (final SearchHistoryItemRow r in await db.getSearchHistory(
          kDictionarySearchHistoryKey,
        ))
          r.searchTerm,
      ];
      expect(searched.toSet(), <String>{'a', 'b', 'c'});
    });
  });

  // ── 端到端：真原生库 ──────────────────────────────────────────────────
  final String? libPath = resolveFushiDictsLibraryPath();
  final bool haveLib = libPath != null && File(libPath).existsSync();
  group(
    '端到端（libfushidicts_ffi）',
    () {
      late Directory tmp;
      late FushiDatabase db;
      late ServerDictionaryHost host;

      setUpAll(() async {
        tmp = await Directory.systemTemp.createTemp('fushi_dict_e2e_');
        db = FushiDatabase.forTesting(NativeDatabase.memory());
        final Directory resources = Directory(
          p.join(tmp.path, 'dictionaryResources'),
        )..createSync();
        host = ServerDictionaryHost(
          db: db,
          dictionaryResourceRoot: resources,
          libraryPath: libPath,
          transformsDir: Directory(
            p.join('..', '..', 'fushi', 'assets', 'transforms'),
          ),
        );
        expect(await host.start(), isTrue, reason: host.unavailableReason);
        await importTestDictionary(db, resources, tmp, title: 'ServerTestDict');
        // 第二本：同一个 食べる 的另一条释义，外加更长的 食べたい（最长匹配排第一）。
        await importTestDictionary(
          db,
          resources,
          tmp,
          title: 'SecondDict',
          order: 1,
          terms: <List<Object>>[
            <Object>[
              '食べる',
              'たべる',
              'v1',
              'v1',
              100,
              <String>['second eat'],
              1,
              '',
            ],
            <Object>[
              '食べたい',
              'たべたい',
              '',
              '',
              100,
              <String>['want to eat'],
              2,
              '',
            ],
          ],
        );
        await host.refresh();
      });

      tearDownAll(() async {
        FushiDicts.disposeInstance();
        await db.close();
        await tmp.delete(recursive: true);
      });

      test('去屈折查词：食べた → 食べる，带 popupJson', () async {
        expect(host.loadedCount, greaterThan(0));
        final ServerRemoteLookupService lookup = ServerRemoteLookupService(
          host,
        );
        final DictionarySearchResult? r = await lookup.searchDictionary(
          term: '「食べた」',
          wildcards: false,
          maximumTerms: 10,
        );
        expect(r, isNotNull);
        expect(r!.searchTerm, '食べた');
        expect(r.entries.map((DictionaryEntry e) => e.word), contains('食べる'));
        expect(r.entries.first.dictionaryName, 'ServerTestDict');
        expect(
          r.entries.map((DictionaryEntry e) => e.dictionaryName).toSet(),
          <String>{'ServerTestDict', 'SecondDict'},
        );
        expect(r.bestLength, 3);
        expect(r.popupJson, contains('to eat'));
        final RemoteDictionaryPopupLookup? popup = await lookup
            .searchDictionaryPopup(
              term: '食べた',
              wildcards: false,
              maximumTerms: 10,
            );
        expect(popup?.popupJson, contains('食べる'));
        expect(popup?.bestLength, 3);
        expect(
          await lookup.lookupAudio(expression: '食べる', reading: 'たべる'),
          isNull,
        );
      });

      Future<DictionaryMetaRow> rowOf(String name) async =>
          (await db.getAllDictionaryMetadata()).firstWhere(
            (DictionaryMetaRow r) => r.name == name,
          );

      Future<void> setHidden(DictionaryMetaRow row, bool hidden) async {
        await db.upsertDictionaryMeta(
          row
              .toCompanion(true)
              .copyWith(
                hiddenLanguagesJson: Value<String>(hidden ? '["ja"]' : '[]'),
              ),
        );
        await host.refresh();
      }

      test('服务端关掉的词典是「没带选择」时的默认排除：全部关掉 ⇒ 无结果；删掉元数据后重载即查不到', () async {
        final DictionaryMetaRow a = await rowOf('ServerTestDict');
        final DictionaryMetaRow b = await rowOf('SecondDict');
        await setHidden(a, true);
        await setHidden(b, true);
        // BUG-3454 的语义不变：全部关掉就是「无结果」，而不是引擎命中后再在 popupJson
        // 里滤空（排除在引擎截断前生效，见 excludedDictionaries）。
        expect(host.search('食べる', maximumTerms: 10), isNull);
        expect(host.searchPopup('食べる', maximumTerms: 10), isNull);
        await setHidden(a, false);
        await setHidden(b, false);
        await db.deleteDictionaryMeta('ServerTestDict');
        await db.deleteDictionaryMeta('SecondDict');
        await host.refresh();
        expect(host.search('食べる', maximumTerms: 10), isNull);
        // 恢复给后续用例。
        await db.upsertDictionaryMeta(a.toCompanion(true));
        await db.upsertDictionaryMeta(b.toCompanion(true));
        await host.refresh();
      });

      test('引擎装全部词典；没带选择时的输出与服务端开关一致（关掉的那本不出现）', () async {
        final DictionaryMetaRow b = await rowOf('SecondDict');
        await setHidden(b, true);
        addTearDown(() => setHidden(b, false));
        // 关掉的那本也在引擎里（装全部），只是默认排除。
        expect(host.loadedCount, 2);
        final DictionarySearchResult? r = host.search('食べたい', maximumTerms: 10);
        expect(r, isNotNull);
        expect(
          r!.entries.map((DictionaryEntry e) => e.dictionaryName).toSet(),
          <String>{'ServerTestDict'},
        );
        expect(r.popupJson, isNot(contains('SecondDict')));
        // 请求方的选择是唯一真相：带了选择就不叠加服务端的隐藏。
        final DictionarySearchResult? withConfig = host.search(
          '食べたい',
          maximumTerms: 10,
          config: const RemoteLookupDictionaryConfig(
            excluded: <String>{},
            order: <String>[],
          ),
        );
        expect(
          withConfig!.entries.map((DictionaryEntry e) => e.dictionaryName),
          contains('SecondDict'),
        );
      });

      test('被排除的词典即使本该排第一也不出现、不挤占名额（截断前排除）', () async {
        const RemoteLookupDictionaryConfig excludeSecond =
            RemoteLookupDictionaryConfig(
              excluded: <String>{'SecondDict'},
              order: <String>[],
            );
        // 不排除时 top-1 是 SecondDict 的 食べたい（最长匹配）。
        final DictionarySearchResult? plain = host.search(
          '食べたい',
          maximumTerms: 1,
          config: const RemoteLookupDictionaryConfig(
            excluded: <String>{},
            order: <String>[],
          ),
        );
        expect(plain!.entries.first.word, '食べたい');
        expect(plain.entries.first.dictionaryName, 'SecondDict');
        // 排除后名额给了 ServerTestDict 的 食べる（去屈折），而不是被滤空。
        final DictionarySearchResult? r = host.search(
          '食べたい',
          maximumTerms: 1,
          config: excludeSecond,
        );
        expect(r, isNotNull);
        expect(r!.entries.map((DictionaryEntry e) => e.word).toSet(), <String>{
          '食べる',
        });
        expect(
          r.entries.map((DictionaryEntry e) => e.dictionaryName).toSet(),
          <String>{'ServerTestDict'},
        );
        expect(r.popupJson, isNot(contains('want to eat')));
        expect(r.popupJson, isNot(contains('second eat')));
        final RemoteDictionaryPopupLookup? popup = host.searchPopup(
          '食べたい',
          maximumTerms: 1,
          config: excludeSecond,
        );
        expect(popup, isNotNull);
        expect(popup!.popupJson, contains('to eat'));
        expect(popup.popupJson, isNot(contains('SecondDict')));
        expect(popup.bestLength, 4);
      });

      test('排序：请求方 order 在前，没提到 / 不认识的名字照服务端顺序追加', () async {
        List<String> dictsOf(DictionarySearchResult? r) => <String>[
          for (final DictionaryEntry e in r!.entries)
            if (e.word == '食べる') e.dictionaryName,
        ];
        expect(
          dictsOf(
            host.search(
              '食べる',
              maximumTerms: 10,
              config: const RemoteLookupDictionaryConfig(
                excluded: <String>{},
                order: <String>['Unknown', 'SecondDict'],
              ),
            ),
          ),
          <String>['SecondDict', 'ServerTestDict'],
        );
        expect(dictsOf(host.search('食べる', maximumTerms: 10)), <String>[
          'ServerTestDict',
          'SecondDict',
        ]);
      });

      test('ServerRemoteLookupService 经 handler：带选择回执 true 且按选择查', () async {
        final ServerRemoteLookupService lookup = ServerRemoteLookupService(
          host,
        );
        final Map<String, dynamic> resp =
            await buildRemoteDictionaryLookupResponse(<String, dynamic>{
              'term': '食べたい',
              'popupOnly': true,
              kRemoteLookupDictionariesField: <String, Object?>{
                'excluded': <String>['SecondDict'],
              },
            }, lookup: lookup);
        expect(resp[kRemoteLookupDictionaryConfigAppliedField], isTrue);
        expect(resp['popupJson'] as String, isNot(contains('SecondDict')));
        final Map<String, dynamic> legacy =
            await buildRemoteDictionaryLookupResponse(<String, dynamic>{
              'term': '食べたい',
              'popupOnly': true,
            }, lookup: lookup);
        expect(
          legacy.containsKey(kRemoteLookupDictionaryConfigAppliedField),
          isFalse,
        );
        expect(legacy['popupJson'] as String, contains('SecondDict'));
      });
    },
    skip: haveLib
        ? false
        : '没有 libfushidicts_ffi（设 $kFushiDictsLibEnv 指向构建好的 .so）',
  );
}

/// 现造一本最小 Yomitan 词典（ichidan 动词 食べる），经原生导入器落进 [resources]，
/// 再登记 DB 元数据——与 app 导入 / 互联推送落地后的形状一致。
Future<void> importTestDictionary(
  FushiDatabase db,
  Directory resources,
  Directory tmp, {
  required String title,
  int order = 0,
  List<List<Object>>? terms,
}) async {
  final Archive archive = Archive();
  void add(String name, Object json) {
    final List<int> bytes = utf8.encode(jsonEncode(json));
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('index.json', <String, Object>{
    'title': title,
    'revision': '1',
    'format': 3,
    'sequenced': true,
  });
  add(
    'term_bank_1.json',
    terms ??
        <Object>[
          <Object>[
            '食べる',
            'たべる',
            'v1',
            'v1',
            100,
            <String>['to eat'],
            1,
            '',
          ],
          <Object>[
            '飲む',
            'のむ',
            'v5',
            'v5',
            90,
            <String>['to drink'],
            2,
            '',
          ],
        ],
  );
  final File zip = File(p.join(tmp.path, '$title.zip'))
    ..writeAsBytesSync(ZipEncoder().encode(archive)!);
  final Directory out = Directory(p.join(tmp.path, 'import_out_$title'))
    ..createSync();
  final FushiImportResult result = await FushiDicts.importDictionary(
    zip.path,
    out.path,
  );
  expect(result.success, isTrue, reason: result.error);
  expect(result.termCount, terms?.length ?? 2);
  final Directory inner = Directory(p.join(out.path, result.title));
  final Directory source = inner.existsSync() ? inner : out;
  source.renameSync(p.join(resources.path, title));
  await db.upsertDictionaryMeta(
    DictionaryMetadataCompanion.insert(
      name: title,
      formatKey: 'yomichan',
      order: order,
      type: const Value<String>('term'),
    ),
  );
}
