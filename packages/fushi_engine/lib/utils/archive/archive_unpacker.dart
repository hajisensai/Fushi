/// 导入链路唯一的归档解包点（发现页下载、漫画包、片源库扫描、控制通道 / 服务端导入共用）。
///
/// - zip / 7z（含 ZipCrypto / WinZip AES / 7z AES-256、加密文件名）：Rust 胖核心
///   `fushi_compute` 的 `ffc_archive_*`，五端都有；探测与解包各放一次后台 isolate。
/// - RAR / CBR：UnRAR 许可不能链进 GPL 本体，交随包（Windows）或 PATH 上的 7-Zip 命令行；
///   找不到 7-Zip → [ArchiveUnpackFailure.toolMissing]。口令在 Windows 上经标准输入喂给 7-Zip
///   的口令提示（不进命令行，别的进程从进程列表看不到）；其它平台见 [ArchiveUnpacker]
///   的 `passwordViaStdin`。
///
/// 加密包：探测出加密就走 [ArchivePasswordProvider]（构造注入，缺省用进程级
/// [ArchivePasswords.provider]）——先试按归档指纹记住的口令，不对就删掉它再问用户；口令错
/// 就带「上次不对」再问，直到解开或用户取消。每次尝试都解进一个新的兄弟暂存目录，成功才
/// 并进 `intoDir`，失败整目录删掉，所以错口令不会在目标目录里留下半截文件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/utils/archive/archive_passwords.dart';

export 'package:fushi_engine/utils/archive/archive_passwords.dart';

/// 测试注入口：替换真实子进程执行。[stdin] 非空时写进子进程标准输入后关掉（7-Zip 口令
/// 走这里，见 [runArchiveProcess]）。
typedef ArchiveProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? stdin,
    });

/// [ArchiveProcessRunner] 的缺省实现：没有 [stdin] 时就是 [Process.run]；有就起进程、把它
/// 写进标准输入再关掉，输出与 [Process.run] 一样按系统编码解码。
Future<ProcessResult> runArchiveProcess(
  String executable,
  List<String> arguments, {
  String? stdin,
}) async {
  if (stdin == null) return Process.run(executable, arguments);
  final Process process = await Process.start(executable, arguments);
  final Future<String> out = process.stdout
      .transform(systemEncoding.decoder)
      .join();
  final Future<String> err = process.stderr
      .transform(systemEncoding.decoder)
      .join();
  try {
    process.stdin.add(utf8.encode(stdin));
    await process.stdin.close();
  } on Object {
    // 包不要口令时 7-Zip 不读标准输入、可能先退出，写端断开无害；结果以退出码与输出为准。
  }
  final int exitCode = await process.exitCode;
  return ProcessResult(process.pid, exitCode, await out, await err);
}

/// 探测（缺省：后台 isolate 里 [ffcArchiveProbeSync]）。
typedef ArchiveProbeFn = Future<FfcArchiveInfo> Function(String archivePath);

/// 原生解包（缺省：后台 isolate 里 [ffcArchiveExtractSync]）。
typedef ArchiveNativeExtractFn =
    Future<FfcArchiveExtractStats> Function(
      String archivePath,
      String destDir, {
      String? password,
      Set<String> includeExtensions,
      int maxTotalBytes,
      int maxEntries,
    });

/// 扩展名认不出格式（魔数不对）时仍按 RAR 交 7-Zip 的扩展名（带点、小写）。
const Set<String> kRarArchiveExtensions = <String>{'.rar', '.cbr'};

/// 7-Zip 命令行定位：构造注入 > `FUSHI_7ZA` 环境变量 > 主程序旁 `7za/7z.exe`（构建期随包）
/// > 旧版随包 `7za.exe` > PATH 上的 `7z` / `7za`。结果按实例缓存。
class SevenZipLocator {
  SevenZipLocator({ArchiveProcessRunner? runProcess, String? sevenZipOverride})
    : _runProcess = runProcess ?? runArchiveProcess,
      _override = sevenZipOverride;

  final ArchiveProcessRunner _runProcess;
  final String? _override;

  /// 已定位的路径缓存（空串 = 已找过且没有）。
  String? _cache;

  Future<String?> find() async {
    final String? override = _override;
    if (override != null) return override.isEmpty ? null : override;
    final String? cached = _cache;
    if (cached != null) return cached.isEmpty ? null : cached;
    final String? found = await _probe();
    _cache = found ?? '';
    return found;
  }

