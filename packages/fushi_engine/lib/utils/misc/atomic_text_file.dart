import 'dart:async';
import 'dart:collection';
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
/// Windows 上别人正把 [target] 打开着读（`dart:io` 打开文件不带
/// `FILE_SHARE_DELETE`）时，rename 同样以「拒绝访问」失败。与写者并发的读者用
/// [readAtomicallyWrittenTextFile] 读，它与这里的替换互斥。
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

/// 读一个由 [writeTextFileAtomically] 写的文本文件。
///
/// POSIX 上就是 `readAsString`。Windows 上 `dart:io` 打开文件不带
/// `FILE_SHARE_DELETE`，读者把 [target] 打开着的那一小段时间里，写者的 rename
/// 会以「拒绝访问」失败（BUG-4801）。所以读者在打开之前先取与写者同一个字节上的
/// **共享**锁（见 [_withWindowsTargetLock]）：写者拿着独占锁做 rename 时没有读者
/// 开着目标，读者之间互不排斥。
///
/// 与并发写者共用同一个目标的读者都要走这里（漫画 OCR 的逐页缓存）。不走这里
/// 直接 `readAsString` 的读者仍会让同一刻的写入失败。
///
/// [target] 不存在等读取错误原样抛出，调用方自己决定怎么处理。
Future<String> readAtomicallyWrittenTextFile(File target) {
  if (!Platform.isWindows) {
    return target.readAsString();
  }
  return _withWindowsTargetLock<String>(
    target,
    FileLock.blockingShared,
    target.readAsString,
  );
}

/// 把写好的 [temporary] rename 到 [target] 上。
///
/// POSIX 的 rename 原子、可并发，直接做。Windows 上并发替换同一个目标会有一个
/// 「拒绝访问」（BUG-4801），所以那里同一目标的替换要互斥
/// （[_withWindowsTargetLock] 的独占锁），锁里只有 rename。
Future<void> _replaceTarget(File temporary, File target) {
  if (!Platform.isWindows) {
    return temporary.rename(target.path);
  }
  return _withWindowsTargetLock<void>(
    target,
    FileLock.blockingExclusive,
    () => temporary.rename(target.path),
  );
}

/// Windows 上拿着 [target] 对应的锁做 [action]（写者 = 独占锁里 rename，读者 =
/// 共享锁里读）。
///
/// 写者与读者分散在不同的 isolate（整卷任务与页级会话）甚至不同进程里，Dart 层
/// 的队列够不着，只能用操作系统的锁：
///
/// - 锁是 [_windowsReplaceLockFile] 上按目标路径哈希出来的一个字节的区间锁
///   （`LockFileEx`，阻塞等待）。它按句柄算，同进程的不同 isolate、不同进程都
///   互斥；不同目标落在不同字节上互不相干（哈希撞上只是多排一次队）。
/// - 持有者崩溃或被杀时句柄随进程关闭，系统自动放锁，不会留下死锁；锁文件
///   始终是 0 字节、整个系统一份、放在系统临时目录里，目标所在的目录不多出
///   任何文件。
/// - 本 isolate 内同一个字节上的请求先在 [_windowsTargetQueues] 里排队（读者
///   也排）：交给 IO 线程去阻塞等锁的请求，等的一定是别的 isolate / 进程里的
///   持有者。不同目标各排各的，一个目标卡住（比如网络盘上的 rename 迟迟不
///   返回）不耽误别的目标。
/// - 同时在锁流程里的请求不超过 [kAtomicWriteMaxConcurrentLockSections] 个
///   （[_windowsLockSectionSlots]）：`dart:io` 每个 isolate 的 IO 服务口有限，
///   阻塞等锁的请求各占一个；占满之后持锁者自己的 rename / 解锁排在被占住的
///   口后面，就成了死锁。
///
/// 路径不同但指向同一个文件（junction / 符号链接 / 8.3 短名）的两个调用方算不到
/// 同一个字节上，互斥不了；同一份数据的读写者都从同一个根路径拼出目标，不会这样。
///
/// 系统临时目录不存在或不可写时锁文件打不开，这里抛 [FileSystemException]：
/// Windows 上的原子写与配套的读都依赖 `%TEMP%` 可用（BUG-4801 备注）。
Future<T> _withWindowsTargetLock<T>(
  File target,
  FileLock mode,
  Future<T> Function() action,
) async {
  final int offset = replaceLockOffsetForTarget(target);
  final Future<void>? previous = _windowsTargetQueues[offset];
  final Completer<void> done = Completer<void>();
  final Future<void> tail = done.future;
  _windowsTargetQueues[offset] = tail;
  try {
    if (previous != null) await previous;
    await _windowsLockSectionSlots.acquire();
    try {
      final RandomAccessFile lock = await _windowsReplaceLockFile.open(
        mode: FileMode.append,
      );
      try {
        await lock.lock(mode, offset, offset + 1);
        try {
          return await action();
        } finally {
          await lock.unlock(offset, offset + 1);
        }
      } finally {
        await lock.close();
      }
    } finally {
      _windowsLockSectionSlots.release();
    }
  } finally {
    if (identical(_windowsTargetQueues[offset], tail)) {
      _windowsTargetQueues.remove(offset);
    }
    done.complete();
  }
}

/// 本 isolate 内各目标（按锁字节偏移）排队的队尾，只在 Windows 上用，见
/// [_withWindowsTargetLock]。队尾只表示「前一个做完了」，前一个的成败由它自己的
/// 调用方拿到，不经这里传；一个偏移上没人排了就删掉这一项。
final Map<int, Future<void>> _windowsTargetQueues = <int, Future<void>>{};

/// 本 isolate 内同时处在锁流程里的请求数上限。`dart:io` 每个 isolate 最多 32 个
/// IO 服务口，留足余量给持锁者自己和别的文件操作。
const int kAtomicWriteMaxConcurrentLockSections = 8;

final _LockSectionSlots _windowsLockSectionSlots = _LockSectionSlots(
  kAtomicWriteMaxConcurrentLockSections,
);

/// 计数名额：先到先得，没有名额时按到达顺序等。
class _LockSectionSlots {
  _LockSectionSlots(this._free);

  int _free;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_free > 0) {
      _free -= 1;
      return Future<void>.value();
    }
    final Completer<void> waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  /// 有人在等就把名额直接交给队首，否则还回去。
  void release() {
    if (_waiters.isEmpty) {
      _free += 1;
    } else {
      _waiters.removeFirst().complete();
    }
  }
}

/// Windows 上读写互斥用的锁文件：系统临时目录里固定的一个，内容永远为空（锁的是
/// 文件末尾之外的字节区间）。被清理工具删掉也无妨，下次用到时重新建出来。
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
