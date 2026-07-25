import 'dart:io';

/// 监听某端口的进程信息（用于「端口被占用 → 一键结束占用进程」）。
class PortListenerInfo {
  const PortListenerInfo({required this.pid, required this.processName});

  final int pid;
  final String processName;
}

/// 桌面端「查找并结束占用端口的进程」工具。典型场景：Yomitan API 默认端口 19633
/// 被浏览器经 native messaging 拉起的 yomitan-api 组件（Python 进程）占着，Hibiki
/// 起 server 失败；SnackBar 上的「结束进程并重试」按钮走这里直接结束占用者。
///
/// 平台命令：Windows 用 `netstat -ano` + `tasklist` + `taskkill`；macOS/Linux 用
/// `lsof` + `ps` + 信号（SIGTERM → 短暂等待 → SIGKILL 兜底）。解析逻辑抽成顶层
/// 纯函数，便于单元测试覆盖各平台输出格式。
class PortProcessTerminator {
  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 找出正在 LISTEN [port] 的进程；找不到（或就是本进程自己）返回 null。
  static Future<PortListenerInfo?> findListener(int port) async {
    if (!isSupported) return null;
    try {
      final int? listenerPid = Platform.isWindows
          ? await _findListenerPidWindows(port)
          : await _findListenerPidPosix(port);
      // pid 等于自身说明端口已是本进程持有（并发下 server 已起来），不能杀自己。
      if (listenerPid == null || listenerPid == pid) return null;
      final String name = await _processName(listenerPid);
      return PortListenerInfo(pid: listenerPid, processName: name);
    } on ProcessException {
      return null;
    }
  }

  /// 结束 [listener] 对应进程。返回是否成功发出并确认结束。
  static Future<bool> terminate(PortListenerInfo listener) async {
    if (!isSupported || listener.pid == pid) return false;
    try {
      if (Platform.isWindows) {
        final ProcessResult result = await Process.run(
          'taskkill',
          <String>['/PID', '${listener.pid}', '/T', '/F'],
        );
        return result.exitCode == 0;
      }
      // POSIX：先 SIGTERM（yomitan-api 注册了 SIGTERM 清理句柄），给它一点退出
      // 时间；仍未退出再 SIGKILL 兜底。
      final bool delivered =
          Process.killPid(listener.pid, ProcessSignal.sigterm);
      if (!delivered) return false;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      Process.killPid(listener.pid, ProcessSignal.sigkill);
      return true;
    } on ProcessException {
      return false;
    }
  }

  static Future<int?> _findListenerPidWindows(int port) async {
    final ProcessResult result =
        await Process.run('netstat', <String>['-ano', '-p', 'tcp']);
    if (result.exitCode != 0) return null;
    return parseNetstatListenerPid('${result.stdout}', port);
  }

  static Future<int?> _findListenerPidPosix(int port) async {
    final ProcessResult result = await Process.run(
      'lsof',
      <String>['-nP', '-iTCP:$port', '-sTCP:LISTEN', '-t'],
    );
    if (result.exitCode != 0) return null;
    final String out = '${result.stdout}'.trim();
    if (out.isEmpty) return null;
    return int.tryParse(out.split('\n').first.trim());
  }

  static Future<String> _processName(int targetPid) async {
    final String fallback = 'PID $targetPid';
    try {
      if (Platform.isWindows) {
        final ProcessResult result = await Process.run(
          'tasklist',
          <String>['/FI', 'PID eq $targetPid', '/FO', 'CSV', '/NH'],
        );
        if (result.exitCode != 0) return fallback;
        return parseTasklistProcessName('${result.stdout}') ?? fallback;
      }
      final ProcessResult result =
          await Process.run('ps', <String>['-p', '$targetPid', '-o', 'comm=']);
      if (result.exitCode != 0) return fallback;
      final String name = '${result.stdout}'.trim();
      return name.isEmpty ? fallback : name;
    } on ProcessException {
      return fallback;
    }
  }
}

/// 从 `netstat -ano -p tcp` 输出解析 LISTEN [port] 的 PID；无匹配返回 null。
/// 行格式：`TCP    0.0.0.0:19633    0.0.0.0:0    LISTENING    188544`
/// （netstat 的 TCP 状态名不随系统语言本地化）。
int? parseNetstatListenerPid(String output, int port) {
  for (final String line in output.split('\n')) {
    final List<String> columns = line.trim().split(RegExp(r'\s+'));
    if (columns.length < 5) continue;
    if (!columns[1].endsWith(':$port')) continue;
    if (!columns[3].toUpperCase().contains('LISTEN')) continue;
    final int? listenerPid = int.tryParse(columns.last);
    if (listenerPid != null && listenerPid > 0) return listenerPid;
  }
  return null;
}

/// 从 `tasklist /FO CSV /NH` 输出解析进程映像名（首列，去引号）；解析不出返回 null。
/// 行格式：`"python.exe","188544","Console","1","25,932 K"`
String? parseTasklistProcessName(String output) {
  final String line = output.trim().split('\n').first.trim();
  if (!line.startsWith('"')) return null;
  final int end = line.indexOf('"', 1);
  if (end <= 1) return null;
  return line.substring(1, end);
}
