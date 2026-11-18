/// 媒体文件落在哪块盘上：给「同一块盘上的整片读盘任务排队」用（内封字幕整轨抽取的
/// 下一集预热，见 `video_subtitle_source.dart` 的 `_awaitBackgroundDiskTurn`）。
///
/// 两个整片顺序读（ffmpeg 抽字幕）同时读一块机械盘 / 慢 USB 盘时，磁头在两个文件间
/// 来回跳，两边都比单独读慢得多，还会拖慢 libmpv 正在播放的那条流。判据必须是真实的
/// 盘 / 卷，而不是「同一个目录」之类的近似：剧集常按季分目录但在同一块盘上，而两个
/// 盘符也可能是同一块物理盘的两个分区。
///
/// - Windows：`GetVolumePathNameW` → 卷挂载点 → `GetVolumeNameForVolumeMountPointW` →
///   卷 GUID → `IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS` 拿到卷所在的**物理盘号**
///   （跨盘的动态卷 / 存储池有多个）。网络共享按共享根（`\\server\share\`）算一块盘。
///   拿不到盘号（虚拟盘 / 驱动不支持）退到卷 GUID。
/// - Linux / Android：`stat -c %d` 取文件系统设备号，再经 sysfs `/sys/dev/block/<maj:min>`
///   归到所属整盘（分区 → 父盘）；归不到（btrfs 子卷、dm、网络文件系统）就用设备号。
/// - macOS：`stat -f %d` 的设备号（卷级；同一 APFS 容器里的几个卷算不同的盘）。
/// - 其它平台 / 任何一步失败：null = 判不出。
///
/// 判不出时调用方按「可能是同一块盘」处理（[mayShareDisk]）：排队的代价只是预热晚一点
/// 开始，并发的代价是当前集的抽取和播放一起变慢。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// [a] 与 [b] 两个盘标识（[mediaDiskIdentity]）**可能**是同一块盘：任一判不出（null）
/// 或有交集即为 true。
bool mayShareDisk(Set<String>? a, Set<String>? b) {
  if (a == null || b == null) return true;
  return a.any(b.contains);
}

/// 按所在目录缓存：同一目录的文件必在同一卷上，一季的各集只问一次系统。
final Map<String, Future<Set<String>?>> _identityByDirectory =
    <String, Future<Set<String>?>>{};

/// [path] 所在的盘（见库注释）。不抛；判不出返回 null。
Future<Set<String>?> mediaDiskIdentity(String path) {
  final String dir = p.dirname(p.absolute(path));
  return _identityByDirectory.putIfAbsent(dir, () async {
    try {
      if (Platform.isWindows) {
        // FFI 调用对断开的网络共享可能阻塞数秒：放后台 isolate，不卡调用方。
        return await Isolate.run(() => _windowsDiskIdentity(dir));
      }
      if (Platform.isLinux || Platform.isAndroid) {
        return await _linuxDiskIdentity(dir);
      }
      if (Platform.isMacOS) return await _statDeviceIdentity(dir, macOS: true);
    } on Object {
      // 落到下面的 null：判不出就按可能同盘处理。
    }
    return null;
  });
}

/// 测试用：清掉按目录的缓存。
void debugResetMediaDiskIdentityCache() => _identityByDirectory.clear();

// ---------------------------------------------------------------------------
// POSIX
// ---------------------------------------------------------------------------

Future<int?> _statDevice(String dir, {required bool macOS}) async {
  final ProcessResult r = await Process.run(
    'stat',
    macOS ? <String>['-f', '%d', dir] : <String>['-c', '%d', dir],
  );
  if (r.exitCode != 0) return null;
  return int.tryParse((r.stdout as String).trim());
}

Future<Set<String>?> _statDeviceIdentity(
  String dir, {
  required bool macOS,
}) async {
  final int? dev = await _statDevice(dir, macOS: macOS);
  return dev == null ? null : <String>{'dev:$dev'};
}

Future<Set<String>?> _linuxDiskIdentity(String dir) async {
  final int? dev = await _statDevice(dir, macOS: false);
  if (dev == null) return null;
  // glibc `gnu_dev_major` / `gnu_dev_minor` 的拆法。
  final int major = ((dev >> 8) & 0xfff) | ((dev >> 32) & ~0xfff);
  final int minor = (dev & 0xff) | ((dev >> 12) & ~0xff);
  try {
    final String real = await Directory(
      '/sys/dev/block/$major:$minor',
    ).resolveSymbolicLinks();
    // 分区目录里有 `partition` 文件，父目录名就是整盘（sda1 → sda、nvme0n1p2 → nvme0n1）。
    final String disk = await File(p.join(real, 'partition')).exists()
        ? p.basename(p.dirname(real))
        : p.basename(real);
    if (disk.isNotEmpty) return <String>{'blk:$disk'};
  } on FileSystemException {
    // 无对应块设备（btrfs 子卷 major=0、tmpfs、NFS…）：用设备号。
  }
  return <String>{'dev:$dev'};
}

