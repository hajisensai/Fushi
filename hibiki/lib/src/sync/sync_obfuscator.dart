import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

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
///
/// **A2（JSON 正文混淆）是 follow-up**，本类只服务 content 字节 + cover 字节，不碰
/// progress / statistics / audioBook 等 JSON（A2 会破坏第三方 ッツ 互通，待用户答复）。
class SyncObfuscator {
  SyncObfuscator._();

  /// 固定混淆密钥种子。常量、入库、人人可见——这是「防扫盘」不是「防破解」。
  static const String _keySeed = 'hibiki';

  /// 8 字节固定魔数：`HBKOBF` + 版本号 `0x01` + 保留 `0x00`。
  ///
  /// 选 8 字节是为了让旧明文「碰巧以这 8 字节开头」的概率可忽略；epub(zip) 头是
  /// `PK\x03\x04`、PNG 头是 `\x89PNG`、JPEG 头是 `\xFF\xD8` —— 都与本魔数不同，
  /// 故旧明文不会被误判为混淆产物。
  static final Uint8List magicHeader =
      Uint8List.fromList(<int>[0x48, 0x42, 0x4B, 0x4F, 0x42, 0x46, 0x01, 0x00]);

  /// magic header 字节数。
  static int get magicHeaderLength => magicHeader.length;

  /// 32 字节循环 keystream（`SHA-256("hibiki")`），懒加载缓存。
  static final Uint8List _keystream =
      Uint8List.fromList(sha256.convert(utf8.encode(_keySeed)).bytes);

  /// keystream 周期（SHA-256 = 32 字节）。
  static int get _period => _keystream.length;

  // ── 整块 API（cover 等小数据） ────────────────────────────────────────

  /// 混淆整块字节：返回 `magicHeader + XOR(plain)`（XOR 偏移从 0 起，不含 header）。
  static Uint8List obfuscateBytes(Uint8List plain) {
    final out = Uint8List(magicHeaderLength + plain.length);
    out.setRange(0, magicHeaderLength, magicHeader);
    for (var i = 0; i < plain.length; i++) {
      out[magicHeaderLength + i] = plain[i] ^ _keystream[i % _period];
    }
    return out;
  }

  /// 反混淆整块字节：带魔数则去头后 XOR 还原；**无魔数则原样返回**（旧明文兼容）。
  static Uint8List deobfuscateBytes(Uint8List data) {
    if (!hasMagicHeader(data)) {
      return data; // 旧明文（或短于 header）：原样透传。
    }
    final bodyLen = data.length - magicHeaderLength;
    final out = Uint8List(bodyLen);
    for (var i = 0; i < bodyLen; i++) {
      out[i] = data[magicHeaderLength + i] ^ _keystream[i % _period];
    }
    return out;
  }

  /// 判定 [data] 是否以 [magicHeader] 开头（即是否为本混淆器的产物）。
  static bool hasMagicHeader(Uint8List data) {
    if (data.length < magicHeaderLength) return false;
    for (var i = 0; i < magicHeaderLength; i++) {
      if (data[i] != magicHeader[i]) return false;
    }
    return true;
  }

  // ── 流式 API（content / 大文件 / 资产包） ─────────────────────────────

  /// 流式混淆：先发 [magicHeader]，再对每个分块逐字节 XOR（维护全局偏移）。
  ///
  /// 全局偏移与分块边界无关，所以反混淆端可用**任意**分块还原。
  static Stream<List<int>> obfuscateStream(Stream<List<int>> source) async* {
    yield Uint8List.fromList(magicHeader);
    var offset = 0;
    await for (final chunk in source) {
      final out = Uint8List(chunk.length);
      for (var i = 0; i < chunk.length; i++) {
        out[i] = chunk[i] ^ _keystream[(offset + i) % _period];
      }
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
      final out = Uint8List(bytes.length);
      for (var i = 0; i < bytes.length; i++) {
        out[i] = bytes[i] ^ _keystream[(offset + i) % _period];
      }
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
