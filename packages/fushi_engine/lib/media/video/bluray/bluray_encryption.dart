/// 判一段蓝光码流（BDAV `.m2ts`）是否仍处于 AACS 加密状态——**只判，不解**。
///
/// 加密原盘（以及把原盘逐字节拷出来的目录）的 MPLS / CLPI 是明文，标题、时长、章节
/// 照样解析得出来；但 `STREAM/*.m2ts` 的负载是密文，交给 libmpv 只会黑屏或花屏，
/// 没有任何可读的错误。在交给内核之前先认出来，供 AacsMediaSession 准备解密输入；
/// 本文件本身只判定封装，不读取播放配置或解密内容。
///
/// 判据与 libaacs 自己决定「这个单元要不要解」同源：BDAV 按 6144 字节的 aligned
/// unit 加密，每个单元由 32 个 192 字节的源包组成；首包 4 字节 TP_extra_header 的
/// 最高两位是 copy_permission_indicator，加密单元非零，解密工具解完会清零。单元的
/// 前 16 字节是明文，其余是密文——所以密文区里每个源包偏移 4 处的 TS 同步字节 0x47
/// 也会被打乱。两条同时成立才判加密：只看标志位，标志没清的已解密副本会被误判；
/// 只看同步字节，损坏的文件也会被当成加密盘。
library;

import 'dart:io';
import 'dart:typed_data';

/// BDAV 的 AACS 加密单元大小（32 × 192）。
const int kBlurayAlignedUnitBytes = 6144;

const int _kSourcePacketBytes = 192;
const int _kTsSyncByte = 0x47;

/// 兼容尚未接入解密输入的调用方；常规播放现由 AacsMediaSession 处理。
class BlurayEncryptedStreamException implements Exception {
  const BlurayEncryptedStreamException(this.streamPath);

  /// 被判为加密的那段码流。
  final String streamPath;

  @override
  String toString() =>
      'BlurayEncryptedStreamException: AACS-encrypted stream $streamPath';
}

/// [path] 是否是 BDAV 封装的码流文件（`.m2ts` 蓝光 / `.mts` AVCHD），大小写不敏感。
bool isBdavStreamPath(String path) {
  final String lower = path.toLowerCase();
  return lower.endsWith('.m2ts') || lower.endsWith('.mts');
}

/// 纯函数：一个完整的 aligned unit 是否是 AACS 密文。长度不足一个单元时返回 false。
///
/// 只对 BDAV（192 字节源包）成立，所以先用单元里的明文部分确认封装：首包的同步字节
/// （偏移 4，落在明文前 16 字节里）必须是 0x47。普通 188 字节 TS（`.ts` 录播、
/// 广播流）的首字节就是 0x47、最高两位恰好非零，偏移 4 却是负载——不先确认封装会把
/// 它们全判成加密（本机真实 `.ts` 样本实测过）。
bool isAacsEncryptedAlignedUnit(Uint8List unit) {
  if (unit.length < kBlurayAlignedUnitBytes) return false;
  if (unit[4] != _kTsSyncByte) return false;
  if (_looksLikePlainTransportStream(unit)) return false;
  final bool copyPermissionSet = (unit[0] & 0xC0) != 0;
  if (!copyPermissionSet) return false;
  // 第 0 包的同步字节落在明文前 16 字节里，不算；看密文区里的其余 31 包。
  for (int i = 1; i < kBlurayAlignedUnitBytes ~/ _kSourcePacketBytes; i++) {
    if (unit[i * _kSourcePacketBytes + 4] != _kTsSyncByte) return true;
  }
  return false;
}

/// 188 字节封装的普通 TS：每 188 字节一个同步字节。偏移 4 碰巧是 0x47 的普通 TS
/// 在这里被挡下（BDAV 密文里 188 / 376 处是密文，不会连着都是 0x47）。
bool _looksLikePlainTransportStream(Uint8List unit) =>
    unit[0] == _kTsSyncByte &&
    unit[188] == _kTsSyncByte &&
    unit[376] == _kTsSyncByte;

/// [streamPath] 这段 m2ts 是否仍是 AACS 密文。
///
/// 抽样文件开头与中段各一个单元（每个 6 KB，几十 GB 的正片也只读 12 KB）：任一单元
/// 是密文即判加密。文件打不开、短于一个单元时返回 false——那不是加密，交给播放
/// 内核报它自己的真实错误。
Future<bool> isAacsEncryptedStreamFile(String streamPath) async {
  RandomAccessFile? handle;
  try {
    handle = await File(streamPath).open();
    final int length = await handle.length();
    final int units = length ~/ kBlurayAlignedUnitBytes;
    if (units == 0) return false;
    for (final int unitIndex in <int>{0, units ~/ 2}) {
      await handle.setPosition(unitIndex * kBlurayAlignedUnitBytes);
      final Uint8List unit = await handle.read(kBlurayAlignedUnitBytes);
      if (isAacsEncryptedAlignedUnit(unit)) return true;
    }
    return false;
  } on FileSystemException {
    return false;
  } finally {
    await handle?.close();
  }
}
