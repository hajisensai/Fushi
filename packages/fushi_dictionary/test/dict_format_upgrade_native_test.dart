import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// [FushiDicts.upgradeDictionaryFormats]（原生 `fushidicts_upgrade_dictionary`）在真原生
/// 库上的端到端：新导入的词典全部「已是最新」；存量（旧式）词典升级后返回码 / report /
/// 进度回调符合预期、幂等、升级前后查词结果逐字段相同；映射释放作用域内调用得到
/// deferred，作用域等在跑的那一本结束。
///
/// 「存量词典」的造法：原生导入在环境变量 `FUSHIDICTS_LEGACY_INDEX=1` 时按改动前的格式
/// 写（`native/fushidicts/fushidicts_src/importer.cpp` 的 `legacy_index_forced`，每次导入
/// 时读一次）。测试进程里经 FFI 调 C 运行时的 `setenv` / `_putenv_s` 设它——原生库读的
/// 是 C 运行时的环境表，Dart 的 `Platform.environment` 改不到那里。
///
/// 需要构建好的 fushidicts_ffi 动态库：设 `FUSHI_DICTS_LIB=<绝对路径>`，没有时整组 skip。
void main() {
  final String? lib = Platform.environment['FUSHI_DICTS_LIB'];
  final bool haveLib = lib != null && lib.isNotEmpty && File(lib).existsSync();

  group(
    '词典格式原地升级（真原生库）',
    () {
      late Directory root;

      // 新格式（当前导入端）。
      late String freshTerm;
      late String freshFreq;
      // 旧式（存量）。
      late String legacyTerm;
      late String legacyFreq;
      late String legacyPitch;
      late String legacyIpa;
      late String legacyForScope;

      Future<String> importDict(
        String title,
        Map<String, Object> banks, {
        bool legacy = false,
      }) async {
        final Archive archive = Archive();
        void add(String name, String content) {
          final List<int> bytes = utf8.encode(content);
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }

        add('index.json', '{"title":"$title","format":3,"revision":"1"}');
        banks.forEach((String n, Object rows) => add(n, jsonEncode(rows)));
        final File zip = File('${root.path}/$title.zip')
          ..writeAsBytesSync(ZipEncoder().encode(archive)!);
        if (legacy) _setCEnv('FUSHIDICTS_LEGACY_INDEX', '1');
        try {
          final FushiImportResult imported = await FushiDicts.importDictionary(
            zip.path,
            '${root.path}/out',
          );
          expect(imported.success, isTrue, reason: imported.error);
          return '${root.path}/out/${imported.title}';
        } finally {
          if (legacy) _setCEnv('FUSHIDICTS_LEGACY_INDEX', null);
        }
      }

      List<Object> term(String expression, String reading, String gloss) =>
          <Object>[
            expression,
            reading,
            '',
            '',
            0,
            <String>[gloss],
            0,
            '',
          ];

      final Map<String, Object> termBanks = <String, Object>{
        'term_bank_1.json': <Object>[
          term('猫', 'ねこ', 'cat'),
          term('食べる', 'たべる', 'to eat'),
          term('犬', 'いぬ', 'dog'),
        ],
      };
      final Map<String, Object> freqBanks = <String, Object>{
        'term_meta_bank_1.json': <Object>[
          <Object>['猫', 'freq', 120],
          <Object>[
            '犬',
            'freq',
            <String, Object>{
              'reading': 'いぬ',
              'frequency': <String, Object>{'value': 7, 'displayValue': '7㋕'},
            },
          ],
          <Object>['食べる', 'freq', '300'],
        ],
      };
      final Map<String, Object> pitchBanks = <String, Object>{
        'term_meta_bank_1.json': <Object>[
          <Object>[
            '猫',
            'pitch',
            <String, Object>{
              'reading': 'ねこ',
              'pitches': <Object>[
                <String, Object>{'position': 1},
              ],
            },
          ],
          <Object>[
            '食べる',
            'pitch',
            <String, Object>{
              'reading': 'たべる',
              'pitches': <Object>[
                <String, Object>{'position': 2},
                <String, Object>{'position': 0},
              ],
            },
          ],
        ],
      };
      final Map<String, Object> ipaBanks = <String, Object>{
        'term_meta_bank_1.json': <Object>[
          <Object>[
            '犬',
            'ipa',
            <String, Object>{
              'reading': 'いぬ',
              'transcriptions': <Object>[
                <String, Object>{'ipa': 'inɯ', 'tags': <String>[]},
              ],
            },
          ],
        ],
      };

      String describe(List<FushiLookupResult> results) => results
          .map(
            (FushiLookupResult r) =>
                '${r.matched}|${r.term.expression}|${r.term.reading}|'
                '${r.term.glossaries.map((g) => '${g.dictName}:${g.glossary}').join(',')}|'
                '${r.term.frequencies.map((f) => '${f.dictName}:${f.frequencies.map((x) => '${x.value}/${x.displayValue}').join('+')}').join(',')}|'
                '${r.term.pitches.map((p) => '${p.dictName}:${p.pitchPositions.join('+')}:${p.patterns.join('+')}:${p.transcriptions.join('+')}').join(',')}',
          )
          .join('\n');

      const List<String> queries = <String>['猫', '食べた', '犬', 'いぬ', 'ない'];

      List<String> lookupAll() => <String>[
        for (final String q in queries) describe(FushiDicts.instance.lookup(q)),
      ];

      void loadLegacySet() => FushiDicts.initializeTyped(
        termPaths: <String>[legacyTerm],
        freqPaths: <String>[legacyFreq],
        pitchPaths: <String>[legacyPitch, legacyIpa],
      );

      setUpAll(() async {
        FushiDicts.nativeLibraryPath = lib;
        await FushiDicts.preloadTransformsFrom(
          (String key) => File('../../fushi/$key').readAsString(),
        );
        root = Directory.systemTemp.createTempSync('fushi_dict_upgrade');
        freshTerm = await importDict('FreshTerm', termBanks);
        freshFreq = await importDict('FreshFreq', freqBanks);
        legacyTerm = await importDict('LegacyTerm', termBanks, legacy: true);
        legacyFreq = await importDict('LegacyFreq', freqBanks, legacy: true);
        legacyPitch = await importDict('LegacyPitch', pitchBanks, legacy: true);
        legacyIpa = await importDict('LegacyIpa', ipaBanks, legacy: true);
        legacyForScope = await importDict(
          'LegacyScope',
          termBanks,
          legacy: true,
        );
      });

      tearDownAll(() async {
        FushiDicts.releaseAllMappings();
        await FushiDicts.whenBackgroundBorrowsSettled();
        try {
          root.deleteSync(recursive: true);
        } on FileSystemException {
          // 临时目录清理失败不影响结论。
        }
      });

      test('新导入的词典全部「已是最新」；不存在的目录跳过但占进度序号', () async {
        final List<(int, int, String, FushiDictUpgradeOutcome)> progress =
            <(int, int, String, FushiDictUpgradeOutcome)>[];
        final String missing = '${root.path}/out/NoSuchDict';
        final FushiDictUpgradeReport report =
            await FushiDicts.upgradeDictionaryFormats(
              <String>[freshTerm, missing, freshFreq],
              onProgress:
                  (
                    int done,
                    int total,
                    String dir,
                    FushiDictUpgradeOutcome o,
                  ) => progress.add((done, total, dir, o)),
            );
        expect(report.results, <String, FushiDictUpgradeOutcome>{
          freshTerm: FushiDictUpgradeOutcome.upToDate,
          freshFreq: FushiDictUpgradeOutcome.upToDate,
        });
        expect(report.deferred, isEmpty);
        expect(report.anyUpgraded, isFalse);
        expect(progress, <(int, int, String, FushiDictUpgradeOutcome)>[
          (1, 3, freshTerm, FushiDictUpgradeOutcome.upToDate),
          (3, 3, freshFreq, FushiDictUpgradeOutcome.upToDate),
        ]);
      });

      test('存量词典：升级（引擎正装着也能升）→ 重载后查词逐字段相同；再调一次全部已是最新', () async {
        loadLegacySet();
        final List<String> before = lookupAll();
        // 素材本身要查得出东西，否则「前后相同」没有判别力。
        expect(before[0], contains('LegacyTerm:'));
        expect(before[0], contains('cat'));
        expect(before[0], contains('LegacyFreq:120/'));
        expect(before[0], contains('LegacyPitch:1'));
        expect(before[1], contains('LegacyPitch:2+0'));
        expect(before[2], contains('LegacyFreq:7/7㋕'));
        expect(before[2], contains('LegacyIpa:'));
        expect(before[2], contains('inɯ'));

        final List<String> dirs = <String>[
          legacyTerm,
          legacyFreq,
          legacyPitch,
          legacyIpa,
        ];
        int callbacks = 0;
        final FushiDictUpgradeReport first =
            await FushiDicts.upgradeDictionaryFormats(
              dirs,
              onProgress: (int done, int total, String dir, _) {
                callbacks++;
                expect(total, dirs.length);
                expect(dir, dirs[done - 1]);
              },
            );
        expect(callbacks, dirs.length);
        expect(first.results, <String, FushiDictUpgradeOutcome>{
          for (final String d in dirs) d: FushiDictUpgradeOutcome.upgraded,
        }, reason: '旧式词典没被升级：多半是 FUSHIDICTS_LEGACY_INDEX 没设进原生库的 C 运行时');
        expect(first.upgraded, dirs);
        expect(first.anyUpgraded, isTrue);

        // 升级不动正在用的引擎：重载之前查词照旧。
        expect(lookupAll(), before);

        // 新格式下一次装载生效。
        loadLegacySet();
        expect(lookupAll(), before, reason: '升级前后查词结果必须逐字段相同');

        // 释放旧引擎后再调：幂等（顺带清理遗留旧文件）。
        FushiDicts.releaseAllMappings();
        await FushiDicts.whenBackgroundBorrowsSettled();
        final FushiDictUpgradeReport again =
            await FushiDicts.upgradeDictionaryFormats(dirs);
        expect(again.results, <String, FushiDictUpgradeOutcome>{
          for (final String d in dirs) d: FushiDictUpgradeOutcome.upToDate,
        });
        loadLegacySet();
        expect(lookupAll(), before);
      });

      test('queryFrequencies：词条 / rules / 词频与 query 逐项相同，但不带释义与音调', () {
        loadLegacySet();
        String freqOf(FushiTermResult t) =>
            '${t.expression}|${t.reading}|${t.rules}|'
            '${t.frequencies.map((f) => '${f.dictName}:${f.frequencies.map((x) => '${x.value}/${x.displayValue}').join('+')}').join(',')}';
        int withFrequency = 0;
        for (final String word in <String>['猫', '犬', '食べる', 'いぬ', '無い']) {
          final List<FushiTermResult> full = FushiDicts.instance.query(word);
          final List<FushiTermResult> freq = FushiDicts.instance
              .queryFrequencies(word);
          expect(
            freq.map(freqOf).toList(),
            full.map(freqOf).toList(),
            reason: word,
          );
          for (final FushiTermResult t in freq) {
            expect(t.glossaries, isEmpty, reason: '$word：不该带释义');
            expect(t.pitches, isEmpty, reason: '$word：不该带音调');
            if (t.frequencies.isNotEmpty) withFrequency++;
          }
        }
        // 素材要真的查得出词条、释义与词频，否则上面的比较没有判别力。
        final List<FushiTermResult> neko = FushiDicts.instance.query('猫');
        expect(neko, isNotEmpty);
        expect(neko.first.glossaries, isNotEmpty);
        expect(neko.first.pitches, isNotEmpty);
        expect(withFrequency, greaterThanOrEqualTo(2));
        expect(FushiDicts.instance.queryFrequencies('存在しない語'), isEmpty);
      });

      test('与删 / 覆盖词典串行：作用域等在跑的那一本结束；作用域内全部 deferred', () async {
        bool done = false;
        final Future<FushiDictUpgradeReport> running =
            FushiDicts.upgradeDictionaryFormats(<String>[legacyForScope]).then((
              FushiDictUpgradeReport r,
            ) {
              done = true;
              return r;
            });
        // 等升级真正登记进账本（前面有一次异步 exists 检查）。
        while (FushiDicts.debugBackgroundBorrowsInFlight == 0 && !done) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(done, isFalse, reason: '后台 isolate 跑一本不可能在一次事件循环内完成');
        await FushiDicts.withMappingsReleased(() async {
          expect(
            FushiDicts.debugBackgroundBorrowsInFlight,
            0,
            reason: '作用域开始前在跑的那一本必须已经结束（账本等到了它）',
          );
          int callbacks = 0;
          final FushiDictUpgradeReport inside =
              await FushiDicts.upgradeDictionaryFormats(
                <String>[legacyForScope, freshTerm],
                onProgress:
                    (
                      int done,
                      int total,
                      String dir,
                      FushiDictUpgradeOutcome o,
                    ) => callbacks++,
              );
          expect(inside.results, isEmpty);
          expect(inside.deferred, <String>[legacyForScope, freshTerm]);
          expect(callbacks, 0);
        });
        expect((await running).results, <String, FushiDictUpgradeOutcome>{
          legacyForScope: FushiDictUpgradeOutcome.upgraded,
        });
      });
    },
    skip: haveLib
        ? false
        : '需要 FUSHI_DICTS_LIB 指向构建好的 fushidicts_ffi 动态库（当前: ${lib ?? '未设置'}）',
  );
}

