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
import 'package:meta/meta.dart' show visibleForTesting;
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
void debugResetMediaDiskIdentityCache() {
  _identityByDirectory.clear();
  _remoteByDirectory.clear();
}

// ---------------------------------------------------------------------------
// 网络卷判定
// ---------------------------------------------------------------------------

/// 按所在目录缓存 [isRemoteMediaVolume] 的结果（同一目录必在同一卷上）。
final Map<String, Future<bool>> _remoteByDirectory = <String, Future<bool>>{};

bool Function(String path)? _remoteOverride;

/// 测试用：让 [isRemoteMediaVolume] 直接按 [predicate] 回答（null = 恢复真实判定）。
@visibleForTesting
void debugOverrideRemoteMediaVolume(bool Function(String path)? predicate) {
  _remoteOverride = predicate;
  _remoteByDirectory.clear();
}

/// [path] 所在的卷是不是**网络卷**：SMB / NFS 共享、WebDAV，或 rclone / sshfs 这类
/// 把云盘挂成本地盘符的 FUSE 挂载。
///
/// 这类卷上每读一个字节都要走网络，带宽往往只比视频码率高一点（云盘还限速、断连）。
/// 播放器自己的顺序读已经吃掉大半，后台再读同一部片（进度条缩略图的随机 seek 取帧、
/// 下一集的整片字幕抽取）就会把正在播的那条流饿到卡缓冲。消费端据此只在本机盘上
/// 做这类「锦上添花」的读盘。
///
/// - Windows：UNC 路径（`\\server\share`）、`GetDriveTypeW == DRIVE_REMOTE`（映射的
///   网络驱动器、rclone `--network-mode`），以及文件系统名为 `FUSE*` / `rclone` 的
///   WinFsp 挂载（rclone 不带 `--network-mode` 时报的是本地盘）。
/// - Linux / Android：`stat -f -c %T` 的文件系统类型属于 [isRemoteLinuxFsType]。
/// - macOS：`mount` 输出里该路径所在挂载点的类型属于 [isRemoteMacMountType]。
/// - 判不出（其它平台 / 任一步失败）按**本机盘**处理：误判成本地只是照旧做后台读，
///   误判成网络盘会让本机用户平白丢掉缩略图。
///
/// 不抛。
Future<bool> isRemoteMediaVolume(String path) {
  final bool Function(String path)? override = _remoteOverride;
  if (override != null) return Future<bool>.value(override(path));
  if (_isUncPath(path)) return Future<bool>.value(true);
  final String dir = p.dirname(p.absolute(path));
  return _remoteByDirectory.putIfAbsent(dir, () async {
    try {
      if (Platform.isWindows) {
        // 断开的网络盘上 FFI 可能阻塞数秒：放后台 isolate。
        return await Isolate.run(() => _windowsIsRemoteVolume(dir));
      }
      if (Platform.isLinux || Platform.isAndroid) {
        final ProcessResult r = await Process.run('stat', <String>[
          '-f',
          '-c',
          '%T',
          dir,
        ]);
        if (r.exitCode != 0) return false;
        return isRemoteLinuxFsType((r.stdout as String).trim());
      }
      if (Platform.isMacOS) {
        final ProcessResult r = await Process.run('/sbin/mount', <String>[]);
        if (r.exitCode != 0) return false;
        final String? type = macMountTypeForPath(
          r.stdout as String,
          await Directory(dir).resolveSymbolicLinks(),
        );
        return type != null && isRemoteMacMountType(type);
      }
    } on Object {
      // 落到下面的 false：判不出按本机盘处理。
    }
    return false;
  });
}

bool _isUncPath(String path) =>
    (path.startsWith(r'\\') || path.startsWith('//')) &&
    !path.startsWith(r'\\?\') &&
    !path.startsWith(r'\\.\');

/// Linux `stat -f -c %T` 报的文件系统类型是不是网络文件系统。
///
/// `fuse` 是非块设备的 FUSE（rclone / sshfs / davfs2 等几乎都是网络盘）；本机 NTFS
/// 分区走的 ntfs-3g 报 `fuseblk`，不算。
bool isRemoteLinuxFsType(String type) {
  const Set<String> remote = <String>{
    'nfs',
    'nfs4',
    'cifs',
    'smb',
    'smb2',
    'smb3',
    'smbfs',
    'fuse',
    '9p',
    'afs',
    'ceph',
    'coda',
    'glusterfs',
    'davfs',
    'ncpfs',
  };
  return remote.contains(type.trim().toLowerCase());
}

/// macOS `mount` 输出（每行 `<设备> on <挂载点> (<类型>, <选项>…)`）里，[dir] 所在
/// 挂载点（最长前缀匹配）的文件系统类型；没有匹配行返回 null。
String? macMountTypeForPath(String mountOutput, String dir) {
  final RegExp line = RegExp(r'^.+? on (.+) \(([^,)]+)');
  String? bestType;
  int bestLength = -1;
  for (final String raw in mountOutput.split('\n')) {
    final RegExpMatch? m = line.firstMatch(raw.trim());
    if (m == null) continue;
    final String mountPoint = m.group(1)!;
    final bool covers =
        mountPoint == '/' ||
        dir == mountPoint ||
        dir.startsWith('$mountPoint/');
    if (covers && mountPoint.length > bestLength) {
      bestLength = mountPoint.length;
      bestType = m.group(2)!.trim();
    }
  }
  return bestType;
}

/// macOS 挂载类型是不是网络文件系统（含 macFUSE：rclone / sshfs 都挂成它）。
bool isRemoteMacMountType(String type) {
  const Set<String> remote = <String>{
    'smbfs',
    'nfs',
    'afpfs',
    'webdav',
    'macfuse',
    'osxfuse',
    'fusefs',
    'ftp',
  };
  return remote.contains(type.trim().toLowerCase());
}

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

const int _driveRemote = 4;

/// Windows 上 [fileSystemName]（`GetVolumeInformationW` 报的名字）是不是 WinFsp 的
/// 用户态网络盘挂载。
bool isRemoteWindowsFileSystemName(String fileSystemName) {
  final String name = fileSystemName.trim().toLowerCase();
  return name.startsWith('fuse') || name == 'rclone';
}

bool _windowsIsRemoteVolume(String dir) {
  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
  final _PathBufDart getVolumePathName = kernel32
      .lookupFunction<_PathBufNative, _PathBufDart>('GetVolumePathNameW');
  final _GetDriveTypeDart getDriveType = kernel32
      .lookupFunction<_GetDriveTypeNative, _GetDriveTypeDart>('GetDriveTypeW');
  final _GetVolumeInformationDart getVolumeInformation = kernel32
      .lookupFunction<_GetVolumeInformationNative, _GetVolumeInformationDart>(
        'GetVolumeInformationW',
      );
  return using((Arena arena) {
    final Pointer<Utf16> mount = arena<Uint16>(_maxPath).cast<Utf16>();
    if (getVolumePathName(
          dir.toNativeUtf16(allocator: arena),
          mount,
          _maxPath,
        ) ==
        0) {
      return false;
    }
    if (_isUncPath(mount.toDartString())) return true;
    if (getDriveType(mount) == _driveRemote) return true;
    final Pointer<Utf16> fsName = arena<Uint16>(_maxPath).cast<Utf16>();
    if (getVolumeInformation(
          mount,
          nullptr,
          0,
          nullptr,
          nullptr,
          nullptr,
          fsName,
          _maxPath,
        ) ==
        0) {
      return false;
    }
    return isRemoteWindowsFileSystemName(fsName.toDartString());
  });
}

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
