import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';

/// Windows 上让所有系统文件对话框都以 Fushi 主窗口为 owner（BUG-3286）。
///
/// file_picker 的 Windows 实现在 `lockParentWindow == false`（默认）时把
/// `hwndOwner` 置 NULL，对话框是无 owner 的顶层窗口。而视频全屏是「保边框巨窗 +
/// `HWND_TOPMOST`」（`windows/runner/win32_window.cpp` `SetFullscreen`，BUG-1933），
/// 主窗失活时又会 `HWND_NOTOPMOST` 重排到非置顶层顶端（`WM_ACTIVATE`）——无 owner
/// 的对话框于是被压在全屏视频下面，用户只能先退出全屏才看得见它。
///
/// 有 owner 的窗口在 z 序上恒位于 owner 之上（owner 置顶 / 取消置顶时随之移动），
/// 所以修法是把 owner 交给对话框，而不是在调用点各自退全屏。放在
/// [FilePicker.platform] 这一层装一次，二十几个调用点（字幕导入、片段导出另存为、
/// 导入目录……）全部覆盖，后来新增的调用点也不会漏。
///
/// 这是**平台实现的装饰层**，不是选择器调用点：每个方法都只把调用原样转给 [inner]，
/// 唯一改动的参数是 `lockParentWindow`；安卓 / iOS 的真实路径分流仍在统一入口
/// `real_path_directory_picker.dart`，这里只在 Windows 装（见
/// `test/tools/file_picker_discipline_guard_test.dart` 的装饰层豁免）。
///
/// owner 由 file_picker 自己定位，且**不接受外部传入的 HWND**：
/// - 选目录（8.3.7 `getDirectoryPath`）取 `GetForegroundWindow()`：前台是谁 owner
///   就是谁。Fushi 不在前台时（对话框由异步流程弹出、用户已切走）会把**别的进程**
///   的窗口设成模态 owner 并禁用它（PR #2081 审查）。
/// - 打开 / 保存取 `FindWindowA('FLUTTER_RUNNER_WIN32_WINDOW')`：z 序上第一个该类
///   顶层窗口。Fushi 不在前台时，同机别的 Flutter 应用主窗可能排在前面被取到。
/// 所以三种对话框统一按事实决定：**前台窗口属于本进程**才请求 owner，否则保持无
/// owner（即改动前的行为）。前台是本进程窗口时，选目录取到的就是它；打开 / 保存
/// 取到的是 z 序最前的 runner 窗口，本进程窗口在前台时排在最前。选目录的判定与
/// file_picker 取前台在同一个同步调用栈里先后发生（中间没有 await）。
///
/// 副作用是对话框期间 owner 被禁用（标准模态行为），与对话框的语义一致。
class WindowsOwnedFilePicker extends FilePicker {
  /// 包住平台注册的实现 [inner]；所有参数原样透传，只决定 `lockParentWindow`。
  ///
  /// [foregroundWindowIsOurs] 判定「当前前台窗口是否属于本进程」，默认走既有的
  /// Win32 探测 [DesktopForegroundGuard.isForegroundOwnedByCurrentProcess]；
  /// 测试注入假实现。
  WindowsOwnedFilePicker(this.inner, {bool Function()? foregroundWindowIsOurs})
    : _foregroundWindowIsOurs =
          foregroundWindowIsOurs ??
          DesktopForegroundGuard.isForegroundOwnedByCurrentProcess;

  /// 被包住的平台实现（生产上是 file_picker 的 `FilePickerWindows`）。
  final FilePicker inner;

  final bool Function() _foregroundWindowIsOurs;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) => inner.pickFiles(
    dialogTitle: dialogTitle,
    initialDirectory: initialDirectory,
    type: type,
    allowedExtensions: allowedExtensions,
    onFileLoading: onFileLoading,
    allowCompression: allowCompression,
    compressionQuality: compressionQuality,
    allowMultiple: allowMultiple,
    withData: withData,
    withReadStream: withReadStream,
    lockParentWindow: _foregroundWindowIsOurs(),
    readSequential: readSequential,
  );

  @override
  Future<bool?> clearTemporaryFiles() => inner.clearTemporaryFiles();

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) => inner.getDirectoryPath(
    dialogTitle: dialogTitle,
    lockParentWindow: _foregroundWindowIsOurs(),
    initialDirectory: initialDirectory,
  );

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) => inner.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    initialDirectory: initialDirectory,
    type: type,
    allowedExtensions: allowedExtensions,
    bytes: bytes,
    lockParentWindow: _foregroundWindowIsOurs(),
  );
}

/// 在 Windows 上把 [FilePicker.platform] 换成 [WindowsOwnedFilePicker]；其它平台
/// 不动（`lockParentWindow` 只有 Windows 实现读）。幂等：已装过就不再套一层。
void installWindowsOwnedFilePicker({bool? isWindows}) {
  if (!(isWindows ?? Platform.isWindows)) return;
  final FilePicker current = FilePicker.platform;
  if (current is WindowsOwnedFilePicker) return;
  FilePicker.platform = WindowsOwnedFilePicker(current);
}
