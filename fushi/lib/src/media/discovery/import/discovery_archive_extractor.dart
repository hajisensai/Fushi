/// 发现页下载物的解压原语。
///
/// 优先用 7-Zip 命令行（zip/7z/rar 全吃、正确处理 cp932 文件名；Windows 随包
/// 分发 `7za.exe`，定位顺序见 [findSevenZip]）；找不到 7-Zip 时 zip 退回
/// `package:archive` 内置解码，7z/rar 无替代 → [DiscoveryImportBlocker.archiveToolMissing]。
///
/// zip 内置解码带 zip-slip 防护：条目路径出现 `..`/绝对路径一律拒绝——下载物
/// 来自外部站点，属不可信输入。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';

import 'package:fushi/src/media/discovery/import/discovery_import_plan.dart';

/// 测试注入口：替换真实子进程执行。
typedef DiscoveryProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class DiscoveryArchiveExtractor {
  DiscoveryArchiveExtractor({
    DiscoveryProcessRunner? runProcess,
    String? sevenZipOverride,
  })  : _runProcess = runProcess ?? Process.run,
        _sevenZipOverride = sevenZipOverride;

  final DiscoveryProcessRunner _runProcess;
  final String? _sevenZipOverride;

  /// 已定位的 7-Zip 可执行路径缓存（空串 = 已找过且没有）。
  String? _sevenZipCache;

  /// 定位 7-Zip 命令行：构造注入 > `FUSHI_7ZA` 环境变量 > 主程序旁
  /// `7za/7za.exe`（构建期随包，仿 voice_hook 落位）> PATH 上的 `7za`/`7z`。
  Future<String?> findSevenZip() async {
    final String? override = _sevenZipOverride;
    if (override != null) return override.isEmpty ? null : override;
    final String? cached = _sevenZipCache;
    if (cached != null) return cached.isEmpty ? null : cached;

    Future<String?> probe() async {
      final String? env = Platform.environment['FUSHI_7ZA'];
      if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
      final String exeDir = File(Platform.resolvedExecutable).parent.path;
      for (final String candidate in <String>[
        '$exeDir${Platform.pathSeparator}7za${Platform.pathSeparator}7za.exe',
        '$exeDir${Platform.pathSeparator}7za.exe',
      ]) {
        if (File(candidate).existsSync()) return candidate;
      }
      for (final String name in <String>['7za', '7z']) {
        try {
          final ProcessResult result = await _runProcess(
            Platform.isWindows ? 'where' : 'which',
            <String>[name],
          );
          if (result.exitCode == 0) {
            final String path =
                (result.stdout as String).trim().split('\n').first.trim();
            if (path.isNotEmpty) return path;
          }
        } catch (_) {
          // where/which 本身不存在：继续下一个候选。
        }
      }
      return null;
    }

    final String? found = await probe();
    _sevenZipCache = found ?? '';
    return found;
  }

  /// 解压 [archivePath] 到 [intoDir]（不存在会创建）。成功返回解出的目录。
  Future<Directory> extract(String archivePath,
      {required String intoDir}) async {
    final Directory target = Directory(intoDir);
    await target.create(recursive: true);

    final String? sevenZip = await findSevenZip();
    if (sevenZip != null) {
      final ProcessResult result = await _runProcess(
        sevenZip,
        // -aoa 覆盖旧文件（重试重解场景）；-p- 空密码占位防交互挂起。
        <String>['x', '-y', '-aoa', '-p-', '-o$intoDir', archivePath],
      );
      if (result.exitCode != 0) {
        throw DiscoveryImportBlockedException(
          DiscoveryImportBlocker.archiveExtractionFailed,
          '7z exit ${result.exitCode}',
        );
      }
      return target;
    }

    final String ext = archivePath.toLowerCase();
    if (!ext.endsWith('.zip')) {
      throw const DiscoveryImportBlockedException(
        DiscoveryImportBlocker.archiveToolMissing,
      );
    }
    await _extractZipBuiltin(archivePath, target);
    return target;
  }

  Future<void> _extractZipBuiltin(String archivePath, Directory target) async {
    final InputFileStream input = InputFileStream(archivePath);
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      for (final ArchiveFile entry in archive) {
        final String? safe = sanitizeArchiveEntryPath(entry.name);
        if (safe == null) {
          throw DiscoveryImportBlockedException(
            DiscoveryImportBlocker.archiveExtractionFailed,
            'unsafe entry path',
          );
        }
        final String outPath = '${target.path}${Platform.pathSeparator}$safe';
        if (entry.isFile) {
          final File outFile = File(outPath);
          await outFile.parent.create(recursive: true);
          final OutputFileStream output = OutputFileStream(outPath);
          try {
            entry.writeContent(output);
          } finally {
            await output.close();
          }
        } else {
          await Directory(outPath).create(recursive: true);
        }
      }
    } on DiscoveryImportBlockedException {
      rethrow;
    } catch (e) {
      throw DiscoveryImportBlockedException(
        DiscoveryImportBlocker.archiveExtractionFailed,
        '$e',
      );
    } finally {
      await input.close();
    }
  }
}

/// zip-slip 防护：归一分隔符、拒绝绝对路径与 `..` 段；空/纯目录名返回原样。
/// 不安全返回 null。
String? sanitizeArchiveEntryPath(String entryName) {
  final String normalized = entryName.replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    return null;
  }
  final List<String> segments = normalized.split('/');
  for (final String segment in segments) {
    if (segment == '..') return null;
  }
  return segments
      .where((String s) => s.isNotEmpty && s != '.')
      .join(Platform.pathSeparator);
}