  Future<String?> _probe() async {
    final String? env = Platform.environment['FUSHI_7ZA'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final String candidate in <String>[
      p.join(exeDir, '7za', '7z.exe'),
      p.join(exeDir, '7za', '7za.exe'),
      p.join(exeDir, '7z.exe'),
      p.join(exeDir, '7za.exe'),
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    for (final String name in <String>['7z', '7za']) {
      try {
        final ProcessResult result = await _runProcess(
          Platform.isWindows ? 'where' : 'which',
          <String>[name],
        );
        if (result.exitCode == 0) {
          final String path = (result.stdout as String)
              .trim()
              .split('\n')
              .first
              .trim();
          if (path.isNotEmpty) return path;
        }
      } catch (_) {
        // where / which 本身不存在：继续下一个候选。
      }
    }
    return null;
  }
}

/// [ArchiveUnpacker.extract] 的结果。
final class ArchiveUnpackResult {
  const ArchiveUnpackResult({
    required this.directory,
    required this.files,
    required this.encrypted,
  });

  /// 解出的目录（= 调用方给的 `intoDir`）。
  final Directory directory;

  /// 解出的文件数。
  final int files;

  /// 包是加密的（经口令解开）。
  final bool encrypted;
}

/// 这次尝试的口令不对（或包要口令而这次没给）——口令循环内部信号。
final class _NeedsPassword implements Exception {
  const _NeedsPassword();
}

class ArchiveUnpacker {
  ArchiveUnpacker({
    ArchivePasswordProvider? passwords,
    ArchiveProcessRunner? runProcess,
    String? sevenZipOverride,
    SevenZipLocator? sevenZipLocator,
    ArchiveProbeFn? probe,
    ArchiveNativeExtractFn? nativeExtract,
    bool? passwordViaStdin,
  }) : _passwords = passwords,
       _runProcess = runProcess ?? runArchiveProcess,
       _passwordViaStdin = passwordViaStdin ?? Platform.isWindows,
       _locator =
           sevenZipLocator ??
           SevenZipLocator(
             runProcess: runProcess,
             sevenZipOverride: sevenZipOverride,
           ),
       _probe = probe ?? _probeInBackground,
       _nativeExtract = nativeExtract ?? _extractInBackground;

  final ArchivePasswordProvider? _passwords;
  final ArchiveProcessRunner _runProcess;
  final SevenZipLocator _locator;
  final ArchiveProbeFn _probe;
  final ArchiveNativeExtractFn _nativeExtract;

  /// 7-Zip 的口令经标准输入给（缺省只在 Windows）。7-Zip 不给 `-p` 时会提示输入口令：
  /// Windows 版标准输入不是控制台就从管道读一行（随包 7-Zip 25 实测）；类 Unix 的
  /// p7zip / 7zz 编进 `getpass` 时直接读 `/dev/tty`，从终端启动的 app 会卡在终端上等输入，
  /// 所以那边仍经 `-p` 传（命令行参数对同机其它进程可见，是这条外部工具限制的代价）。
  final bool _passwordViaStdin;

  /// 这次 7-Zip 调用的口令开关（经标准输入时不带开关）。
  List<String> _passwordArgs(String? password) => _passwordViaStdin
      ? const <String>[]
      : <String>[password == null ? '-p-' : '-p$password'];

  /// 这次 7-Zip 调用的标准输入：一行口令（没有口令就给空行，加密包按「口令不对」失败，
  /// 与 `-p-` 一样不会挂起等输入）。
  String? _passwordStdin(String? password) =>
      _passwordViaStdin ? '${password ?? ''}\n' : null;

  SevenZipLocator get sevenZipLocator => _locator;

  /// 只探测（格式 / 是否加密 / 指纹），后台 isolate。条目表坏抛 [ArchiveUnpackException]。
  Future<FfcArchiveInfo> probe(String archivePath) async {
    try {
      return await _probe(archivePath);
    } on FfcArchiveException catch (e) {
      throw ArchiveUnpackException(
        ArchiveUnpackFailure.corrupt,
        archivePath,
        e.failure.name,
      );
    }
  }

  /// 把 [archivePath] 解进 [intoDir]（不存在会建；已存在则并入、同名覆盖）。
  ///
  /// [includeExtensions]（小写带点）非空时只解这些扩展名；[maxTotalBytes] / [maxEntries]
  /// 是解出总量的上限（0 = 不限）。失败抛 [ArchiveUnpackException]。
  Future<ArchiveUnpackResult> extract(
    String archivePath, {
    required String intoDir,
    Set<String> includeExtensions = const <String>{},
    int maxTotalBytes = 0,
    int maxEntries = 0,
  }) async {
    final FfcArchiveInfo info = await probe(archivePath);
    final String ext = p.extension(archivePath).toLowerCase();
    final bool viaCli =
        info.format == FfcArchiveFormat.rar ||
        (info.format == FfcArchiveFormat.unknown &&
            kRarArchiveExtensions.contains(ext));
    if (viaCli) {
      return _extractWithCli(
        archivePath,
        info.fingerprint,
        intoDir: intoDir,
        includeExtensions: includeExtensions,
        maxTotalBytes: maxTotalBytes,
        maxEntries: maxEntries,
      );
    }
    if (info.format == FfcArchiveFormat.unknown) {
      throw ArchiveUnpackException(
        ArchiveUnpackFailure.unsupported,
        archivePath,
        'unknown archive format',
      );
    }
    return _withPassword(
      archivePath: archivePath,
      fingerprint: info.fingerprint,
      encrypted: info.encryption.isEncrypted,
      intoDir: intoDir,
      attempt: (String? password, Directory staging) async {
        try {
          final FfcArchiveExtractStats stats = await _nativeExtract(
            archivePath,
            staging.path,
            password: password,
            includeExtensions: includeExtensions,
            maxTotalBytes: maxTotalBytes,
            maxEntries: maxEntries,
          );
          return stats.files;
        } on FfcArchiveException catch (e) {
          throw switch (e.failure) {
            FfcArchiveFailure.passwordRequired ||
            FfcArchiveFailure.wrongPassword => const _NeedsPassword(),
            FfcArchiveFailure.unsafeEntry => ArchiveUnpackException(
              ArchiveUnpackFailure.unsafeEntry,
              archivePath,
            ),
            FfcArchiveFailure.tooLarge => ArchiveUnpackException(
              ArchiveUnpackFailure.tooLarge,
              archivePath,
            ),
            FfcArchiveFailure.unsupported => ArchiveUnpackException(
              ArchiveUnpackFailure.unsupported,
              archivePath,
            ),
            FfcArchiveFailure.corrupt ||
            FfcArchiveFailure.io ||
            FfcArchiveFailure.cancelled => ArchiveUnpackException(
              ArchiveUnpackFailure.corrupt,
              archivePath,
              e.failure.name,
            ),
          };
        }
      },
    );
  }

  // ── 口令循环 ──────────────────────────────────────────────────────────────────────

  Future<ArchiveUnpackResult> _withPassword({
    required String archivePath,
    required String fingerprint,
    required bool encrypted,
    required String intoDir,
    required Future<int> Function(String? password, Directory staging) attempt,
  }) async {
    final Directory target = Directory(intoDir);
    Future<ArchiveUnpackResult> run(String? password) async {
      final Directory staging = await _freshStaging(target);
      try {
        final int files = await attempt(password, staging);
        await _commit(staging, target);
        return ArchiveUnpackResult(
          directory: target,
          files: files,
          encrypted: password != null,
        );
      } catch (_) {
        await _deleteQuietly(staging);
        rethrow;
      }
    }

    if (!encrypted) {
      try {
        return await run(null);
      } on _NeedsPassword {
        // 探测没看出加密、解的时候才要口令（个别条目加密的怪包）：转口令流程。
      }
    }

    final ArchivePasswordProvider? provider =
        _passwords ?? ArchivePasswords.provider;
    bool rememberedRejected = false;
    final String? saved = await provider?.remembered(fingerprint);
    if (saved != null) {
      try {
        return await run(saved);
      } on _NeedsPassword {
        rememberedRejected = true;
        await provider!.forget(fingerprint);
      }
    }
    // 不能交互（无头服务端没装来源 / 后台扫描只用记住的口令）：按「要口令」失败，
    // 不算用户取消。
    if (provider == null || provider is StoredOnlyArchivePasswords) {
      throw ArchiveUnpackException(
        ArchiveUnpackFailure.passwordRequired,
        archivePath,
      );
    }
    for (int n = 0; ; n++) {
      final ArchivePasswordAnswer? answer = await provider.ask(
        ArchivePasswordRequest(
          archivePath: archivePath,
          fingerprint: fingerprint,
          attempt: n,
          previousWrong: n > 0,
          rememberedRejected: rememberedRejected && n == 0,
        ),
      );
      if (answer == null) {
        throw ArchiveUnpackException(
          ArchiveUnpackFailure.passwordCancelled,
          archivePath,
        );
      }
      try {
        final ArchiveUnpackResult result = await run(answer.password);
        if (answer.remember) {
          await provider.remember(fingerprint, answer.password);
        }
        return result;
      } on _NeedsPassword {
        continue;
      }
    }
  }

  /// 与 [target] 同级的新暂存目录（同卷，成功后 rename 进去）。
  static Future<Directory> _freshStaging(Directory target) async {
    final Directory parent = target.absolute.parent;
    await parent.create(recursive: true);
    return parent.createTemp('${p.basename(target.path)}.unpacking-');
  }

  /// 把 [staging] 的内容并进 [target]：目标不存在或为空就整目录 rename，否则逐项并入
  /// （同名文件覆盖，与 7-Zip `-aoa` 一致）。
  static Future<void> _commit(Directory staging, Directory target) async {
    if (await target.exists() && await target.list().isEmpty) {
      await target.delete();
    }
    if (!await target.exists()) {
      await staging.rename(target.path);
      return;
    }
    await _merge(staging, target);
    await _deleteQuietly(staging);
  }

  static Future<void> _merge(Directory from, Directory into) async {
    await for (final FileSystemEntity entity in from.list(followLinks: false)) {
      final String dest = p.join(into.path, p.basename(entity.path));
      if (entity is Directory) {
        if (await Directory(dest).exists()) {
          await _merge(entity, Directory(dest));
          continue;
        }
        if (await File(dest).exists()) await File(dest).delete();
        await entity.rename(dest);
      } else if (entity is File) {
        if (await Directory(dest).exists()) {
          await Directory(dest).delete(recursive: true);
        } else if (await File(dest).exists()) {
          await File(dest).delete();
        }
        await entity.rename(dest);
      }
    }
  }

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不掩盖原错误。暂存目录与目标同级（`<目标名>.unpacking-*`），调用方的
      // 目标都在各自的临时 / 工作目录里，残留随那一层清理一起走。
    }
  }

