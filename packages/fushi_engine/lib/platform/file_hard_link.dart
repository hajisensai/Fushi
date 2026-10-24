/// 硬链接：同一份磁盘内容的第二个文件名，不占第二份空间。
///
/// `dart:io` 没有建硬链接的 API（`Link` 是符号链接），直接调系统：Windows `CreateHardLinkW`、
/// 其它平台 libc `link()`。只用在「两个名字指向的内容都不会被原地改写」的地方——任何一边
/// 原地写（截断再写）另一边跟着变；先写临时文件再改名的写法换的是新文件，不影响另一边。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateHardLinkWNative =
    Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>);
typedef _CreateHardLinkWDart =
    int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>);
typedef _LinkNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _LinkDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

_CreateHardLinkWDart? _createHardLinkW;
_LinkDart? _link;
bool _resolved = false;

void _resolve() {
  if (_resolved) return;
  _resolved = true;
  try {
    if (Platform.isWindows) {
      _createHardLinkW = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_CreateHardLinkWNative, _CreateHardLinkWDart>(
            'CreateHardLinkW',
          );
    } else {
      final DynamicLibrary libc = Platform.isAndroid
          ? DynamicLibrary.open('libc.so')
          : DynamicLibrary.process();
      _link = libc.lookupFunction<_LinkNative, _LinkDart>('link');
    }
  } on Object {
    // 找不到符号：一律当作不支持，调用方回落复制。
  }
}

/// 在 [linkPath] 建一个指向 [existingPath] 的硬链接。成功 true；跨卷、文件系统不支持
/// （FAT / exFAT 等）、[linkPath] 已存在、平台拒绝一律 false，不抛——调用方回落复制。
bool tryCreateHardLink(String existingPath, String linkPath) {
  _resolve();
  final _CreateHardLinkWDart? win = _createHardLinkW;
  if (win != null) {
    final Pointer<Utf16> link = linkPath.toNativeUtf16();
    final Pointer<Utf16> existing = existingPath.toNativeUtf16();
    try {
      return win(link, existing, nullptr) != 0;
    } finally {
      malloc
        ..free(link)
        ..free(existing);
    }
  }
  final _LinkDart? posix = _link;
  if (posix == null) return false;
  final Pointer<Utf8> existing = existingPath.toNativeUtf8();
  final Pointer<Utf8> link = linkPath.toNativeUtf8();
  try {
    return posix(existing, link) == 0;
  } finally {
    malloc
      ..free(existing)
      ..free(link);
  }
}
