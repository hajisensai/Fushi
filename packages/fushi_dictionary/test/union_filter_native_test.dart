import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// 联合过滤器（原生引擎的跨词典键过滤器）在真原生库上的 Dart 侧接线：装载词典后引擎
/// 自己在后台备好它、缓存落到 [FushiDicts.unionFilterCacheDirectory]；过滤器就绪后
/// 查词结果是词典里该有的那些（内存版与落盘版一致）；引擎释放后词典目录立刻删得动。
/// 「有过滤器 / 没过滤器逐字段相同」这条对照在 Dart 侧做不出确定的无过滤器一方
/// （构建是后台的、小词典亚毫秒就绪），由 ctest `union_filter_test` 在引擎层钉；
/// 无假阴性、坏缓存重建、作废时机、销毁时收回构建线程也在那里。
///
/// 需要构建好的 fushidicts_ffi 动态库：设 `FUSHI_DICTS_LIB=<绝对路径>`（与
/// corpus_terms_native_test 同一个变量），没有时整组 skip 并说明原因。
void main() {
  final String? lib = Platform.environment['FUSHI_DICTS_LIB'];
  final bool haveLib = lib != null && lib.isNotEmpty && File(lib).existsSync();

  group(
    '联合过滤器（真原生库）',
    () {
      late Directory root;
      late String firstPath;
      late String secondPath;
      late String freqPath;

      Future<String> importDict(String title, Map<String, String> banks) async {
        final Archive archive = Archive();
        void add(String name, String content) {
          final List<int> bytes = utf8.encode(content);
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }

        add('index.json', '{"title":"$title","format":3,"revision":"1"}');
        banks.forEach(add);
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

      String describe(List<FushiLookupResult> results) => results
          .map(
            (FushiLookupResult r) =>
                '${r.matched}|${r.term.expression}|${r.term.reading}|'
                '${r.term.glossaries.map((g) => '${g.dictName}:${g.glossary}').join(',')}|'
                '${r.term.frequencies.map((f) => f.dictName).join(',')}',
          )
          .join('\n');

      Future<void> waitReady() async {
        final Stopwatch watch = Stopwatch()..start();
        while (!FushiDicts.instance.unionFilterReady) {
          if (watch.elapsed > const Duration(seconds: 30)) {
            fail('联合过滤器 30 秒内没有就绪');
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      void load() {
        FushiDicts.initializeTyped(
          termPaths: <String>[firstPath, secondPath],
          freqPaths: <String>[freqPath],
        );
      }

      setUpAll(() async {
        FushiDicts.nativeLibraryPath = lib;
        await FushiDicts.preloadTransformsFrom(
          (String key) => File('../../fushi/$key').readAsString(),
        );
        root = Directory.systemTemp.createTempSync('fushi_union_filter');
        firstPath = await importDict('UnionDartFirst', <String, String>{
          'term_bank_1.json': jsonEncode(<List<Object>>[
            row('猫', 'ねこ', 'cat'),
            row('食べる', 'たべる', 'to eat'),
          ]),
        });
        secondPath = await importDict('UnionDartSecond', <String, String>{
          'term_bank_1.json': jsonEncode(<List<Object>>[
            row('猫', 'ねこ', 'feline'),
            row('犬', 'いぬ', 'dog'),
          ]),
        });
        freqPath = await importDict('UnionDartFreq', <String, String>{
          'term_meta_bank_1.json': jsonEncode(<List<Object>>[
            <Object>['猫', 'freq', 120],
            <Object>['犬', 'freq', 300],
          ]),
        });
      });

      tearDownAll(() async {
        FushiDicts.unionFilterCacheDirectory = null;
        FushiDicts.releaseAllMappings();
        await FushiDicts.whenBackgroundBorrowsSettled();
        root.deleteSync(recursive: true);
      });

      test('装载后自动就绪并落盘；过滤器就绪后查到的就是词典里的内容', () async {
        const List<String> queries = <String>[
          '猫',
          '猫が食べた',
          '犬と猫',
          '存在しない',
          'いぬ',
          '食べた',
        ];

        // 不落盘（内存版）与落盘两种配置各装一遍：结果必须逐项相同。
        FushiDicts.unionFilterCacheDirectory = null;
        load();
        await waitReady();
        final List<String> inMemory = <String>[
          for (final String q in queries)
            describe(FushiDicts.instance.lookup(q)),
        ];

        final Directory cache = Directory('${root.path}/index_cache');
        FushiDicts.unionFilterCacheDirectory = cache.path;
        load();
        // 装完立刻查一遍（过滤器多半还没就绪，那时走各词典自己的过滤器；时序不
        // 保证，所以它只是多一道一致性检查，不是「无过滤器」对照），再等就绪后查。
        final List<String> early = <String>[
          for (final String q in queries)
            describe(FushiDicts.instance.lookup(q)),
        ];
        await waitReady();
        final List<String> ready = <String>[
          for (final String q in queries)
            describe(FushiDicts.instance.lookup(q)),
        ];

        expect(early, inMemory);
        expect(ready, inMemory);

        // 过滤器在场时的结果按词典内容逐条核对：过滤器若漏判（假阴性）或把词典
        // 认错，下面某一条就对不上。
        String firstLine(int query) => ready[query].split('\n').first;
        // 猫：两本释义词典都命中，频率词典也命中。
        expect(firstLine(0), startsWith('猫|猫|ねこ|'));
        expect(firstLine(0), contains('UnionDartFirst:'));
        expect(firstLine(0), contains('cat'));
        expect(firstLine(0), contains('UnionDartSecond:'));
        expect(firstLine(0), contains('feline'));
        expect(firstLine(0), endsWith('|UnionDartFreq'));
        // 句首最长匹配。
        expect(firstLine(1), startsWith('猫|猫|ねこ|'));
        // 犬只在第二本里：不能带出第一本的释义。
        expect(firstLine(2), startsWith('犬|犬|いぬ|'));
        expect(firstLine(2), contains('UnionDartSecond:'));
        expect(firstLine(2), contains('dog'));
        expect(firstLine(2), isNot(contains('UnionDartFirst:')));
        expect(firstLine(2), endsWith('|UnionDartFreq'));
        // 哪本都没有。
        expect(ready[3], isEmpty);
        // 按读音命中。
        expect(ready[4], contains('|犬|いぬ|'));
        expect(ready[4], contains('dog'));
        // 去屈折后命中，只在第一本里，频率词典没有它。
        expect(ready[5], contains('|食べる|たべる|'));
        expect(ready[5], contains('to eat'));
        expect(ready[5], isNot(contains('UnionDartFreq')));

        final List<String> files = <String>[
          for (final FileSystemEntity e in cache.listSync())
            e.uri.pathSegments.last,
        ];
        expect(files, hasLength(1));
        expect(files.single, startsWith('union-'));
        expect(files.single, endsWith('.filter'));
      });

      test('刚装载就释放：词典目录立刻删得动', () async {
        // 复制一本词典出来装载，装完不等过滤器就释放并删目录。Windows 上只要还有
        // 线程撑着索引文件的映射，这里的改名 / 删除就会抛（BUG-1756 的形状）。新导入的
        // 词典索引是 key.index（旧式词典才有 hash.table）。
        // 只在 Windows 上有判别力（POSIX 允许改名 / 删除被映射的文件），且是概率性的
        // （构建线程要恰好还没跑完）；确定性的保证是引擎析构里叫停并等线程退出，
        // 由 ctest `union_filter_test` 用映射计数钉。
        final Directory copy = Directory('${root.path}/copy_first')
          ..createSync();
        for (final FileSystemEntity e in Directory(firstPath).listSync()) {
          if (e is File) {
            e.copySync('${copy.path}/${e.uri.pathSegments.last}');
          }
        }
        FushiDicts.unionFilterCacheDirectory = '${root.path}/index_cache';
        for (int round = 0; round < 5; round++) {
          FushiDicts.initializeTyped(termPaths: <String>[copy.path]);
          FushiDicts.releaseAllMappings();
          await FushiDicts.whenBackgroundBorrowsSettled();
          final File table = File('${copy.path}/key.index');
          final File moved = table.renameSync('${copy.path}/key.index.moved');
          moved.renameSync(table.path);
        }
        copy.deleteSync(recursive: true);
        expect(copy.existsSync(), isFalse);
      });
    },
    skip: haveLib
        ? false
        : '需要 FUSHI_DICTS_LIB 指向构建好的 fushidicts_ffi 动态库（当前: ${lib ?? '未设置'}）',
  );
}
