import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fushi_compute/fushi_compute.dart';

/// 云盘同步「防扫盘」轻量字节混淆器（TODO-623 A1）。
///
/// 目标不是密码学安全的加密，而是让 Google Drive / OneDrive / Dropbox 等云盘的
/// 网页端 / 文件管理器「扫盘」时看到的 epub / 封面 / 音频 / 词典字节**不是明文**，
/// 防止随手翻看就能读到书名以外的正文内容。用户明确要求「简单 base64 / 固定 key
/// 这种就行」，所以这里用**固定密钥 XOR 流密码**（密钥常量 `"hibiki"` 经 SHA-256
/// 拉成 32 字节 keystream），不引入加密库、不做 KDF、不做密钥管理。
///
/// 设计要点：
/// - **位置无关循环 keystream**：第 `i` 个正文字节 XOR `keystream[i % 32]`，`i` 是
///   全局字节偏移（不含 header），与读取分块无关——所以流式分块怎么切都能还原。
/// - **magic header**（8 字节固定魔数）：混淆产物前缀 [magicHeader]。读时按是否带魔数
///   判定「混淆 vs 旧明文」，实现**混读向后兼容**：现有 Drive 明文（无魔数）原样读出
///   并能正常导入，新上传带魔数混淆，逐步重传即可全部变混淆，无需一键全重传。
/// - 文件名不混淆（同步协议靠文件名做对比/增量/冲突/删除），所以混淆零影响同步协议。
/// - **整块 / 流式两条路径的 XOR 在 native/fushi_compute**（`ffc_crypto_sync_xor`），按块
///   一次 FFI。**Range 随机访问路径（[deobfuscateBodyAt]）留在 Dart**：它是纯内存带宽
///   操作，FFI 只能借原生暂存区拷进拷出（`TypedData.address` 只给 `@Native` 静态绑定，
///   本包按路径动态加载；`asTypedList(finalizer:)` 免拷出在 Dart 3.13.5 AOT 下循环分配
///   必崩），实测比这里的 64 位字长循环慢（2026-10-19 Windows AOT，64 KiB / 1 MiB / 8 MiB
///   分块各 3 轮：Dart 520～1870 MB/s、FFI 550～1280 MB/s，9 组里 8 组 Dart 更快），按
///   「边界加粗后仍不比 Dart 快就不搬」留下。
///   两份 keystream 都是 SHA-256("hibiki")，回归向量
///   `fushi/test/sync/sync_obfuscator_vectors_test.dart` 同时钉住两条路径。
///   已同步到云端的文件靠这份 keystream 解开，**永远不能改**。
///
/// **A2（JSON 正文混淆）是 follow-up**，本类只服务 content 字节 + cover 字节，不碰
/// progress / statistics / audioBook 等 JSON（A2 会破坏第三方 ッツ 互通，待用户答复）。
class SyncObfuscator {
  SyncObfuscator._();

  /// 8 字节固定魔数：`HBKOBF` + 版本号 `0x01` + 保留 `0x00`。
  ///
  /// 选 8 字节是为了让旧明文「碰巧以这 8 字节开头」的概率可忽略；epub(zip) 头是
  /// `PK\x03\x04`、PNG 头是 `\x89PNG`、JPEG 头是 `\xFF\xD8` —— 都与本魔数不同，
  /// 故旧明文不会被误判为混淆产物。
  static final Uint8List magicHeader = Uint8List.fromList(<int>[
    0x48,
    0x42,
    0x4B,
    0x4F,
    0x42,
    0x46,
    0x01,
    0x00,
  ]);

  /// magic header 字节数。
  static int get magicHeaderLength => magicHeader.length;

  // ── 整块 API（cover 等小数据） ────────────────────────────────────────

  /// 混淆整块字节：返回 `magicHeader + XOR(plain)`（XOR 偏移从 0 起，不含 header）。
  static Uint8List obfuscateBytes(Uint8List plain) {
    final out = Uint8List(magicHeaderLength + plain.length);
    out.setRange(0, magicHeaderLength, magicHeader);
    out.setRange(magicHeaderLength, out.length, _xor(plain, 0));
    return out;
  }

  /// 反混淆整块字节：带魔数则去头后 XOR 还原；**无魔数则原样返回**（旧明文兼容）。
  static Uint8List deobfuscateBytes(Uint8List data) {
    if (!hasMagicHeader(data)) {
      return data; // 旧明文（或短于 header）：原样透传。
    }
    return _xor(Uint8List.sublistView(data, magicHeaderLength), 0);
  }

  /// 判定 [data] 是否以 [magicHeader] 开头（即是否为本混淆器的产物）。
  static bool hasMagicHeader(Uint8List data) {
    if (data.length < magicHeaderLength) return false;
    for (var i = 0; i < magicHeaderLength; i++) {
      if (data[i] != magicHeader[i]) return false;
    }
    return true;
  }

  // ── 随机访问 API（Range 流播） ────────────────────────────────────────