  // ── RAR：7-Zip 命令行 ────────────────────────────────────────────────────────────

  static final RegExp _wrongPassword = RegExp(
    r'wrong password|can ?not open encrypted archive',
    caseSensitive: false,
  );

  Future<ArchiveUnpackResult> _extractWithCli(
    String archivePath,
    String fingerprint, {
    required String intoDir,
    required Set<String> includeExtensions,
    required int maxTotalBytes,
    required int maxEntries,
  }) async {
    final String? sevenZip = await _locator.find();
    if (sevenZip == null) {
      throw ArchiveUnpackException(
        ArchiveUnpackFailure.toolMissing,
        archivePath,
      );
    }
    // 第一遍不带口令列目录：条目内容加密的包照样列得出（`Encrypted = +`），这份清单直接用来
    // 校验；条目表加密的包列不出，带口令后再列。
    _CliListing? listing = await _cliList(sevenZip, archivePath, null);
    final bool encrypted = listing == null || listing.encrypted;
    return _withPassword(
      archivePath: archivePath,
      fingerprint: fingerprint,
      encrypted: encrypted,
      intoDir: intoDir,
      attempt: (String? password, Directory staging) async {
        final _CliListing checked =
            listing ??
            await _cliList(sevenZip, archivePath, password) ??
            (throw const _NeedsPassword());
        listing = checked;
        checked.validate(
          archivePath,
          includeExtensions: includeExtensions,
          maxTotalBytes: maxTotalBytes,
          maxEntries: maxEntries,
        );
        final ProcessResult result = await _runProcess(sevenZip, <String>[
          'x',
          '-y',
          '-aoa',
          ..._passwordArgs(password),
          '-sccUTF-8',
          '-ssc-',
          '-smemx2g',
          '-o${staging.path}',
          for (final String e in includeExtensions) '-ir!*$e',
          // 之后一律按文件名解析：`-` 开头的包名不会被当成开关。
          '--',
          archivePath,
        ], stdin: _passwordStdin(password));
        if (result.exitCode != 0) {
          if (_wrongPassword.hasMatch('${result.stdout}\n${result.stderr}')) {
            throw const _NeedsPassword();
          }
          throw ArchiveUnpackException(
            ArchiveUnpackFailure.corrupt,
            archivePath,
            '7z exit ${result.exitCode}',
          );
        }
        return _countAndRejectLinks(archivePath, staging);
      },
    );
  }

