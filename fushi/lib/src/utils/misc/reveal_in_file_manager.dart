import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// 在系统文件管理器里定位一条本地路径的唯一原语（三桌面端）。
///
/// 归属：这套 argv 形状原本长在视频下载面板里（`videoDownloadReveal*`），但它和视频
/// 下载没有任何关系——是纯粹的「路径 → 文件管理器」平台边界。书架的「打开文件位置」
/// 需要同一行为，与其复制第二份 explorer 调用（仓库里已经因此踩过 BUG-920 那种正/反
/// 斜杠坑），不如把原语搬到中立位置、两个调用方共用。
///
/// 契约：能选中就选中文件本身、否则打开其所在目录；移动端**没有**文件管理器契约，
/// [currentRevealHost] 返回 null，调用方据此整条隐藏入口，而不是画一个点了没反应的
/// 按钮。
enum RevealHost { windows, macos, linux }

/// 当前平台的文件管理器宿主；移动端返回 null（无契约，入口必须隐藏）。
RevealHost? currentRevealHost() {
  if (Platform.isWindows) return RevealHost.windows;
  if (Platform.isMacOS) return RevealHost.macos;
  if (Platform.isLinux) return RevealHost.linux;
  return null;
}

/// 一条已解析的文件管理器调用，外加「它的退出码是否有意义」。见 [revealCommand]。
class RevealCommand {
  /// 用可执行文件 [executable]、参数 [arguments] 和退出码语义
  /// [exitCodeIsMeaningful] 构造。
  const RevealCommand({
    required this.executable,
    required this.arguments,
    required this.exitCodeIsMeaningful,
  });

  /// 要启动的可执行文件（`explorer` / `open` / `xdg-open`）。
  final String executable;

  /// 传给它的 argv；顺序与拆分方式本身就是契约的一部分，见 [revealCommand]。
  final List<String> arguments;

  /// false = 该进程报的状态与成功无关，能把它启动起来就是唯一可得的信号。
  final bool exitCodeIsMeaningful;
}

/// 为 [host] 构造文件管理器调用。
///
/// Windows specifics, measured on Windows 11 by launching each form and
/// reading back the opened window through `Shell.Application`:
/// * `explorer.exe` exits with 1 on every form, including the ones that open
///   and select correctly, so its exit code carries no success signal.
/// * `/select,` and the path must stay two separate argv entries. Dart quotes
///   any argument containing a space, so joining them into `/select,<path>`
///   yields the command line `explorer "/select,C:\dir\file.mkv"`, which
///   explorer answers by opening Documents instead - 3/3 runs, with and
///   without spaces in the path. The split form selected the file in every
///   run.
RevealCommand revealCommand({
  required RevealHost host,
  required String path,
  required bool isDirectory,
}) {
  switch (host) {
    case RevealHost.windows:
      final String windowsPath = p.normalize(path).replaceAll('/', r'\');
      return RevealCommand(
        executable: 'explorer',
        arguments: isDirectory
            ? <String>[windowsPath]
            : <String>['/select,', windowsPath],
        exitCodeIsMeaningful: false,
      );
    case RevealHost.macos:
      return RevealCommand(
        executable: 'open',
        arguments: isDirectory ? <String>[path] : <String>['-R', path],
        exitCodeIsMeaningful: true,
      );
    case RevealHost.linux:
      return RevealCommand(
        executable: 'xdg-open',
        arguments: <String>[isDirectory ? path : p.dirname(path)],
        exitCodeIsMeaningful: true,
      );
  }
}

/// 在系统文件管理器里打开 [path]：支持选中的平台选中文件本身，目录则直接打开。
///
/// 返回 false = 平台无文件管理器契约、路径已不存在，或启动失败——调用方据此提示，
/// 不要吞掉。
Future<bool> revealInFileManager(String path) => revealInFileManagerOn(
      path,
      host: currentRevealHost(),
      typeOf: (String value) =>
          FileSystemEntity.type(value, followLinks: false),
      run: Process.run,
    );

/// [revealInFileManager] 的可注入内核：让 per-host 的 argv 形状与退出码策略脱离真实
/// 文件管理器可测。
@visibleForTesting
Future<bool> revealInFileManagerOn(
  String path, {
  required RevealHost? host,
  required Future<FileSystemEntityType> Function(String path) typeOf,
  required Future<ProcessResult> Function(
    String executable,
    List<String> arguments,
  ) run,
}) async {
  if (host == null) return false;
  final FileSystemEntityType type = await typeOf(path);
  if (type == FileSystemEntityType.notFound) return false;
  final RevealCommand command = revealCommand(
    host: host,
    path: path,
    isDirectory: type == FileSystemEntityType.directory,
  );
  try {
    final ProcessResult result = await run(
      command.executable,
      command.arguments,
    );
    if (!command.exitCodeIsMeaningful) return true;
    return result.exitCode == 0;
  } on Object {
    return false;
  }
}
