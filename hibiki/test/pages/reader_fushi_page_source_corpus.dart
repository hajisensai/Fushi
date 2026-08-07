import '../helpers/part_corpus.dart';

/// TODO-589: `reader_fushi_page.dart` 正被分批拆成主壳 + `reader_fushi/*.part.dart`
/// 一组 part 文件（零行为重构）。原来逐文件硬编码读单文件的静态守卫，凡断言落在已搬出
/// 主壳的方法体里，必须改读这份「合并语料」：主壳 + 全部 part 文件按固定顺序拼接。
///
/// part 文件里的方法仍是 2 空格缩进的 `extension on _ReaderFushiPageState` 成员，主壳
/// 顶层 class / 常量 / 其它方法照搬不动，所以基于方法签名 / 字符串切片的守卫逻辑零改写，
/// 只把数据源从「单文件」换成「合并语料」。
///
/// **part 清单是从磁盘枚举出来的，不是手写常量**：清单一旦手写，新增/改名一个 part 就
/// 意味着它的内容不在语料里，而 90+ 个消费方里那些 `isNot(contains(...))` 的**负向**断言
/// 会因此「真空通过」——不是符号真的没了，是根本没读到那个文件。枚举 + 排序（确定性）
/// 让新 part 自动进语料，负向断言不可能因为漏登记而假绿。
const String _readerFushiShell =
    'lib/src/pages/implementations/reader_fushi_page.dart';
const String kReaderFushiPartDir =
    'lib/src/pages/implementations/reader_fushi';

/// 主壳 + 磁盘上全部 `*.part.dart`（按路径排序，保证跨机器/跨次运行顺序确定）。
List<String> readerFushiPageFiles() => partCorpusFiles(
      shell: _readerFushiShell,
      partDir: kReaderFushiPartDir,
    );

/// 读「阅读器页合并语料」：主壳 + 全部 part 文件拼成单个字符串，供静态守卫切片/断言。
/// 统一把 CRLF 归一成 LF，与逐文件守卫此前的隐式假设一致。
String readReaderPageSource() => readPartCorpus(readerFushiPageFiles());