  /// 列目录；条目表加密（要口令 / 口令不对）返回 null，其它失败抛。
  Future<_CliListing?> _cliList(
    String sevenZip,
    String archivePath,
    String? password,
  ) async {
    final ProcessResult result = await _runProcess(sevenZip, <String>[
      'l',
      '-slt',
      '-sccUTF-8',
      ..._passwordArgs(password),
      '--',
      archivePath,
    ], stdin: _passwordStdin(password));
    if (result.exitCode != 0) {
      if (_wrongPassword.hasMatch('${result.stdout}\n${result.stderr}')) {
        return null;
      }
      throw ArchiveUnpackException(
        ArchiveUnpackFailure.corrupt,
        archivePath,
        '7z list exit ${result.exitCode}',
      );
    }
    return _CliListing.parse(archivePath, result.stdout.toString());
  }

  static Future<int> _countAndRejectLinks(
    String archivePath,
    Directory staging,
  ) async {
    int files = 0;
    await for (final FileSystemEntity entity in staging.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) {
        throw ArchiveUnpackException(
          ArchiveUnpackFailure.unsafeEntry,
          archivePath,
          'link ${entity.path}',
        );
      }
      if (entity is File) files++;
    }
    return files;
  }
}

/// `7z l -slt` 的解析结果。
final class _CliListing {
  const _CliListing(this.entries, {required this.encrypted});

