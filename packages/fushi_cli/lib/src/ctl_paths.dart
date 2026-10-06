import 'package:path/path.dart' as p;

/// 显式覆盖控制通道目录的环境变量（app 与 CLI 两侧同认）。
const String kCtlDirEnv = 'FUSHI_CTL_DIR';

/// 发现文件名：app 启动控制通道后写入，CLI 读它找端口与 token。
const String kCtlEndpointFileName = 'endpoint.json';

/// 控制通道状态目录。
///
/// 刻意**不放在 app 的数据根下**：数据根是用户可改的（偏好里的锚点键），CLI 进程
/// 读不到 app 的偏好，就找不到它。这里只依赖每用户固定的系统目录，两侧各自算出
/// 同一个路径：
///
/// 1. `FUSHI_CTL_DIR`（显式覆盖，两侧都认）；
/// 2. [testRoot] 非空时落 `<testRoot>/ctl`——集成测试里的 app 不得改写用户真实
///    app 的发现文件（与 `FUSHI_TEST_ROOT` 隔离 SharedPreferences 同理）；
/// 3. 平台默认：Windows `%LOCALAPPDATA%\Fushi\ctl`、macOS
///    `~/Library/Application Support/Fushi/ctl`、其它
///    `${XDG_STATE_HOME:-~/.local/state}/fushi/ctl`。
///
/// 解析不出（缺 HOME / LOCALAPPDATA）时返回 null，调用方按「通道不可用」处理。
String? resolveCtlStateDir({
  required Map<String, String> environment,
  required String operatingSystem,
  String? testRoot,
}) {
  final String? explicit = _nonEmpty(environment[kCtlDirEnv]);
  if (explicit != null) return explicit;
  final String? root = _nonEmpty(testRoot);
  if (root != null) {
    return (operatingSystem == 'windows' ? p.windows : p.posix).join(
      root,
      'ctl',
    );
  }
  switch (operatingSystem) {
    case 'windows':
      final String? local = _nonEmpty(environment['LOCALAPPDATA']);
      if (local == null) return null;
      return p.windows.join(local, 'Fushi', 'ctl');
    case 'macos':
      final String? home = _nonEmpty(environment['HOME']);
      if (home == null) return null;
      return p.posix.join(
        home,
        'Library',
        'Application Support',
        'Fushi',
        'ctl',
      );
    default:
      final String? state = _nonEmpty(environment['XDG_STATE_HOME']);
      if (state != null) return p.posix.join(state, 'fushi', 'ctl');
      final String? home = _nonEmpty(environment['HOME']);
      if (home == null) return null;
      return p.posix.join(home, '.local', 'state', 'fushi', 'ctl');
  }
}

String? _nonEmpty(String? value) {
  final String? trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
