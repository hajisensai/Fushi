import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../anki_models.dart';
import 'anki_desktop_foreground.dart';
import 'ankiconnect_service.dart';

/// 一次「拉起 Anki 桌面版」的结论。
enum AnkiDesktopLaunchStatus {
  /// 已经交给系统启动（不等 AnkiConnect 就绪）。
  launched,

  /// AnkiConnect 端口已有人监听，不重复启动。
  alreadyRunning,

  /// 本平台需要 Anki 程序路径而用户没配（Windows 没有可靠的默认入口）。
  notConfigured,

  /// 条件不满足、按设计不动作：自动启动开关关着 / 走同步客户端后端 /
  /// AnkiConnect 指向别的机器 / 移动端。
  skipped,

  /// 启动进程失败（路径不存在、不可执行、Linux 上 `anki` 不在 PATH 等）。
  failed,
}

class AnkiDesktopLaunchResult {
  const AnkiDesktopLaunchResult(
    this.status, {
    this.detail,
    this.learnedExecutable,
  });

  final AnkiDesktopLaunchStatus status;

  /// [AnkiDesktopLaunchStatus.failed] 时的底层错误文本。
  final String? detail;

  /// 用户没配路径、而这次正好认出了正在运行的 Anki 入口 exe 时给出它，
  /// 调用方据此写回设置，下次 Anki 没开时就能直接拉起。
  final String? learnedExecutable;
}

