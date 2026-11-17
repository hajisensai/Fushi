import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

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
/// 「替换目标」这一步同一目标同一时刻只有一个写者在做（[_replaceTarget]）：
/// Windows 上两个 rename 同时替换同一个目标时，`MoveFileEx` 会让其中一个以
/// 「拒绝访问」失败（POSIX 的 rename 可以并发）。并发的写者因此排队替换、全部
/// 成功，最后替换的那份留在目标上。
///
/// 没管的一种：Windows 上别人正把 [target] 打开着读（`dart:io` 打开文件不带
/// `FILE_SHARE_DELETE`）时，rename 同样以「拒绝访问」失败。读者不经过这里，
/// 这个 helper 管不到。
///
/// 写入或 rename 失败时删掉本次的临时文件再把原错误抛出去（唯一名不会被下一次
/// 写入覆盖，不删就一直留在盘上）。抛出去的始终是写入 / rename 的那个错误：
/// 临时文件删不掉时留在盘上，不让清理的错误顶掉它。进程在写入中途被杀时也会
/// 留下一个 `.tmp`，它不会被当成目标读到。
///
/// 这是最底层的一层，只管「文本怎么落盘」；带业务合并语义的写入（例如书根
/// `manga.json` 的 PDF 文字层合并）在各自的上层做，不要塞进这里。
Future<void> writeTextFileAtomically(File target, String content) async {
  await target.parent.create(recursive: true);
  final File temporary = temporaryFileForAtomicWrite(target);
  try {
    await temporary.writeAsString(content, flush: true);
    await _replaceTarget(temporary, target);
  } on Object {
    _discardTemporary(temporary);
    rethrow;
  }
}

/// 删掉一次失败写入留下的临时文件。
///
/// 删不掉就留着（Windows 上杀软 / 索引器正拿着刚写完的文件时会这样）：调用方要
/// 看到的是写入 / rename 为什么失败，这里再抛就把那个错误顶掉了。留下的文件以
/// `.tmp` 结尾，不会被当成目标读到。
void _discardTemporary(File temporary) {
  try {
    if (temporary.existsSync()) temporary.deleteSync();
  } on FileSystemException {
    // 见上：清理失败不改变这次写入的结局。
  }
}

/// 把写好的 [temporary] rename 到 [target] 上。
///
/// POSIX 的 rename 原子、可并发，直接做。Windows 上并发替换同一个目标会有一个
/// 「拒绝访问」（BUG-4801），所以那里同一目标的替换要互斥，而写者分散在不同的
/// isolate（整卷任务与页级会话）甚至不同进程里，Dart 层的队列够不着，只能用
/// 操作系统的锁：
///
/// - 锁是 [_windowsReplaceLockFile] 上按目标路径哈希出来的一个字节的区间锁
///   （`LockFileEx`，阻塞等待）。它按句柄算，同进程的不同 isolate、不同进程都
///   互斥；不同目标落在不同字节上互不相干（哈希撞上只是多排一次队）。
/// - 持有者崩溃或被杀时句柄随进程关闭，系统自动放锁，不会留下死锁；锁文件
///   始终是 0 字节、整个系统一份、放在系统临时目录里，目标所在的目录不多出
///   任何文件。
/// - 本 isolate 内先在 [_windowsReplaceQueue] 上排队，任何时刻最多只有一个锁
///   请求交给 IO 线程去等，不会把 IO 线程占满而让持锁者自己的 rename 排不上。
///
/// 路径不同但指向同一个文件（junction / 符号链接 / 8.3 短名）的两个写者算不到
/// 同一个字节上，互斥不了；同一份数据的写者都从同一个根路径拼出目标，不会这样。
Future<void> _replaceTarget(File temporary, File target) {
  if (!Platform.isWindows) {
    return temporary.rename(target.path);
  }
  final Future<void> previous = _windowsReplaceQueue;
  final Completer<void> done = Completer<void>();
  _windowsReplaceQueue = done.future;
  return () async {
    await previous;
    try {
      final RandomAccessFile lock = await _windowsReplaceLockFile.open(
        mode: FileMode.append,
      );
      try {
        final int offset = replaceLockOffsetForTarget(target);
        await lock.lock(FileLock.blockingExclusive, offset, offset + 1);
        try {
          await temporary.rename(target.path);
        } finally {
          await lock.unlock(offset, offset + 1);
        }
      } finally {
        await lock.close();
      }
    } finally {
      done.complete();
    }
  }();
}

/// 本 isolate 内排队做替换的队尾（只在 Windows 上用，见 [_replaceTarget]）。
/// 它只表示「前一个做完了」，前一个的成败由它自己的调用方拿到，不经这里传。
Future<void> _windowsReplaceQueue = Future<void>.value();

/// Windows 上替换目标用的锁文件：系统临时目录里固定的一个，内容永远为空（锁的是
/// 文件末尾之外的字节区间）。被清理工具删掉也无妨，下次写入时重新建出来。
final File _windowsReplaceLockFile = File(
  p.join(Directory.systemTemp.path, kAtomicWriteReplaceLockFileName),
);

/// [_windowsReplaceLockFile] 的文件名。
const String kAtomicWriteReplaceLockFileName = 'fushi-atomic-write.lock';

/// [target] 在锁文件上对应的字节偏移：规范化路径（Windows 上不分大小写）的
/// FNV-1a 32 位哈希。不用 `String.hashCode`——偏移要在不同进程、不同版本的
/// 运行时之间一致。
int replaceLockOffsetForTarget(File target) {
  int hash = 0x811c9dc5;
  for (final int byte in utf8.encode(p.canonicalize(target.path))) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}
