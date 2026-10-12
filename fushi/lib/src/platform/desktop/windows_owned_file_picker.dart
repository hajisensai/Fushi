import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

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
/// owner 由 file_picker 自己定位（打开 / 保存走 `FindWindowA` 找 runner 的窗口类
/// `FLUTTER_RUNNER_WIN32_WINDOW`，选目录走 `GetForegroundWindow`）；本进程只有一个
/// 该类窗口，用户点按钮时它在前台、位于同带 z 序最上，取到的就是 Fushi 主窗。
/// 副作用是对话框期间主窗被禁用（标准模态行为），与对话框的语义一致。
class WindowsOwnedFilePicker extends FilePicker {
  /// 包住平台注册的实现 [inner]；所有参数原样透传，只把 `lockParentWindow` 钉成 true。
  WindowsOwnedFilePicker(this.inner);

  /// 被包住的平台实现（生产上是 file_picker 的 `FilePickerWindows`）。
  final FilePicker inner;

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
    lockParentWindow: true,
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
    lockParentWindow: true,
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
    lockParentWindow: true,
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