/// 设 / 清 C 运行时的环境变量（[value] 为 null = 清掉）。原生库用 `std::getenv` 读，
/// 只看 C 运行时自己的环境表：POSIX 上整个进程共用 libc 的 `environ`；Windows 上
/// fushidicts_ffi.dll 按 CMake 默认链动态 UCRT（`/MD`），与这里调的 `ucrtbase.dll`
/// 是同一张表。
void _setCEnv(String name, String? value) {
  final Pointer<Utf8> n = name.toNativeUtf8();
  final Pointer<Utf8> v = (value ?? '').toNativeUtf8();
  try {
    if (Platform.isWindows) {
      final int Function(Pointer<Utf8>, Pointer<Utf8>) putenvS =
          DynamicLibrary.open('ucrtbase.dll').lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<Utf8>, Pointer<Utf8>)
          >('_putenv_s');
      // 值为空串 = 删除该变量。
      expect(putenvS(n, v), 0);
      return;
    }
    final DynamicLibrary libc = DynamicLibrary.process();
    if (value == null) {
      final int Function(Pointer<Utf8>) unsetenv = libc
          .lookupFunction<
            Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('unsetenv');
      expect(unsetenv(n), 0);
    } else {
      final int Function(Pointer<Utf8>, Pointer<Utf8>, int) setenv = libc
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('setenv');
      expect(setenv(n, v, 1), 0);
    }
  } finally {
    malloc.free(n);
    malloc.free(v);
  }
}
