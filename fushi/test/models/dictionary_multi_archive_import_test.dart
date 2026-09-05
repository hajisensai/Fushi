// BUG-1903 / BUG-1904：用户把「日语辞典三件套」打成一个 zip 拖进来，报「不支持」。
//
// 实测（真引擎，用户原包）：
//   整包导入  → success=true title="旺文社国語辞典［第十一版］" term=219343
//              ——三本只进了一本，岩波与大辞林**静默丢弃**，还报成功。
//   逐本导入  → 岩波 189782 / 旺文社 219343 / 大辞林 1000000（正好卡上限）
//   MDX 头声明 → 岩波 189782 / 旺文社 220573 / 大辞林 1086308
//
// 于是两条根因各自成一条 bug：
//   BUG-1903 一包多典只进第一本（本文件前两组）
//   BUG-1904 大辞林被 kMaxEntriesPerBank 砍掉 86308 条（本文件第三组）
//
// 顺带排除掉两个看着像但不是的原因：`Encrypted=2`（旺文社正文 / 岩波 mdd）只是
// key-block-info 混淆，引擎自带 RIPEMD-128 解法、无需注册码；日文文件名也正常。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_import_manager.dart';

void main() {
  group('BUG-1903 判据：什么算「一包多典」', () {
    test('两本 MDX = 两本词典', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          'iwanami/iwanami.mdx',
          'iwanami/iwanami.css',
          'daijirin/daijirin.mdx',
          'daijirin/daijirin.mdd',
        ]),
        <String>['iwanami/iwanami.mdx', 'daijirin/daijirin.mdx'],
      );
    });

    test('用户那一包正是三本（岩波 / 旺文社 / 大辞林）', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          '岩波国語辞典8/iwakoku.css',
          '岩波国語辞典8/岩波国語辞典.mdd',
          '岩波国語辞典8/岩波国語辞典.mdx',
          '旺文社/obs.css',
          '旺文社/旺文社国語辞典［第十一版］.mdx',
          '三省堂 大辞林 [第三版]/daijirin2.css',
          '三省堂 大辞林 [第三版]/daijirin2.ddb',
          '三省堂 大辞林 [第三版]/daijirin2.mdd',
          '三省堂 大辞林 [第三版]/daijirin2.mdx',
        ]).length,
        3,
      );
    });

    test('Yomitan 包有几十个 term_bank 也只是一本，绝不能按文件数拆', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          'index.json',
          'term_bank_1.json',
          'term_bank_2.json',
          'term_bank_3.json',
          'tag_bank_1.json',
        ]),
        isEmpty,
        reason: '按 json 文件数拆会把一本 Yomitan 词典拆成几十本',
      );
    });

    test('单本 MDX 不触发拆包（长度 1，走原路径）', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          'daijirin2.mdx',
          'daijirin2.mdd',
          'daijirin2.css',
        ]).length,
        1,
      );
    });

    test('DSL 同样是一文件一典', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          'a/a.dsl',
          'b/b.dsl',
        ]).length,
        2,
      );
    });

    test('mdd / ddb / png 是资源，不算词典', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          'x/x.mdd',
          'x/x.ddb',
          'x/x.png',
          'x/x.css',
        ]),
        isEmpty,
      );
    });
  });

  group('BUG-1903 接线：分流真的挂在导入入口上', () {
    final String src = File(
      'lib/src/models/dictionary_import_manager.dart',
    ).readAsStringSync();

    test('importFromFile 里按判据分流到逐本导入', () {
      expect(
        src.contains('archivedDictionaryEntries(_readZipFileNames(file))'),
        isTrue,
      );
      expect(src.contains('_importArchivedDictionaries('), isTrue);
      expect(
        src.contains('if (archived.length > 1) {'),
        isTrue,
        reason: '只有真的多于一本才拆；单本必须走原路径，行为不变',
      );
    });

    test('三个「更新某一本」的入口不拆包', () {
      expect(
        src.contains(
          'if (replaceTarget == null &&\n'
          '        !forceReplaceExisting &&\n'
          '        sourceOverride == null &&',
        ),
        isTrue,
        reason:
            '强制重导 / 来源回填 / 显式替换目标的语义是「用这个包替换那一本」，'
            '拆包会把一次更新变成多次追加',
      );
    });

    test('每本只带同目录的 css，且单本失败不中断其余', () {
      expect(
        src.contains('Directory(path.dirname(dictionary.path))'),
        isTrue,
        reason: 'MDX 的样式表就在它自己那本的目录里，摊平会让 A 典样式套到 B 典头上',
      );
      expect(
        src.contains("ErrorLogService.instance.log('DictImport.multiArchive'"),
        isTrue,
      );
      expect(src.contains('failedNames.add('), isTrue);
    });

    test('临时解压目录在 finally 里清掉', () {
      expect(src.contains('import_multi_temp'), isTrue);
      expect(src.contains('} finally {'), isTrue);
    });
  });

  group('BUG-1904：整词典流不该套用 per-bank 上限', () {
    final String importer = File(
      '../native/fushidicts/fushidicts_src/importer.cpp',
    ).readAsStringSync();

    // 取整个 SimpleEntryAccumulator 类体。不要用「锚点 + 固定字符数」的窗口：
    // 注释一增删窗口就够不到目标，本守卫就这么误红过一次。
    String accumulatorBody() {
      final int at = importer.indexOf('class SimpleEntryAccumulator');
      expect(at, greaterThan(0), reason: '累加器不在了，守卫需更新');
      final int end = importer.indexOf('\n};', at);
      expect(end, greaterThan(at), reason: '找不到累加器类体结尾，守卫需更新');
      return importer.substring(at, end);
    }

    test('simple entries（MDX/DSL 整本词典流）用 kMaxTotalEntries 而非 per-bank', () {
      // 上限住在 SimpleEntryAccumulator::add()。MDX 导入改成流式之后，整词典流
      // 由累加器逐条喂进来，StarDict/DSL 的整表入口喂的是同一个累加器
      // （下一条守卫盯着这个共用关系）。
      final String body = accumulatorBody();
      expect(
        body.contains('records_.count >= kMaxTotalEntries'),
        isTrue,
        reason:
            '大辞林第四版声明 1086308 条，per-bank 的 100 万上限会把它砍到'
            '正好 1000000 还报 success；整词典级别的上限应当是 kMaxTotalEntries',
      );
      // 注意查的是代码形式：类体注释里就提到了 kMaxEntriesPerBank 这个名字，
      // 裸子串会假阳性。
      expect(
        body.contains('records_.count >= kMaxEntriesPerBank'),
        isFalse,
        reason:
            'kMaxEntriesPerBank 是给 Yomitan 单个 term_bank_N.json 设计的，'
            '同一个常量套到整词典流上语义就错位了',
      );
    });

    test('整表入口与流式入口共用同一条 per-entry 逻辑', () {
      final int at = importer.indexOf(
        'ImportResult dictionary_importer::write_simple_dict(',
      );
      expect(at, greaterThan(0), reason: 'write_simple_dict 不在了，守卫需更新');
      // 取到函数体结束，不用「锚点 + 固定字符数」——上面 accumulatorBody() 的注释
      // 已经记过这个教训，这条当时漏改：余量只有 243 字符，给 write_simple_dict
      // 补一段注释就够不到目标了（实测在 CI 的真单测门上红了一次）。
      final int end = importer.indexOf('\n}', at);
      expect(end, greaterThan(at), reason: '找不到 write_simple_dict 结尾，守卫需更新');
      final String body = importer.substring(at, end);
      expect(
        body.contains('SimpleEntryAccumulator accumulator(sink.blobs)'),
        isTrue,
        reason:
            'StarDict/DSL 的整表入口必须和 MDX 流式入口走同一个累加器；'
            '各自复制一份 per-entry 逻辑，上限/glossary 去重/记录布局就会分叉',
      );
    });

    test('BUG-2160：glossary blob 边压边写盘，不在内存里攒整本', () {
      // 旧写法把整本词典的压缩正文攒在 processed.glossaries，再抄进
      // glossary_buf 一次性写出——同一份 1.24 GB 在内存里存了两遍（实测
      // 389 MB 的 Wuliyanquan.mdx）。累加器现在拿到 blobs 流直接写，内存
      // 只留 hash -> (offset, size)。
      final String body = accumulatorBody();
      expect(
        body.contains('blobs_.write('),
        isTrue,
        reason: '新 glossary 必须当场写进 blobs.bin，而不是留在内存等最后统一写',
      );
      expect(
        RegExp(r'map<uint64_t,\s*BlobRef>').hasMatch(body),
        isTrue,
        reason: '去重表只该记 (offset, size)，不该再持有压缩后的字节',
      );
      // 简单词典的落盘路径不得再把 blob 区整个攒进一个缓冲。Yomitan 那条路径
      // 仍有同名 glossary_buf，但它是按 bank 缓冲（受单个 bank 大小约束），
      // 不是整本词典，所以只约束这一条路径，不做全文断言。
      // lastIndexOf：文件里先有一条前向声明（import_mdx 要用），定义在后面。
      final int fa = importer.lastIndexOf('void finish_simple_dict(');
      expect(fa, greaterThan(0), reason: 'finish_simple_dict 不在了，守卫需更新');
      final int fe = importer.indexOf('\n}', fa);
      expect(fe, greaterThan(fa), reason: '找不到 finish_simple_dict 结尾');
      final String finishBody = importer.substring(fa, fe);
      expect(
        finishBody.contains('glossary_buf'),
        isFalse,
        reason: 'glossary_buf 会是整个 blob 区的第二份全量副本，必须不再出现',
      );
      expect(
        finishBody.contains('blob_region_size'),
        isTrue,
        reason: 'term 记录偏移要按已写出的 blob 区大小平移，说明 blob 已在盘上',
      );
    });

    test('另外两道 OOM 保护仍在（不是把闸门全拆了）', () {
      expect(importer.contains('kMaxDataBufferBytes'), isTrue);
      expect(importer.contains('kMaxGlossarySizeBytes'), isTrue);
      expect(
        importer.contains(
          "static constexpr size_t kMaxTotalEntries = 10'000'000;",
        ),
        isTrue,
        reason: '整词典上限本身必须还是个有限值',
      );
    });

    test('per-bank 上限对 Yomitan 的三条 bank 路径原样保留', () {
      expect(
        'processed.count >= kMaxEntriesPerBank'.allMatches(importer).length,
        3,
        reason:
            'term / meta / kanji 三条 bank 路径仍该用 per-bank 上限——'
            '那里的语义是对的，本次只改整词典流那一处',
      );
    });
  });
}
