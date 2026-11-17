import 'dart:io';

/// 原子写文本文件：先写同目录的 `<target>.tmp`（落盘 flush），再 rename **直接
/// 覆盖** [target]。读者要么看到旧文件、要么看到完整的新文件。
///
/// **绝不先 `delete()` 再 rename**：delete 与 rename 之间目标完全不存在，进程崩在
/// 这个窗口里旧内容就丢了。`File.rename` 在 Windows 与 POSIX 上都能覆盖已存在的
/// 目标，那一步既危险又多余。
///
/// `.tmp` 是 per-target 固定名：同一 [target] 的并发写者由调用方串行化。
///
/// 这是最底层的一层，只管「文本怎么落盘」；带业务合并语义的写入（例如书根
/// `manga.json` 的 PDF 文字层合并）在各自的上层做，不要塞进这里。
Future<void> writeTextFileAtomically(File target, String content) async {
  await target.parent.create(recursive: true);
  final File temporary = File('${target.path}.tmp');
  await temporary.writeAsString(content, flush: true);
  await temporary.rename(target.path);
}
