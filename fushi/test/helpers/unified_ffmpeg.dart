// 测试用「真 ffmpeg」解析：统一 FFmpeg（tool/ffmpeg-unified）随播放器运行时入库，
// 不再有单独的 ffmpeg-min 可执行文件可直接指向。
//
// 解析顺序：
//   1. FUSHI_FFMPEG / FUSHI_FFPROBE（显式覆盖，CI 或本机自带 ffmpeg 时用）；
//   2. Windows：vendored libmpv 7z（third_party/media_kit_libs_windows_video/vendored，
//      CMakeLists 的 LIBMPV / LIBMPV_MD5 钉住的那一份）里的 ffmpeg.exe / ffprobe.exe
//      与它们共用的 fbd*.dll——这正是随包发给用户的二进制；
//      macOS：vendored 的 ffmpeg-unified-macos.tar.gz（Frameworks + MacOS 布局，
//      third_party/media_kit_libs_macos_video/native）；
//      两者都用系统 tar（libarchive，Windows 10+ 自带，能读 7z）解到
//      .dart_tool/unified-ffmpeg/<hash>/，按哈希缓存，只解一次；
//   3. PATH 上的 ffmpeg。
//   都没有 → null，调用方 skip。
import 'dart:io';

import 'package:crypto/crypto.dart' show md5;
import 'package:path/path.dart' as p;

/// 统一 FFmpeg 的 ffmpeg / ffprobe 路径（同一份构建）。
class UnifiedFfmpegForTests {
  const UnifiedFfmpegForTests(this.ffmpeg, this.ffprobe, {required this.bundled});

  final String ffmpeg;
  final String ffprobe;

  /// true = 随包二进制（vendored 统一 FFmpeg）；false = 环境覆盖或 PATH。
  final bool bundled;
}

UnifiedFfmpegForTests? _cached;
bool _resolved = false;

/// 解析测试用 ffmpeg / ffprobe；找不到返回 null。
UnifiedFfmpegForTests? resolveUnifiedFfmpegForTests() {
  if (_resolved) return _cached;
  _resolved = true;
  return _cached = _resolve();
}

/// 只要随包二进制（不接受 PATH / 覆盖）：验证「发给用户的那份」时用。
UnifiedFfmpegForTests? resolveBundledUnifiedFfmpegForTests() {
  final UnifiedFfmpegForTests? any = resolveUnifiedFfmpegForTests();
  if (any != null && any.bundled) return any;
  return _extractBundled();
}

UnifiedFfmpegForTests? _resolve() {
  final String? override = Platform.environment['FUSHI_FFMPEG'];
  if (override != null && override.isNotEmpty) {
    final String probe = Platform.environment['FUSHI_FFPROBE'] ??
        p.join(p.dirname(override),
            p.basename(override).replaceFirst('ffmpeg', 'ffprobe'));
    return UnifiedFfmpegForTests(override, probe, bundled: false);
  }
  final UnifiedFfmpegForTests? bundled = _extractBundled();
  if (bundled != null) return bundled;
  try {
    final ProcessResult r = Process.runSync('ffmpeg', <String>['-version']);
    if (r.exitCode == 0) {
      return const UnifiedFfmpegForTests('ffmpeg', 'ffprobe', bundled: false);
    }
  } on ProcessException {
    // PATH 上没有 ffmpeg。
  }
  return null;
}

/// 仓库根（fushi/ 是测试 CWD）。
String _repoRoot() => p.normalize(p.absolute('..'));

UnifiedFfmpegForTests? _extractBundled() {
  final String root = _repoRoot();
  final String archive;
  final String hash;
  if (Platform.isWindows) {
    final File cmake = File(p.join(root, 'third_party',
        'media_kit_libs_windows_video', 'windows', 'CMakeLists.txt'));
    if (!cmake.existsSync()) return null;
    final String src = cmake.readAsStringSync();
    final RegExpMatch? name = RegExp(r'set\(LIBMPV "([^"]+)"\)').firstMatch(src);
    final RegExpMatch? pinned =
        RegExp(r'set\(LIBMPV_MD5 "([0-9a-f]+)"\)').firstMatch(src);
    if (name == null || pinned == null) return null;
    archive = p.join(root, 'third_party', 'media_kit_libs_windows_video',
        'vendored', name.group(1)!);
    hash = pinned.group(1)!;
  } else if (Platform.isMacOS) {
    archive = p.join(root, 'third_party', 'media_kit_libs_macos_video',
        'native', 'ffmpeg-unified-macos.tar.gz');
    if (!File(archive).existsSync()) return null;
    hash = md5.convert(File(archive).readAsBytesSync()).toString();
  } else {
    return null;
  }
  if (!File(archive).existsSync()) return null;

  final Directory dir = Directory(
      p.join(root, 'fushi', '.dart_tool', 'unified-ffmpeg', hash));
  final String exe = Platform.isWindows ? '.exe' : '';
  final String sub = Platform.isWindows ? '' : 'MacOS';
  final File ffmpeg = File(p.join(dir.path, sub, 'ffmpeg$exe'));
  final File ffprobe = File(p.join(dir.path, sub, 'ffprobe$exe'));
  if (!ffmpeg.existsSync() || !ffprobe.existsSync()) {
    // 先解到临时目录再改名：并发测试进程不会看到半解压的目录。
    final Directory staging = Directory('${dir.path}.tmp$pid');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    final ProcessResult r = Process.runSync(
        'tar', <String>['-xf', archive, '-C', staging.path]);
    if (r.exitCode != 0) {
      staging.deleteSync(recursive: true);
      return null;
    }
    try {
      staging.renameSync(dir.path);
    } on FileSystemException {
      // 另一个进程已经解好。
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }
  }
  if (!ffmpeg.existsSync() || !ffprobe.existsSync()) return null;
  return UnifiedFfmpegForTests(ffmpeg.path, ffprobe.path, bundled: true);
}
