import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// 「我库里的例句」的词元来源（[FushiDicts.corpusTermsBorrowed]）在真原生库上的端到端：
/// 主 isolate 借句柄（[FushiDicts.borrowForBackground]）、后台 isolate 带库路径重建绑定、
/// 一次 FFI 处理一整批句子，返回原生线格式。原生语义（词典形 / UTF-16 / 拉丁词跳过）由
/// ctest `corpus_terms_ffi_test` 钉；这一组补上 Dart 封送与借用这段。
///
/// 需要构建好的 fushidicts_ffi 动态库：设 `FUSHI_DICTS_LIB=<绝对路径>`（与
/// background_tokenize_native_test 同一个变量），没有时整组 skip 并说明原因。
List<List<(int, int, String)>> decode(Uint8List bytes, int sentences) {
  final ByteData d = ByteData.sublistView(bytes);
  int at = 0;
  int u32() {
    final int v = d.getUint32(at, Endian.little);
    at += 4;
    return v;
  }

  final List<List<(int, int, String)>> out = <List<(int, int, String)>>[];
  for (int s = 0; s < sentences; s++) {
    final int n = u32();
    final List<(int, int, String)> tokens = <(int, int, String)>[];
    for (int i = 0; i < n; i++) {
      final int start = u32();
      final int len = u32();
      final int bytesLen = u32();
      tokens.add((
        start,
        len,
        utf8.decode(Uint8List.sublistView(bytes, at, at + bytesLen)),
      ));
      at += bytesLen;
    }
    out.add(tokens);
  }
  expect(at, bytes.length);
  return out;
}

void main() {
  final String? lib = Platform.environment['FUSHI_DICTS_LIB'];
  final bool haveLib = lib != null && lib.isNotEmpty && File(lib).existsSync();

  group(
    '语料词元（真原生库）',
    () {
      late Directory root;

      setUpAll(() async {
        FushiDicts.nativeLibraryPath = lib;
        await FushiDicts.preloadTransformsFrom(
          (String key) => File('../../fushi/$key').readAsString(),
        );
        root = Directory.systemTemp.createTempSync('fushi_corpus_terms');
        final Archive archive = Archive();
        void add(String name, String content) {
          final List<int> bytes = utf8.encode(content);
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }

        add('index.json', '{"title":"CorpusTerms","format":3,"revision":"1"}');
        add(
          'term_bank_1.json',
          jsonEncode(<Object>[
            <Object>[
              '食べる',
              'たべる',
              '',
              'v1',
              0,
              <String>['eat'],
              0,
              '',
            ],
            <Object>[
              '猫',
              'ねこ',
              '',
              '',
              0,
              <String>['cat'],
              0,
              '',
            ],
            <Object>[
              'go',
              '',
              '',
              'v',
              0,
              <String>['move'],
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
        FushiDicts.initializeTyped(
          termPaths: <String>['${root.path}/out/${imported.title}'],
        );
      });

      tearDownAll(() async {
        FushiDicts.releaseAllMappings();
        await FushiDicts.whenBackgroundBorrowsSettled();
        root.deleteSync(recursive: true);
      });

      test('后台批量：词典形 + UTF-16 区间，日英同一条路径', () async {
        expect(FushiDicts.instance.termDictionaryPaths, hasLength(1));
        final Uint8List? bytes = await FushiDicts.instance
            .borrowForBackground<Uint8List>(
              (int address, String? libraryPath) => Isolate.run(
                () => FushiDicts.corpusTermsBorrowed(
                  address,
                  libraryPath,
                  <String>['猫が食べた', 'We went home', ''],
                ),
              ),
            );
        expect(bytes, isNotNull);
        final List<List<(int, int, String)>> tokens = decode(bytes!, 3);
        expect(tokens[0], <(int, int, String)>[(0, 1, '猫'), (2, 3, '食べる')]);
        expect(tokens[1], <(int, int, String)>[(3, 4, 'go')]);
        expect(tokens[2], isEmpty);
      });
    },
    skip: haveLib
        ? false
        : 'FUSHI_DICTS_LIB not set: build native/fushidicts (fushidicts_ffi) '
              'and point FUSHI_DICTS_LIB at it to run the native corpus-terms test',
  );
}
