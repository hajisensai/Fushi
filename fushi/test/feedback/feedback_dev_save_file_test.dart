// 处理台「另存样本文件」（saveFeedbackSampleFile）：桌面端调 saveFile 不带 bytes、拿到路径后
// 自己写盘（file_picker 8.x 的 macOS 实现收到 bytes 直接抛 UnsupportedError）；移动端把 bytes
// 交给插件写，自己不再写。

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_dev_page.dart';
import 'package:path/path.dart' as p;

/// 照 file_picker 8.3.7 的 macOS 行为：带 bytes 就抛；否则回 [path]。
class _MacLikePicker extends FilePicker {
  _MacLikePicker(this.path);

  final String? path;
  int calls = 0;
  Uint8List? lastBytes;

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
    calls++;
    lastBytes = bytes;
    if (bytes != null) {
      throw UnsupportedError('Bytes are not supported on macOS');
    }
    return path;
  }
}

/// 移动端插件：收 bytes 并由它写到 [path]。
class _MobilePicker extends FilePicker {
  _MobilePicker(this.path);

  final String path;
  Uint8List? lastBytes;

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
    lastBytes = bytes;
    return path;
  }
}

void main() {
  late Directory root;
  final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

  setUp(() => root = Directory.systemTemp.createTempSync('fushi_dev_save_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('桌面端：saveFile 不带 bytes（macOS 插件带了就抛），拿到路径后自己写一次', () async {
    final String target = p.join(root.path, 'ep01.srt');
    final _MacLikePicker picker = _MacLikePicker(target);
    final bool saved = await saveFeedbackSampleFile(
      picker: picker,
      desktop: true,
      dialogTitle: 'Save',
      fileName: 'ep01.srt',
      bytes: bytes,
    );
    expect(saved, isTrue);
    expect(picker.calls, 1);
    expect(picker.lastBytes, isNull);
    expect(File(target).readAsBytesSync(), bytes);
  });

  test('桌面端用户取消：不写、返回 false', () async {
    final _MacLikePicker picker = _MacLikePicker(null);
    final bool saved = await saveFeedbackSampleFile(
      picker: picker,
      desktop: true,
      dialogTitle: 'Save',
      fileName: 'ep01.srt',
      bytes: bytes,
    );
    expect(saved, isFalse);
    expect(root.listSync(), isEmpty);
  });

  test('移动端：bytes 交给插件写，自己不写', () async {
    final String target = p.join(root.path, 'never-written.srt');
    final _MobilePicker picker = _MobilePicker(target);
    final bool saved = await saveFeedbackSampleFile(
      picker: picker,
      desktop: false,
      dialogTitle: 'Save',
      fileName: 'ep01.srt',
      bytes: bytes,
    );
    expect(saved, isTrue);
    expect(picker.lastBytes, bytes);
    expect(File(target).existsSync(), isFalse);
  });
}
