/// Windows 光驱的原始 CDDA 读取：`CreateFileW(\\.\X:)` + `DeviceIoControl`。
///
/// 只用两条 IOCTL：`IOCTL_CDROM_READ_TOC`（音轨表）与 `IOCTL_CDROM_RAW_READ`
/// （按 2352 字节原始扇区读 PCM）。读盘是阻塞系统调用，调用方必须放在后台
/// isolate（见 `audio_cd_ripper.dart`），不要在 UI isolate 上跑。
///
/// 裸 FFI 而非 package:win32：win32 在本仓只是传递依赖（同
/// `windows_process_query.dart` 的说明）。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_disc.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

const int _genericRead = 0x80000000;
const int _fileShareReadWrite = 0x3;
const int _openExisting = 3;
const int _invalidHandle = -1;
const int _driveCdrom = 5;
const int _ioctlCdromReadToc = 0x24000;
const int _ioctlCdromRawRead = 0x2403E;
const int _trackModeCdda = 2;
const int _cookedSectorBytes = 2048;
const int _tocBytes = 4 + 100 * 8;
const int _rawReadInfoBytes = 16;

/// 单次 `RAW_READ` 的扇区上限。驱动普遍 ≤ 27，取 20 留余量。
const int kWindowsCdRawReadChunk = 20;

/// 路径所在盘符是否是光驱（`GetDriveTypeW == DRIVE_CDROM`）。非 Windows 恒 false。
bool isWindowsCdromPath(String path) {
  final String? root = _driveRoot(path);
  if (!Platform.isWindows || root == null) return false;
  return using(
    (Arena arena) =>
        _Kernel32.instance.getDriveType(root.toNativeUtf16(allocator: arena)) ==
        _driveCdrom,
  );
}

/// 光驱卷标（音频 CD 通常是 `Audio CD`），取不到为 null。
String? windowsVolumeLabel(String path) {
  final String? root = _driveRoot(path);
  if (!Platform.isWindows || root == null) return null;
  return using((Arena arena) {
    final Pointer<Utf16> label = arena<Uint16>(261).cast<Utf16>();
    final int ok = _Kernel32.instance.getVolumeInformation(
      root.toNativeUtf16(allocator: arena),
      label,
      261,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      0,
    );
    final String value = ok == 0 ? '' : label.toDartString().trim();
    return value.isEmpty ? null : value;
  });
}

/// `E:\foo` → `E:\`；不是盘符路径返回 null。
String? _driveRoot(String path) {
  final RegExpMatch? m = RegExp(r'^([A-Za-z]):').firstMatch(path);
  return m == null ? null : '${m.group(1)!.toUpperCase()}:\\';
}

/// 一个打开的光驱句柄。用完必须 [close]。
class WindowsAudioCdDrive {
  WindowsAudioCdDrive._(this._handle);

  /// 打开 [path] 所在盘符的光驱。不是光驱 / 打不开时抛 [AudioCdException]。
  factory WindowsAudioCdDrive.open(String path) {
    final String? root = _driveRoot(path);
    if (!Platform.isWindows || root == null || !isWindowsCdromPath(path)) {
      throw AudioCdException('$path is not a CD drive');
    }
    final int handle = using(
      (Arena arena) => _Kernel32.instance.createFile(
        '\\\\.\\${root.substring(0, 2)}'.toNativeUtf16(allocator: arena),
        _genericRead,
        _fileShareReadWrite,
        nullptr,
        _openExisting,
        0,
        0,
      ),
    );
    if (handle == _invalidHandle || handle == 0) {
      throw AudioCdException('Cannot open drive $root');
    }
    return WindowsAudioCdDrive._(handle);
  }

  int _handle;

  /// 读音轨表，只含音频轨。无盘 / 读不出时抛 [AudioCdException]。
  List<AudioCdTrack> readToc() => using((Arena arena) {
    final Pointer<Uint8> out = arena<Uint8>(_tocBytes);
    final int got = _ioctl(nullptr, 0, out, _tocBytes, arena);
    if (got < 0) throw const AudioCdException('Cannot read the disc TOC');
    return parseCdromToc(Uint8List.fromList(out.asTypedListOutOfLine(got)));
  });

