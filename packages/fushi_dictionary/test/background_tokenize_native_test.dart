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
        await FushiDicts.releaseAllMappingsAndSettle();
        mapped.writeAsBytesSync(bytes); // 映射已解除：覆盖写成功
        await again;
      });
    },
    skip: haveLib ? false : '没有 fushidicts_ffi 动态库（设 FUSHI_DICTS_LIB 指向构建好的库）',
  );
}
