import '../helpers/part_corpus.dart';

/// TODO-587: `reader_fushi_history_page.dart` 被拆成主壳 + `reader_history/*.part.dart`
/// 一组 part 文件（card_widgets / remote / video / books / dialogs）。原来逐文件硬编码
/// 读单文件的静态守卫，现在读这份「合并语料」：主壳 + 全部 part 文件按固定顺序拼接。
///
/// part 文件里的方法仍是 2 空格缩进的 `extension on _ReaderFushiHistoryPageState` 成员，
/// 顶层类/常量也照搬不动，所以基于方法签名 / 类名 / 字符串切片的守卫逻辑零改写，只把
/// 数据源从「单文件」换成「合并语料」。
///
/// **part 清单从磁盘枚举，不是手写常量**（TODO-2707）：手写清单要靠人记得回来补，漏了
/// 没有任何反馈，而落在漏登记 part 里的**负向**断言（`isNot(contains(...))`）会因此
/// 「真空通过」——不是被禁的符号真的没了，是根本没读到那个文件。枚举 + 排序让新 part
/// 自动进语料。契约由 `reader_history_source_corpus_test.dart` 锁住。
const String _readerHistoryShell =
    'lib/src/pages/implementations/reader_fushi_history_page.dart';
const String kReaderHistoryPartDir =
    'lib/src/pages/implementations/reader_history';

/// 主壳 + 磁盘上全部 `*.part.dart`（按路径排序，保证跨机器/跨次运行顺序确定）。
List<String> readerHistoryFiles() => partCorpusFiles(
      shell: _readerHistoryShell,
      partDir: kReaderHistoryPartDir,
    );

/// 读「书架页合并语料」：主壳 + 全部 part 文件拼成单个字符串，供静态守卫切片/断言。
String readReaderHistorySource() => readPartCorpus(readerHistoryFiles());