  /// 从 [lba] 起读 [count] 个原始扇区的 PCM。驱动报错返回 null（由调用方
  /// 决定重试 / 逐扇区降级）。[count] ≤ [kWindowsCdRawReadChunk]。
  Uint8List? readSectors(int lba, int count) => using((Arena arena) {
    final Pointer<Uint8> info = arena<Uint8>(_rawReadInfoBytes);
    // RAW_READ_INFO { LARGE_INTEGER DiskOffset; ULONG SectorCount; TRACK_MODE_TYPE TrackMode; }
    ByteData.sublistView(info.asTypedListOutOfLine(_rawReadInfoBytes))
      ..setInt64(0, lba * _cookedSectorBytes, Endian.little)
      ..setUint32(8, count, Endian.little)
      ..setUint32(12, _trackModeCdda, Endian.little);
    final int size = count * kCddaRawSectorBytes;
    final Pointer<Uint8> out = arena<Uint8>(size);
    final int got = _ioctl(
      info,
      _rawReadInfoBytes,
      out,
      size,
      arena,
      code: _ioctlCdromRawRead,
    );
    return got < 0 ? null : Uint8List.fromList(out.asTypedListOutOfLine(got));
  });

  int _ioctl(
    Pointer<Uint8> input,
    int inputBytes,
    Pointer<Uint8> output,
    int outputBytes,
    Arena arena, {
    int code = _ioctlCdromReadToc,
  }) {
    if (_handle == _invalidHandle) {
      throw const AudioCdException('Drive already closed');
    }
    final Pointer<Uint32> returned = arena<Uint32>();
    final int ok = _Kernel32.instance.deviceIoControl(
      _handle,
      code,
      input.cast(),
      inputBytes,
      output.cast(),
      outputBytes,
      returned,
      nullptr,
    );
    return ok == 0 ? -1 : returned.value;
  }

  void close() {
    if (_handle == _invalidHandle) return;
    _Kernel32.instance.closeHandle(_handle);
    _handle = _invalidHandle;
  }
}

typedef _CreateFileNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CreateFileDart =
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _DeviceIoControlNative =
    Int32 Function(
      IntPtr,
      Uint32,
      Pointer<Void>,
      Uint32,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef _DeviceIoControlDart =
    int Function(
      int,
      int,
      Pointer<Void>,
      int,
      Pointer<Void>,
      int,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);
typedef _GetDriveTypeNative = Uint32 Function(Pointer<Utf16>);
typedef _GetDriveTypeDart = int Function(Pointer<Utf16>);
typedef _GetVolumeInformationNative =
    Int32 Function(
      Pointer<Utf16>,
      Pointer<Utf16>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Utf16>,
      Uint32,
    );
typedef _GetVolumeInformationDart =
    int Function(
      Pointer<Utf16>,
      Pointer<Utf16>,
      int,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Utf16>,
      int,
    );

/// kernel32 函数表。每个 isolate 各自懒加载一份（抓轨在后台 isolate 里跑）。
class _Kernel32 {
  _Kernel32._(DynamicLibrary lib)
    : createFile = lib.lookupFunction<_CreateFileNative, _CreateFileDart>(
        'CreateFileW',
      ),
      deviceIoControl = lib
          .lookupFunction<_DeviceIoControlNative, _DeviceIoControlDart>(
            'DeviceIoControl',
          ),
      closeHandle = lib.lookupFunction<_CloseHandleNative, _CloseHandleDart>(
        'CloseHandle',
      ),
      getDriveType = lib.lookupFunction<_GetDriveTypeNative, _GetDriveTypeDart>(
        'GetDriveTypeW',
      ),
      getVolumeInformation = lib
          .lookupFunction<
            _GetVolumeInformationNative,
            _GetVolumeInformationDart
          >('GetVolumeInformationW');

  static final _Kernel32 instance = _Kernel32._(
    DynamicLibrary.open('kernel32.dll'),
  );

  final _CreateFileDart createFile;
  final _DeviceIoControlDart deviceIoControl;
  final _CloseHandleDart closeHandle;
  final _GetDriveTypeDart getDriveType;
  final _GetVolumeInformationDart getVolumeInformation;
}
