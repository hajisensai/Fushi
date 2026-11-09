// TyranoScript 打包游戏（Electron / NW.js 外壳）的目录结构判定。
//
// 判据只看引擎结构特征，不认 exe 名 / 标题 / 哈希（docs/agent/galgame-hooking.md §0
// 「只做引擎级适配」）：
//   * Electron：`resources/app.asar` + exe 同目录 `ffmpeg.dll`（与
//     native/galgame_hook/engine-support.yaml 里 tyrano_nwjs 的 directory_files_all
//     一致），且 asar 头的顶层目录里有 `tyrano/`（TyranoScript 运行时的固定目录）。
//   * NW.js：exe 同目录有 `nw.dll` + `ffmpeg.dll`（NW.js 运行时固定随包），应用本体是
//     NW.js 文档的前两种打包方式之一：exe 同目录的散文件（`package.json` + `tyrano/`），
//     或 exe 同目录的 `package.nw`（目录，或 zip，zip 时读中央目录找 `tyrano/`）。
//     第三种「zip 直接拼在 exe 末尾」不识别：要扫描整份 exe 尾部，代价与误判面都不值，
//     这类游戏落回原有的 hook 路径。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/mining/tyrano_dom/tyrano_asar.dart';
import 'package:path/path.dart' as p;

/// TyranoScript 运行时在应用根目录下的固定目录名。
const String kTyranoRuntimeDirName = 'tyrano';

/// [exePath] 所在目录是不是 Electron / NW.js 打包的 TyranoScript 游戏。
bool isTyranoElectronGameDirectory(String exePath) {
  final String dir = p.dirname(exePath);
  if (!File(p.join(dir, 'ffmpeg.dll')).existsSync()) return false;
  final File asar = File(p.join(dir, 'resources', 'app.asar'));
  if (asar.existsSync()) {
    final Set<String>? top = readAsarTopLevelEntries(asar.path);
    return top != null && top.contains(kTyranoRuntimeDirName);
  }
  return _isTyranoNwjsDirectory(dir);
}

bool _isTyranoNwjsDirectory(String dir) {
  if (!File(p.join(dir, 'nw.dll')).existsSync()) return false;
  final String packageNw = p.join(dir, 'package.nw');
  if (Directory(packageNw).existsSync()) {
    return Directory(p.join(packageNw, kTyranoRuntimeDirName)).existsSync();
  }
  if (File(packageNw).existsSync()) {
    return zipHasTopLevelDirectory(packageNw, kTyranoRuntimeDirName);
  }
  return File(p.join(dir, 'package.json')).existsSync() &&
      Directory(p.join(dir, kTyranoRuntimeDirName)).existsSync();
}

/// 读 asar 头（Chromium Pickle：`u32 4, u32 头大小, u32 载荷大小, u32 JSON 长度,
/// JSON`），返回顶层条目名；不是合法 asar 返回 null。只读文件开头，不读整包。
Set<String>? readAsarTopLevelEntries(String asarPath) =>
    AsarArchive.openSync(asarPath)?.topLevelEntries;

/// zip 的中央目录里有没有以 `<name>/` 开头的条目。只读文件尾部的中央目录，不解压。
/// ZIP64 / 损坏的 zip 返回 false。
bool zipHasTopLevelDirectory(String zipPath, String name) {
  RandomAccessFile? raf;
  try {
    raf = File(zipPath).openSync();
    final int length = raf.lengthSync();
    // EOCD 22 字节 + 最多 65535 字节注释。
    final int tailLength = length < 65557 ? length : 65557;
    raf.setPositionSync(length - tailLength);
    final Uint8List tail = raf.readSync(tailLength);
    final ByteData tailData = ByteData.sublistView(tail);
    int eocd = -1;
    for (int i = tail.length - 22; i >= 0; i--) {
      if (tailData.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return false;
    final int cdSize = tailData.getUint32(eocd + 12, Endian.little);
    final int cdOffset = tailData.getUint32(eocd + 16, Endian.little);
    if (cdOffset == 0xFFFFFFFF || cdOffset + cdSize > length) return false;
    raf.setPositionSync(cdOffset);
    final Uint8List cd = raf.readSync(cdSize);
    final ByteData cdData = ByteData.sublistView(cd);
    final String prefix = '$name/';
    int pos = 0;
    while (pos + 46 <= cd.length) {
      if (cdData.getUint32(pos, Endian.little) != 0x02014b50) return false;
      final int nameLength = cdData.getUint16(pos + 28, Endian.little);
      final int extraLength = cdData.getUint16(pos + 30, Endian.little);
      final int commentLength = cdData.getUint16(pos + 32, Endian.little);
      final int nameStart = pos + 46;
      if (nameStart + nameLength > cd.length) return false;
      final String entry = latin1
          .decode(cd.sublist(nameStart, nameStart + nameLength))
          .replaceAll('\\', '/');
      if (entry.startsWith(prefix)) return true;
      pos = nameStart + nameLength + extraLength + commentLength;
    }
    return false;
  } on Object {
    return false;
  } finally {
    raf?.closeSync();
  }
}