  /// 还原混淆正文里**从正文偏移 [bodyOffset] 起**的一段字节 [chunk]（不含 header）。
  ///
  /// keystream 与位置绑定、与分块无关，所以任意偏移起的一段都能单独还原——这正是
  /// 云盘视频不下载、按 `Range` 流播（seek 到中间）所需的能力。
  ///
  /// 流播时这里跑在 UI isolate 上、每秒过几 MB，所以按 64 位字长 XOR（循环次数降到
  /// 逐字节的 1/8）：从 [bodyOffset] 的相位起，keystream 每 8 字节一个字、4 个字一周期
  /// （32 字节周期是 8 的倍数，`8w mod 32 == 8(w & 3)`）；不足 8 字节的尾巴逐字节补。
  /// 为什么不走 FFI 见类注释。
  static Uint8List deobfuscateBodyAt(List<int> chunk, int bodyOffset) {
    if (bodyOffset < 0) {
      throw ArgumentError.value(bodyOffset, 'bodyOffset', 'negative');
    }
    final int length = chunk.length;
    final out = Uint8List(length)..setRange(0, length, chunk);
    final int phase = bodyOffset % _rangeKeyPeriod;
    final Uint64List key = _rangeKeyWordsAtPhase[phase];
    final int words = length >> 3;
    // 新分配的 Uint8List 从 0 偏移起，8 字节对齐，可以直接开 64 位视图。
    final Uint64List outWords = out.buffer.asUint64List(0, words);
    for (var w = 0; w < words; w++) {
      outWords[w] ^= key[w & 3];
    }
    for (var i = words << 3; i < length; i++) {
      out[i] ^= _rangeKeyBytes[(phase + i) % _rangeKeyPeriod];
    }
    return out;
  }

  /// Range 路径的 keystream：SHA-256("hibiki")，与 `ffc_crypto_sync_xor` 同一份。
  static final Uint8List _rangeKeyBytes = Uint8List.fromList(
    sha256.convert(utf8.encode('hibiki')).bytes,
  );

  static const int _rangeKeyPeriod = 32;

  /// keystream 的 32 种相位旋转，各以 4 个 64 位字存放：
  /// `_rangeKeyWordsAtPhase[s]` 的字节 `j` = `_rangeKeyBytes[(s + j) % 32]`。
  static final List<Uint64List> _rangeKeyWordsAtPhase =
      List<Uint64List>.generate(_rangeKeyPeriod, (int phase) {
        final rotated = Uint8List(_rangeKeyPeriod);
        for (var j = 0; j < _rangeKeyPeriod; j++) {
          rotated[j] = _rangeKeyBytes[(phase + j) % _rangeKeyPeriod];
        }
        return rotated.buffer.asUint64List();
      });

  /// 正文偏移 [bodyOffset] 起的一段字节与 keystream XOR（混淆 = 还原）。
  static Uint8List _xor(List<int> bytes, int bodyOffset) =>
      FushiComputeCrypto.instance.syncXor(bytes, bodyOffset);

  // ── 流式 API（content / 大文件 / 资产包） ─────────────────────────────

  /// 流式混淆：先发 [magicHeader]，再对每个分块逐字节 XOR（维护全局偏移）。
  ///
  /// 全局偏移与分块边界无关，所以反混淆端可用**任意**分块还原。
  static Stream<List<int>> obfuscateStream(Stream<List<int>> source) async* {
    yield Uint8List.fromList(magicHeader);
    var offset = 0;
    await for (final chunk in source) {
      final out = _xor(chunk, offset);
      offset += chunk.length;
      yield out;
    }
  }

  /// 流式反混淆：缓冲前 [magicHeaderLength] 字节判定 header。
  ///
  /// - 带魔数：丢弃 header，对其后字节按全局偏移 XOR 还原。
  /// - 无魔数（旧明文 / 短于 header）：**原样透传**全部字节（混读向后兼容）。
  static Stream<List<int>> deobfuscateStream(Stream<List<int>> source) async* {
    final head = BytesBuilder(copy: false);
    var headerDecided = false;
    var obfuscated = false;
    var offset = 0;

    Uint8List xorBody(List<int> bytes) {
      final out = _xor(bytes, offset);
      offset += bytes.length;
      return out;
    }

    await for (final chunk in source) {
      if (headerDecided) {
        // header 已判定，按既定模式处理后续分块。
        yield obfuscated ? xorBody(chunk) : Uint8List.fromList(chunk);
        continue;
      }
      head.add(chunk);
      if (head.length < magicHeaderLength) {
        continue; // 还凑不齐 header，继续缓冲。
      }
      final buffered = head.toBytes();
      headerDecided = true;
      if (hasMagicHeader(buffered)) {
        obfuscated = true;
        final body = buffered.sublist(magicHeaderLength);
        if (body.isNotEmpty) yield xorBody(body);
      } else {
        // 旧明文：把缓冲的全部字节原样吐出。
        obfuscated = false;
        yield buffered;
      }
    }

    // 流结束但 header 始终没凑齐（数据短于 header）：必是旧明文，原样透传。
    if (!headerDecided) {
      final buffered = head.toBytes();
      if (buffered.isNotEmpty) yield buffered;
    }
  }
}
