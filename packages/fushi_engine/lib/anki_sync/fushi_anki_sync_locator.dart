import 'dart:io';

/// 覆盖 helper 路径的环境变量（开发 / 测试用；随包版本放在可执行文件旁边）。
const String kFushiAnkiSyncBinEnv = 'FUSHI_ANKI_SYNC_BIN';

/// `fushi-anki-sync` 在本平台上的文件名。
String fushiAnkiSyncFileName({bool? isWindows}) =>
    (isWindows ?? Platform.isWindows)
    ? 'fushi-anki-sync.exe'
    : 'fushi-anki-sync';

/// 找 `fushi-anki-sync`：先认 [kFushiAnkiSyncBinEnv]，再认与宿主可执行文件同目录的
/// 随包副本（app：`fushi.exe` 旁 / macOS `Contents/MacOS/`；服务端：`bundle/bin/`）。
/// 找不到返回 null——调用方据此不提供「同步客户端」这个后端。
String? resolveFushiAnkiSyncExecutable({
  Map<String, String>? environment,
  String? resolvedExecutable,
  bool? isWindows,
}) {
  final String? fromEnv =
      (environment ?? Platform.environment)[kFushiAnkiSyncBinEnv];
  if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
    return fromEnv;
  }
  try {
    final String dir = File(
      resolvedExecutable ?? Platform.resolvedExecutable,
    ).parent.path;
    final File bundled = File(
      '$dir${Platform.pathSeparator}${fushiAnkiSyncFileName(isWindows: isWindows)}',
    );
    if (bundled.existsSync()) return bundled.path;
  } catch (_) {}
  return null;
}