// ---------------------------------------------------------------------------
// Windows（裸 FFI，同 windows_audio_cd_drive.dart：win32 包在本仓只是传递依赖）
// ---------------------------------------------------------------------------

typedef _PathBufNative = Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _PathBufDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);
typedef _CreateFileWNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CreateFileWDart =
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

const int _maxPath = 1024;
const int _fileShareReadWrite = 0x3;
const int _openExisting = 3;
const int _ioctlVolumeGetVolumeDiskExtents = 0x00560000;
const int _maxExtents = 32;

/// `VOLUME_DISK_EXTENTS`：DWORD 个数 + 对齐到 8 + 每项 `DISK_EXTENT`
/// （DWORD 盘号 + 对齐 + LARGE_INTEGER 起点 + LARGE_INTEGER 长度 = 24 字节）。
const int _extentsHeaderBytes = 8;
const int _extentBytes = 24;

Set<String>? _windowsDiskIdentity(String dir) {
  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
  final _PathBufDart getVolumePathName = kernel32
      .lookupFunction<_PathBufNative, _PathBufDart>('GetVolumePathNameW');
  final _PathBufDart getVolumeName = kernel32
      .lookupFunction<_PathBufNative, _PathBufDart>(
        'GetVolumeNameForVolumeMountPointW',
      );
  final _CreateFileWDart createFile = kernel32
      .lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');
  final _DeviceIoControlDart deviceIoControl = kernel32
      .lookupFunction<_DeviceIoControlNative, _DeviceIoControlDart>(
        'DeviceIoControl',
      );
  final _CloseHandleDart closeHandle = kernel32
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

  return using((Arena arena) {
    final Pointer<Utf16> mount = arena<Uint16>(_maxPath).cast<Utf16>();
    if (getVolumePathName(
          dir.toNativeUtf16(allocator: arena),
          mount,
          _maxPath,
        ) ==
        0) {
      return null;
    }
    final String mountPoint = mount.toDartString();
    // 网络共享（`\\server\share\`）：远端那台机器上是哪块盘无从得知，按共享根算一块。
    if (mountPoint.startsWith(r'\\') && !mountPoint.startsWith(r'\\?\')) {
      return <String>{'share:${mountPoint.toLowerCase()}'};
    }
    final Pointer<Utf16> volume = arena<Uint16>(_maxPath).cast<Utf16>();
    if (getVolumeName(mount, volume, _maxPath) == 0) {
      // subst / 某些虚拟盘没有卷 GUID：只能按挂载点认。
      return <String>{'volume:${mountPoint.toLowerCase()}'};
    }
    // `\\?\Volume{GUID}\` → 打开卷设备要去掉末尾反斜杠；访问权限给 0 即可发
    // FILE_ANY_ACCESS 的 IOCTL，不需要管理员。
    final String volumeName = volume.toDartString();
    final String volumeKey = 'volume:${volumeName.toLowerCase()}';
    final String devicePath = volumeName.endsWith(r'\')
        ? volumeName.substring(0, volumeName.length - 1)
        : volumeName;
    final int handle = createFile(
      devicePath.toNativeUtf16(allocator: arena),
      0,
      _fileShareReadWrite,
      nullptr,
      _openExisting,
      0,
      0,
    );
    if (handle == -1 || handle == 0) return <String>{volumeKey};
    try {
      const int outBytes = _extentsHeaderBytes + _extentBytes * _maxExtents;
      final Pointer<Uint8> out = arena<Uint8>(outBytes);
      final Pointer<Uint32> returned = arena<Uint32>();
      final int ok = deviceIoControl(
        handle,
        _ioctlVolumeGetVolumeDiskExtents,
        nullptr,
        0,
        out.cast<Void>(),
        outBytes,
        returned,
        nullptr,
      );
      if (ok == 0) return <String>{volumeKey};
      final int count = out.cast<Uint32>().value;
      if (count <= 0 || count > _maxExtents) return <String>{volumeKey};
      return <String>{
        for (int i = 0; i < count; i++)
          'disk:${(out + _extentsHeaderBytes + i * _extentBytes).cast<Uint32>().value}',
      };
    } finally {
      closeHandle(handle);
    }
  });
}
