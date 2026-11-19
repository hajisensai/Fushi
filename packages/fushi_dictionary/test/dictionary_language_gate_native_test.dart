import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// 词典语言把关（反馈 WIZUEQx1fY）在真原生库上的端到端：`initializeTyped` 的
/// `termLanguages` 经 FFI 把语言带进引擎，标成英语的词典不再被阿尔巴尼亚语的
/// -ur 规则查到 Our → O；未标注时行为不变；排序里 our 在 O 前面。引擎语义由 ctest
/// `dictionary_language_gate_lookup_test` 钉，这一组补上 Dart 封送这段。
///
/// 需要构建好的 fushidicts_ffi 动态库：设 `FUSHI_DICTS_LIB=<绝对路径>`（与
/// excluded_dictionaries_native_test 同一个变量），没有时整组 skip 并说明原因。
void main() {
  final String? lib = Platform.environment['FUSHI_DICTS_LIB'];
  final bool haveLib = lib != null && lib.isNotEmpty && File(lib).existsSync();

  group(
    '词典语言把关（真原生库）',
    () {
      late Directory root;
      late String dictPath;

      List<Object> row(String expression) => <Object>[
        expression,
        '',
        '',
        '',
        0,
        <String>['gloss of $expression'],
        0,
        '',
      ];

      bool deinflectsTo(List<FushiLookupResult> results, String expression) =>
          results.any(
            (FushiLookupResult r) =>
                r.term.expression == expression &&
                r.matched == 'Our' &&
                r.trace.isNotEmpty,
          );

      setUpAll(() async {
        FushiDicts.nativeLibraryPath = lib;
        await FushiDicts.preloadTransformsFrom(
          (String key) => File('../../fushi/$key').readAsString(),
        );
        root = Directory.systemTemp.createTempSync('fushi_dict_language_gate');
        final Archive archive = Archive();
        void add(String name, String content) {
          final List<int> bytes = utf8.encode(content);
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }

        // 整本无词性的 Yomitan 词典：空 rules 当通配，与 MDX / StarDict 同一形态。
        add('index.json', '{"title":"LangGateDart","format":3,"revision":"1"}');
        add(
          'term_bank_1.json',
          jsonEncode(<List<Object>>[row('our'), row('O')]),
        );
        final File zip = File('${root.path}/gate.zip')
          ..writeAsBytesSync(ZipEncoder().encode(archive)!);
        final FushiImportResult imported = await FushiDicts.importDictionary(
          zip.path,
          '${root.path}/out',
        );
        expect(imported.success, isTrue, reason: imported.error);
        dictPath = '${root.path}/out/${imported.title}';
      });

      tearDownAll(() async {
        FushiDicts.releaseAllMappings();
        await FushiDicts.whenBackgroundBorrowsSettled();
        root.deleteSync(recursive: true);
      });

      test('未标注语言：别的语言的还原链照旧接受，但 our 排在 O 前面', () {
        FushiDicts.initializeTyped(termPaths: <String>[dictPath]);
        final List<FushiLookupResult> results = FushiDicts.instance.lookup(
          'Our',
          maxResults: 16,
        );
        expect(results.first.term.expression, 'our');
        expect(deinflectsTo(results, 'O'), isTrue);
      });

      test('标成英语：Our 不再被阿尔巴尼亚语规则还原成 O，精确命中不受影响', () {
        FushiDicts.initializeTyped(
          termPaths: <String>[dictPath],
          termLanguages: <String, String>{dictPath: 'en-US'},
        );
        final List<FushiLookupResult> results = FushiDicts.instance.lookup(
          'Our',
          maxResults: 16,
        );
        expect(results.first.term.expression, 'our');
        expect(deinflectsTo(results, 'O'), isFalse);
        expect(
          FushiDicts.instance
              .lookup('O', maxResults: 16)
              .map((FushiLookupResult r) => r.term.expression),
          contains('O'),
        );
      });

      test('排期装载（scheduleTyped → loadPendingAsync）同样带上语言', () async {
        FushiDicts.scheduleTyped(
          termPaths: <String>[dictPath],
          termLanguages: <String, String>{dictPath: 'en'},
        );
        await FushiDicts.loadPendingAsync();
        expect(
          deinflectsTo(FushiDicts.instance.lookup('Our', maxResults: 16), 'O'),
          isFalse,
        );
      });
    },
    skip: haveLib
        ? null
        : 'set FUSHI_DICTS_LIB to a built fushidicts_ffi library to run',
  );
}