/// 解析出来的一条启动命令。
@immutable
class AnkiDesktopLaunchCommand {
  const AnkiDesktopLaunchCommand(
    this.executable,
    this.arguments, {
    this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  @override
  bool operator ==(Object other) =>
      other is AnkiDesktopLaunchCommand &&
      other.executable == executable &&
      listEquals(other.arguments, arguments) &&
      other.workingDirectory == workingDirectory;

  @override
  int get hashCode =>
      Object.hash(executable, Object.hashAll(arguments), workingDirectory);

  @override
  String toString() =>
      'AnkiDesktopLaunchCommand($executable, $arguments, $workingDirectory)';
}

/// 启动 Fushi 时 / 用户点按钮时把 Anki 桌面版拉起来（issue #1949）。
///
/// ## 路径从哪来
///
/// Anki 没在运行时，「`anki.exe` 装在哪」只能猜（注册表、默认目录、绿色版、多版本
/// 共存都可能），这正是 [AnkiConnectInstaller] 刻意回避的问题。这里不猜：
///
/// - 用户在设置里配的路径优先；
/// - 没配时，**Anki 正在运行**的那一刻用 [AnkiDesktopForeground.findRunningAnkiExecutable]
///   认出入口 exe 并回填（[AnkiDesktopLaunchResult.learnedExecutable]）。它只认「有窗口
///   且 exe 叫 anki.exe」的进程：新 launcher 架构下真正监听 8765 的是 venv 里的
///   `pythonw.exe`，拿它去启动会少掉 `-c "import aqt; aqt.run()"` 而起不来；那种
///   环境下它返回 null，宁可不学也不学错，用户手动选一次即可；
/// - macOS / Linux 有不依赖路径的标准入口（`open -a Anki` / PATH 上的 `anki`）。
///
/// ## 不等就绪
///
/// 启动后不轮询 AnkiConnect：制卡时它自然连上，阻塞 Fushi 启动等一个可能开不起来的
/// 程序只会让两边都慢。
abstract final class AnkiDesktopLauncher {
  /// 测试注入点；null = 真实平台实现。
  @visibleForTesting
  static AnkiDesktopLauncherHost? debugHost;

  static AnkiDesktopLauncherHost get _host =>
      debugHost ?? const _RealAnkiDesktopLauncherHost();

  /// 本平台是否有「拉起 Anki 桌面版」这回事。
  static bool get isSupported => _host.isDesktop;

  /// 由用户配置的路径解析启动命令；本平台必须有路径而没配时返回 null。
  ///
  /// [operatingSystem] 取 `Platform.operatingSystem` 的值域，抽成参数是为了让
  /// 三个平台的分支都能在任意一台机器上单测。
  static AnkiDesktopLaunchCommand? resolveCommand(
    String configuredExecutable, {
    required String operatingSystem,
  }) {
    final String path = configuredExecutable.trim();
    final bool isMac = operatingSystem == 'macos';
    if (path.isEmpty) {
      if (isMac) {
        return const AnkiDesktopLaunchCommand('open', <String>['-a', 'Anki']);
      }
      if (operatingSystem == 'linux') {
        return const AnkiDesktopLaunchCommand('anki', <String>[]);
      }
      return null;
    }
    // .app 是目录，Process.start 跑不了它，交给 LaunchServices。
    if (isMac && path.toLowerCase().endsWith('.app')) {
      return AnkiDesktopLaunchCommand('open', <String>['-a', path]);
    }
    return AnkiDesktopLaunchCommand(
      path,
      const <String>[],
      workingDirectory: File(path).parent.path,
    );
  }

  /// 正在运行的 Anki 的入口 exe（只在旧单进程架构下认得出，见类注释）。
  static String? detectRunningExecutable() => _host.findRunningAnkiExecutable();

  /// 用户显式要求启动（设置页按钮）。AnkiConnect 指向本机且已在监听时不重复启动。
  static Future<AnkiDesktopLaunchResult> launch(AnkiSettings settings) async {
    final AnkiDesktopLauncherHost host = _host;
    if (!host.isDesktop) {
      return const AnkiDesktopLaunchResult(AnkiDesktopLaunchStatus.skipped);
    }
    if (ankiConnectHostIsLoopback(settings.ankiConnectHost) &&
        await host.isPortListening(
          settings.ankiConnectHost,
          settings.ankiConnectPort,
        )) {
      return AnkiDesktopLaunchResult(
        AnkiDesktopLaunchStatus.alreadyRunning,
        learnedExecutable: _learnExecutable(host, settings),
      );
    }
    final AnkiDesktopLaunchCommand? command = resolveCommand(
      settings.ankiDesktopExecutable,
      operatingSystem: host.operatingSystem,
    );
    if (command == null) {
      return const AnkiDesktopLaunchResult(
        AnkiDesktopLaunchStatus.notConfigured,
      );
    }
    try {
      await host.start(command);
    } on Object catch (e) {
      return AnkiDesktopLaunchResult(
        AnkiDesktopLaunchStatus.failed,
        detail: '$e',
      );
    }
    return const AnkiDesktopLaunchResult(AnkiDesktopLaunchStatus.launched);
  }

  /// 启动 Fushi 时调用一次：只有用户打开了开关、走的是 AnkiConnect、且它指向本机
  /// 时才动作；其余一律 [AnkiDesktopLaunchStatus.skipped]。
  static Future<AnkiDesktopLaunchResult> autoLaunchOnStartup(
    AnkiSettings settings,
  ) async {
    if (!settings.autoLaunchAnkiDesktop ||
        settings.useAnkiSyncClient ||
        !ankiConnectHostIsLoopback(settings.ankiConnectHost)) {
      return const AnkiDesktopLaunchResult(AnkiDesktopLaunchStatus.skipped);
    }
    return launch(settings);
  }

  static String? _learnExecutable(
    AnkiDesktopLauncherHost host,
    AnkiSettings settings,
  ) {
    if (settings.ankiDesktopExecutable.trim().isNotEmpty) return null;
    return host.findRunningAnkiExecutable();
  }
}

/// [AnkiDesktopLauncher] 依赖的平台原语，抽出来是为了让编排逻辑可单测。
abstract interface class AnkiDesktopLauncherHost {
  bool get isDesktop;

  /// `Platform.operatingSystem` 的值域。
  String get operatingSystem;

  /// [host]:[port] 上是否有人接受 TCP 连接。
  Future<bool> isPortListening(String host, int port);

  String? findRunningAnkiExecutable();

  /// 分离启动 [command]，不等它退出。
  Future<void> start(AnkiDesktopLaunchCommand command);
}

class _RealAnkiDesktopLauncherHost implements AnkiDesktopLauncherHost {
  const _RealAnkiDesktopLauncherHost();

  static const Duration _probeTimeout = Duration(milliseconds: 800);

  @override
  bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  String get operatingSystem => Platform.operatingSystem;

  @override
  Future<bool> isPortListening(String host, int port) async {
    try {
      final Socket socket = await Socket.connect(
        host,
        port,
        timeout: _probeTimeout,
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  @override
  String? findRunningAnkiExecutable() =>
      AnkiDesktopForeground.findRunningAnkiExecutable();

  @override
  Future<void> start(AnkiDesktopLaunchCommand command) async {
    // detached：Anki 是独立程序，Fushi 退出不该带走它，也不留 stdio 管道。
    await Process.start(
      command.executable,
      command.arguments,
      workingDirectory: command.workingDirectory,
      mode: ProcessStartMode.detached,
    );
  }
}
