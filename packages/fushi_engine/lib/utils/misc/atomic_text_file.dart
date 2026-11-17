import 'dart:io';
import 'dart:math';

/// 本 isolate 的临时文件名标签：`pid` 区分进程，随机数区分同一进程里的各个
/// isolate（顶层变量每个 isolate 各有一份，单靠计数器跨 isolate 会重名）。
final String _temporaryTag =
    '$pid-${Random.secure().nextInt(1 << 32).toRadixString(16)}';

/// 本 isolate 内的写入序号，与 [_temporaryTag] 合起来让每次写入的临时文件名唯一。
int _temporarySequence = 0;

/// 一次写入用的临时文件：与 [target] 同目录（rename 不跨卷），每次调用给出一个
/// 新名字，以 `.tmp` 结尾。
File temporaryFileForAtomicWrite(File target) =>
    File('${target.path}.$_temporaryTag-${_temporarySequence++}.tmp');

/// 原子写文本文件：先写同目录的临时文件（落盘 flush），再 rename **直接覆盖**
/// [target]。读者要么看到旧文件、要么看到完整的新文件。
///
/// **绝不先删 [target] 再 rename**：删除与 rename 之间目标完全不存在，进程崩在
/// 这个窗口里旧内容就丢了。`File.rename` 在 Windows 与 POSIX 上都能覆盖已存在的
/// 目标，那一步既危险又多余。
///
/// 临时文件每次写入一个唯一名（[temporaryFileForAtomicWrite]），不是
/// `<target>.tmp` 这种 per-target 固定名：同一 [target] 可以有并发写者（漫画
/// OCR 的整卷任务与页级会话各在自己的 isolate 里写同一页的缓存，取消后还在
/// 收尾的旧任务与新任务也会撞同一页）。固定名下两个写者共用一个临时文件，一个
/// 写到一半、另一个 rename，目标就成了半截 JSON；或者一个 rename 走了文件，
/// 另一个的 rename 找不到源而失败（BUG-4801）。唯一名下各写各的，后 rename 的
/// 覆盖先 rename 的，两份都是完整内容。
///
/// 没解决的平台限制：Windows 上两个写者在同一瞬间 rename 到同一个目标时，
/// `MoveFileEx` 会让其中一个以「拒绝访问」失败（POSIX 没有）。那个写者照常抛错，
/// 目标仍是另一个写者的完整内容。要连这个也消掉得做跨 isolate 的互斥，这里不做。
///
/// 写入或 rename 失败时删掉本次的临时文件再把原错误抛出去（唯一名不会被下一次
/// 写入覆盖，不删就一直留在盘上）。进程在写入中途被杀时会留下一个 `.tmp`，
/// 它不会被当成目标读到。
///
/// 这是最底层的一层，只管「文本怎么落盘」；带业务合并语义的写入（例如书根
/// `manga.json` 的 PDF 文字层合并）在各自的上层做，不要塞进这里。
Future<void> writeTextFileAtomically(File target, String content) async {
  await target.parent.create(recursive: true);
  final File temporary = temporaryFileForAtomicWrite(target);
  try {
    await temporary.writeAsString(content, flush: true);
    await temporary.rename(target.path);
  } on Object {
    if (temporary.existsSync()) temporary.deleteSync();
    rethrow;
  }
}