  final List<Map<String, String>> entries;
  final bool encrypted;

  static _CliListing parse(String archivePath, String output) {
    final String normalized = output.replaceAll('\r\n', '\n');
    final int marker = normalized.indexOf('\n----------\n');
    if (marker < 0) {
      throw ArchiveUnpackException(
        ArchiveUnpackFailure.corrupt,
        archivePath,
        'unparseable 7-Zip listing',
      );
    }
    final List<Map<String, String>> entries = <Map<String, String>>[];
    bool encrypted = false;
    for (final String block
        in normalized.substring(marker + 12).split(RegExp(r'\n\s*\n'))) {
      final Map<String, String> fields = <String, String>{};
      for (final String line in block.split('\n')) {
        final int separator = line.indexOf(' = ');
        if (separator <= 0) continue;
        fields[line.substring(0, separator)] = line.substring(separator + 3);
      }
      final String? path = fields['Path'];
      if (path == null || path.isEmpty) continue;
      if (fields['Encrypted'] == '+') encrypted = true;
      entries.add(fields);
    }
    return _CliListing(entries, encrypted: encrypted);
  }

  /// 解压前校验：路径安全、无符号链接、（过滤后的）声明总量不超上限。
  void validate(
    String archivePath, {
    required Set<String> includeExtensions,
    required int maxTotalBytes,
    required int maxEntries,
  }) {
    int total = 0;
    int count = 0;
    for (final Map<String, String> fields in entries) {
      final String path = fields['Path']!;
      if (sanitizeArchiveEntryPath(path) == null ||
          fields.containsKey('Symbolic Link')) {
        throw ArchiveUnpackException(
          ArchiveUnpackFailure.unsafeEntry,
          archivePath,
          path,
        );
      }
      if ((fields['Attributes'] ?? '').toUpperCase().contains('D') ||
          fields['Folder'] == '+') {
        continue;
      }
      if (includeExtensions.isNotEmpty &&
          !includeExtensions.contains(
            p.posix.extension(path.replaceAll('\\', '/')).toLowerCase(),
          )) {
        continue;
      }
      final int? size = int.tryParse(fields['Size'] ?? '');
      if (size == null || size < 0) {
        throw ArchiveUnpackException(
          ArchiveUnpackFailure.corrupt,
          archivePath,
          'invalid entry size: $path',
        );
      }
      total += size;
      count++;
      if ((maxTotalBytes > 0 && total > maxTotalBytes) ||
          (maxEntries > 0 && count > maxEntries)) {
        throw ArchiveUnpackException(
          ArchiveUnpackFailure.tooLarge,
          archivePath,
        );
      }
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

Future<FfcArchiveInfo> _probeInBackground(String archivePath) =>
    Isolate.run(() => ffcArchiveProbeSync(archivePath));

Future<FfcArchiveExtractStats> _extractInBackground(
  String archivePath,
  String destDir, {
  String? password,
  Set<String> includeExtensions = const <String>{},
  int maxTotalBytes = 0,
  int maxEntries = 0,
}) => Isolate.run(
  () => ffcArchiveExtractSync(
    archivePath,
    destDir,
    password: password,
    includeExtensions: includeExtensions,
    maxTotalBytes: maxTotalBytes,
    maxEntries: maxEntries,
  ),
);
