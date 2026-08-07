/// FNV-1a 稳定哈希的单一真相源（跨 isolate / 跨版本 / 跨端确定性，非安全用途）。
///
/// 收敛前全仓散落 5 份手写副本、3 种口径（video_manifest / deletion_propagation
/// 的 UTF-16 拆字节双轮版、audiobook_storage / hibiki_manga_ocr_host 的 UTF-8
/// 逐字节版、local_audio_db 的 16 位码元整体 XOR 弱版——后者即 BUG-1124 根因）。
/// 这些哈希值已持久化在备份资产名 / 缓存目录名 / 缓存文件名里，因此本文件的每个
/// 口径都必须**逐字节复现**既有输出；金标向量锁死在
/// `packages/fushi_core/test/stable_hash_test.dart`，任何漂移会被测试拦截。
library;

/// FNV-1a 32 位核心：把 [units] 逐个 XOR 进哈希再乘素数。
///
/// **刻意不对单元掩码**：喂 `utf8.encode(...)` 时是标准逐字节 FNV-1a；喂
/// `String.codeUnits` 时保留历史「16 位码元整体 XOR」口径（仅供旧键迁移路径
/// 复现旧输出用，新代码一律喂 UTF-8 字节——宽单元口径对 CJK 的扩散轮数减半，
/// 碰撞率显著更高，见 BUG-1124）。
int fnv1a32(Iterable<int> units) {
  int hash = 0x811c9dc5;
  for (final int unit in units) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// [fnv1a32] 的 8 位十六进制形态（左补零；持久化键 / 资产名用）。
String fnv1a32Hex(Iterable<int> units) =>
    fnv1a32(units).toRadixString(16).padLeft(8, '0');

/// FNV-1a 64 位核心。种子 `0xcbf29ce484222325` 在 Dart VM 里是**有符号**字面量
/// （= 负数），乘法按 64 位二补码回绕，`& 0xFFFFFFFFFFFFFFFF` 即 `& -1` 为恒等
/// ——与收敛前 `hibiki_manga_ocr_host._stableSlug` 的实现逐位一致。
int fnv1a64(Iterable<int> units) {
  int hash = 0xcbf29ce484222325;
  for (final int unit in units) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash;
}

/// [fnv1a64] 的十六进制形态。注意历史行为：哈希为负时 `toRadixString(16)` 带
/// `-` 号（17 字符，`padLeft(16)` 不再补零）——该形态已持久化进漫画 OCR 的
/// `vol_<slug>` 断点缓存目录名，**不得**「修正」成无符号 16 位十六进制。
String fnv1a64Hex(Iterable<int> units) =>
    fnv1a64(units).toRadixString(16).padLeft(16, '0');

/// FNV-1a 32 位、UTF-16 码元拆低/高字节各混一轮的口径（每码元 2 轮）。
///
/// 复现 video_manifest / deletion_propagation 的历史 `_stableHashHex`：这些
/// 哈希已固化在云端资产名（`__videos__/<base>_<hash>.<ext>`、墓碑标记文件名），
/// 口径不可更换。新代码起哈希请用 `fnv1a32Hex(utf8.encode(s))`。
String fnv1a32Utf16PairHex(String s) {
  int hash = 0x811c9dc5;
  for (final int c in s.codeUnits) {
    hash = (hash ^ (c & 0xff)) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
    hash = (hash ^ ((c >> 8) & 0xff)) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
