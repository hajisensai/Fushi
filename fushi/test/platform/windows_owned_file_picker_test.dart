// BUG-3286：Windows 视频全屏（HWND_TOPMOST 巨窗）时，file_picker 默认的无 owner
// 系统对话框被压在全屏窗口下。修法是在 FilePicker.platform 层请求 lockParentWindow
// （对话框以主窗为 owner，z 序恒在 owner 之上），但只在前台窗口属于本进程时请求
// （否则 file_picker 会把别的进程的窗口当 owner）。这里钉住：前台是本进程时三种
// 对话框都带 owner、不是时都不带、其余参数原样透传、只在 Windows 装、重复装不会
// 套两层。
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/desktop/windows_owned_file_picker.dart';

class _RecordingFilePicker extends FilePicker {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

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
  }) async {
    calls.add(<String, Object?>{
      'op': 'pickFiles',
      'dialogTitle': dialogTitle,
      'initialDirectory': initialDirectory,
      'type': type,
      'allowedExtensions': allowedExtensions,
      'allowMultiple': allowMultiple,
      'withData': withData,
      'lockParentWindow': lockParentWindow,
    });
    return null;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    calls.add(<String, Object?>{
      'op': 'getDirectoryPath',
      'dialogTitle': dialogTitle,
      'initialDirectory': initialDirectory,
      'lockParentWindow': lockParentWindow,
    });
    return 'D:/dir';
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    calls.add(<String, Object?>{
      'op': 'saveFile',
      'fileName': fileName,
      'type': type,
      'allowedExtensions': allowedExtensions,
      'lockParentWindow': lockParentWindow,
    });
    return 'D:/out.mp4';
  }
}

void main() {
  // FilePicker.platform 在 host 测试里没有注册实现（getter 读未初始化的 late 字段），
  // 每条用例自己装假实现；本文件独立 isolate，不污染别的测试。
  test('三种系统对话框都以主窗为 owner，其余参数原样透传', () async {
    final _RecordingFilePicker inner = _RecordingFilePicker();
    final WindowsOwnedFilePicker picker = WindowsOwnedFilePicker(
      inner,
      foregroundWindowIsOurs: () => true,
    );

    await picker.pickFiles(
      dialogTitle: 'sub',
      type: FileType.custom,
      allowedExtensions: <String>['ass', 'srt'],
      allowMultiple: true,
      withData: true,
    );
    expect(await picker.getDirectoryPath(initialDirectory: 'C:/'), 'D:/dir');
    expect(
      await picker.saveFile(
        fileName: 'clip.mp4',
        type: FileType.custom,
        allowedExtensions: <String>['mp4'],
      ),
      'D:/out.mp4',
    );

    expect(inner.calls, hasLength(3));
    for (final Map<String, Object?> call in inner.calls) {
      expect(call['lockParentWindow'], isTrue, reason: '${call['op']}');
    }
    expect(inner.calls[0]['dialogTitle'], 'sub');
    expect(inner.calls[0]['type'], FileType.custom);
    expect(inner.calls[0]['allowedExtensions'], <String>['ass', 'srt']);
    expect(inner.calls[0]['allowMultiple'], isTrue);
    expect(inner.calls[0]['withData'], isTrue);
    expect(inner.calls[1]['initialDirectory'], 'C:/');
    expect(inner.calls[2]['fileName'], 'clip.mp4');
    expect(inner.calls[2]['allowedExtensions'], <String>['mp4']);
  });

  // PR #2081 审查：file_picker 8.3.7 选目录拿 GetForegroundWindow() 当 owner、打开 /
  // 保存拿 FindWindowA（z 序第一个 runner 类窗口）。Fushi 不在前台时这两种取法都可能
  // 取到别的进程的窗口并把它设成模态 owner（被禁用）。前台不是本进程 ⇒ 不请求 owner。
  test('前台窗口不属于本进程时，三种对话框都不请求 owner', () async {
    final _RecordingFilePicker inner = _RecordingFilePicker();
    final WindowsOwnedFilePicker picker = WindowsOwnedFilePicker(
      inner,
      foregroundWindowIsOurs: () => false,
    );

    await picker.pickFiles(dialogTitle: 'sub');
    await picker.getDirectoryPath(initialDirectory: 'C:/');
    await picker.saveFile(fileName: 'clip.mp4');

    expect(inner.calls, hasLength(3));
    for (final Map<String, Object?> call in inner.calls) {
      expect(call['lockParentWindow'], isFalse, reason: '${call['op']}');
    }
    // 其余参数照旧透传。
    expect(inner.calls[0]['dialogTitle'], 'sub');
    expect(inner.calls[1]['initialDirectory'], 'C:/');
    expect(inner.calls[2]['fileName'], 'clip.mp4');
  });

  test('前台归属在每次弹框时现查，不在构造时缓存', () async {
    final _RecordingFilePicker inner = _RecordingFilePicker();
    bool ours = true;
    final WindowsOwnedFilePicker picker = WindowsOwnedFilePicker(
      inner,
      foregroundWindowIsOurs: () => ours,
    );

    await picker.getDirectoryPath();
    ours = false;
    await picker.getDirectoryPath();
    ours = true;
    await picker.getDirectoryPath();

    expect(
      inner.calls.map((Map<String, Object?> c) => c['lockParentWindow']),
      <bool>[true, false, true],
    );
  });

  test('只在 Windows 装，且重复装不会套两层', () {
    final _RecordingFilePicker inner = _RecordingFilePicker();
    FilePicker.platform = inner;

    installWindowsOwnedFilePicker(isWindows: false);
    expect(FilePicker.platform, same(inner));

    installWindowsOwnedFilePicker(isWindows: true);
    final FilePicker installed = FilePicker.platform;
    expect(installed, isA<WindowsOwnedFilePicker>());
    expect((installed as WindowsOwnedFilePicker).inner, same(inner));

    installWindowsOwnedFilePicker(isWindows: true);
    expect(FilePicker.platform, same(installed));
  });

  test('生产入口 main() 装了它（源码守卫）', () {
    // main() 无法在 host 测试里跑；漏装 = 全屏下对话框又被压住且静默。
    final String mainSource = _readMain();
    expect(mainSource, contains('installWindowsOwnedFilePicker();'));
  });
}

String _readMain() {
  return File('lib/main.dart').readAsStringSync();
}
