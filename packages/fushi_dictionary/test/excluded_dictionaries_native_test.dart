import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// 按请求排除词典（`excludedDictionaries` / [FushiLookupRequest.hiddenDictionaries]）在
/// 真原生库上的端到端：Dart 封送把名字带进引擎，排除发生在截断之前（被排除词典的更长
/// 匹配不占 maxResults 名额）。引擎语义由 ctest `excluded_dictionaries_lookup_test` 钉；
/// 这一组补上 FFI 封送与后台查词转发这段。
///
/// 需要构建好的 fushidicts_ffi 动态库：设 `FUSHI_DICTS_LIB=<绝对路径>`（与
/// corpus_terms_native_test 同一个变量），没有时整组 skip 并说明原因。
void main() {
  final String? lib = Platform.environment['FUSHI_DICTS_LIB'];
  final bool haveLib = lib != null && lib.isNotEmpty && File(lib).existsSync();

  const String kept = 'ExclDartKept';
  const String gone = 'ExclDartGone';

  group(
    '排除词典（真原生库）',
    () {
      late Directory root;

      Future<String> importDict(String title, List<List<Object>> rows) async {
        final Archive archive = Archive();
        void add(String name, String content) {
          final List<int> bytes = utf8.encode(content);
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }

        add('index.json', '{"title":"$title","format":3,"revision":"1"}');
        add('term_bank_1.json', jsonEncode(rows));
        final File zip = File('${root.path}/$title.zip')
          ..writeAsBytesSync(ZipEncoder().encode(archive)!);
        final FushiImportResult imported = await FushiDicts.importDictionary(
          zip.path,
          '${root.path}/out_$title',
        );
        expect(imported.success, isTrue, reason: imported.error);
        return '${root.path}/out_$title/${imported.title}';
      }

      List<Object> row(String expression, String reading, String gloss) =>
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

      setUpAll(() async {
        FushiDicts.nativeLibraryPath = lib;
        await FushiDicts.preloadTransformsFrom(
          (String key) => File('../../fushi/$key').readAsString(),
        );
        root = Directory.systemTemp.createTempSync('fushi_excluded_dicts');
        final String gonePath = await importDict(gone, <List<Object>>[
          row('猫', 'ねこ', 'cat (gone)'),
          row('猫舌', 'ねこじた', 'cat tongue (gone)'),
        ]);
        final String keptPath = await importDict(kept, <List<Object>>[
          row('猫', 'ねこ', 'cat (kept)'),
        ]);
        FushiDicts.initializeTyped(termPaths: <String>[gonePath, keptPath]);
      });

      tearDownAll(() async {
        FushiDicts.releaseAllMappings();
        await FushiDicts.whenBackgroundBorrowsSettled();
        root.deleteSync(recursive: true);
      });

      test('同步 lookup：被排除词典不出现、不占名额；默认空集不变', () {
        final List<FushiLookupResult> baseline = FushiDicts.instance.lookup(
          '猫舌',
          maxResults: 1,
        );
        expect(baseline.single.term.expression, '猫舌');

        final List<FushiLookupResult> excluded = FushiDicts.instance.lookup(
          '猫舌',
          maxResults: 1,
          excludedDictionaries: const <String>{gone},
        );
        expect(excluded, hasLength(1));
        expect(excluded.single.term.expression, '猫');
        expect(
          excluded.single.term.glossaries.map((g) => g.dictName).toList(),
          <String>[kept],
        );

        final List<FushiLookupResult> unknown = FushiDicts.instance.lookup(
          '猫舌',
          maxResults: 1,
          excludedDictionaries: const <String>{'NoSuchDictionary', ''},
        );
        expect(unknown.single.term.expression, '猫舌');
      });

      test(
        '后台查词：hiddenDictionaries 进引擎（popupOnly 的 bestLength 不再算隐藏词典）',
        () async {
          final FushiLookupOutcome? visible = await FushiDicts.instance
              .lookupInBackground(
                const FushiLookupRequest(
                  text: '猫舌',
                  maxResults: 1,
                  popupOnly: true,
                ),
              );
          expect(visible?.bestLength, 2);

          final FushiLookupOutcome? hidden = await FushiDicts.instance
              .lookupInBackground(
                const FushiLookupRequest(
                  text: '猫舌',
                  maxResults: 1,
                  popupOnly: true,
                  hiddenDictionaries: <String>{gone},
                ),
              );
          expect(hidden, isNotNull);
          // 引擎排除后只剩 猫：只命中隐藏词典的 猫舌 既不占唯一名额，也不贡献高亮长度。
          expect(hidden!.bestLength, 1);
          expect(hidden.ffiCacheHit, isFalse);
          final List<Object?> cards =
              jsonDecode(hidden.popupJson!) as List<Object?>;
          expect(cards, hasLength(1));
          expect(jsonEncode(cards), contains('cat (kept)'));
          expect(jsonEncode(cards), isNot(contains('(gone)')));
        },
      );
    },
    skip: haveLib
        ? false
        : 'FUSHI_DICTS_LIB not set: build native/fushidicts (fushidicts_ffi) '
              'and point FUSHI_DICTS_LIB at it to run the native excluded-dictionaries test',
  );
}
