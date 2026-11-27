import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 只追加、超限保尾的行日志文件（BUG-5571）。
///
/// 旧写法（`VideoDiagLog` / `StudyDiagLog` 各抄一份）每追加一行就 `length()`，超了就
/// 把**整个文件**读回来、UTF-8 解码、`substring` 保尾到**正好**上限、再编码写回。保尾
/// 正好落在上限下方一点，于是文件一旦长满，**下一行就又超限**——稳态下每一行日志都是
/// 一次整文件读 + 解码 + 编码 + 重写，全在 UI isolate 上。视频诊断开着时每秒几十行，
/// 4 MB 的文件每行一来回就是十几 MB 的字符串分配：2026-11-27 视频页冻结里，主线程在
/// `VideoDiagLog._trimFile` 的 `substring` / `writeAsString` 大块分配里被 GC 标记拖住，
/// 两份 hang dump 都停在这里，一次卡 20.8 s。
///
/// 现在：
///  * 大小记在内存里（首次用到时 stat 一次），追加不再每行 stat；
///  * 超过 [maxBytes] 才裁，一裁裁到 [trimToBytes]（缺省 3/4 上限）——两次裁之间至少
///    隔 1/4 上限的新内容，裁剪摊到每行是常数；
///  * 裁剪全在字节层：只读要保留的尾部（[RandomAccessFile] 定位读），从第一个 `\n`
///    之后起留（`\n` 是单字节 ASCII，不会切进多字节 UTF-8 字符），原样写回——不解码、
///    不建字符串。
///
/// 调用方负责串行化（各日志自己的 `_chain`）：本类不加锁。
class CappedLogFile {
  CappedLogFile(this.file, {required this.maxBytes, int? trimToBytes})
    : trimToBytes = trimToBytes ?? maxBytes * 3 ~/ 4,
      assert(maxBytes > 0);

  final File file;

  /// 文件超过这个字节数就裁。
  final int maxBytes;

  /// 裁到不超过这个字节数（对齐行首后通常略少）。
  final int trimToBytes;

  /// 已知的文件大小；null = 还没量过（或外部改过文件，见 [forgetSize]）。
  int? _size;

  /// 追加 [text]（调用方自带换行）；超限则裁。
  Future<void> append(String text) async {
    final Uint8List bytes = utf8.encode(text);
    final int before = _size ?? await _lengthOrZero();
    await file.writeAsBytes(bytes, mode: FileMode.append);
    _size = before + bytes.length;
    if (_size! > maxBytes) await trim();
  }

  /// 超过 [maxBytes] 就裁到 [trimToBytes]（启动时调一次，接住上次运行留下的大文件）。
  Future<void> trimIfOver() async {
    final int size = _size ?? await _lengthOrZero();
    _size = size;
    if (size > maxBytes) await trim();
  }

  /// 外部直接写过 / 清空过文件后调用，下次追加重新 stat。
  void forgetSize() => _size = null;

  /// 无条件裁到 [trimToBytes]（对齐行首）。
  Future<void> trim() async {
    if (!await file.exists()) {
      _size = 0;
      return;
    }
    final RandomAccessFile raf = await file.open();
    Uint8List tail;
    try {
      final int length = await raf.length();
      if (length <= trimToBytes) {
        _size = length;
        return;
      }
      await raf.setPosition(length - trimToBytes);
      tail = await raf.read(trimToBytes);
    } finally {
      await raf.close();
    }
    final Uint8List kept = alignToLineStart(tail);
    await file.writeAsBytes(kept, flush: false);
    _size = kept.length;
  }

  /// 纯函数：从第一个 `\n` 之后起留（丢掉被截断的那段残行）；没有换行 / 换行在最后
  /// 就原样返回（单行比保留量还长，宁可留残行也不清空）。
  static Uint8List alignToLineStart(Uint8List tail) {
    final int nl = tail.indexOf(0x0A);
    if (nl < 0 || nl + 1 >= tail.length) return tail;
    return Uint8List.sublistView(tail, nl + 1);
  }

  Future<int> _lengthOrZero() async {
    try {
      return await file.length();
    } on FileSystemException {
      return 0;
    }
  }
}
