import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-935 ①A）：「引用原文件（不复制）」只能在桌面生效，移动端零回归。
///
/// 移动端 file_picker 返回的是 app 缓存里的临时副本，引用即指向会被系统清掉的
/// 文件。故两个导入对话框里：
///   1. 引用开关只在 `isDesktopPlatform` 为真时渲染；
///   2. 真正跳过复制的判据必须 `&& isDesktopPlatform` 双重门控（即使 UI 漏判，
///      落库逻辑也不会在移动端走引用分支）。
///
/// 这条扫描守卫钉住门控不被回归删除，使「移动端仍复制」成为编译期可验的契约。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('audiobook_import_dialog 引用分支双重门控 isDesktopPlatform', () {
    final String src =
        read('lib/src/media/audiobook/audiobook_import_dialog.dart');
    expect(
      RegExp(r'_referenceOriginal\s*&&\s*isDesktopPlatform').hasMatch(src),
      isTrue,
      reason: '引用复制判据必须 && isDesktopPlatform，否则移动端会引用缓存临时副本',
    );
    expect(
      src.contains('if (isDesktopPlatform)'),
      isTrue,
      reason: '引用开关 UI 必须 isDesktopPlatform 门控（移动端隐藏）',
    );
  });

  test('book_import_dialog 引用分支双重门控 isDesktopPlatform', () {
    final String src = read('lib/src/media/audiobook/book_import_dialog.dart');
    expect(
      RegExp(r'_referenceOriginal\s*&&\s*isDesktopPlatform').hasMatch(src),
      isTrue,
      reason: '引用复制判据必须 && isDesktopPlatform，否则移动端会引用缓存临时副本',
    );
    expect(
      RegExp(r'if \(isDesktopPlatform\s*&&\s*_audioPaths\.isNotEmpty\)')
          .hasMatch(src),
      isTrue,
      reason: '引用开关 UI 必须 isDesktopPlatform 门控（移动端隐藏）',
    );
  });

  test('删除有声书时引用的外部 audioRoot 不被递归删除', () {
    final String src = read('lib/src/sync/app_model_library_host_service.dart');
    // audioRoot 删除前必须经引用判据守卫（引用导入的外部目录不删）。
    expect(
      src.contains('AudiobookStorage.isReferencedPath'),
      isTrue,
      reason: 'deleteAudiobook 删 audioRoot 前必须用 isReferencedPath 守卫，'
          '否则会递归删用户引用导入的原始外部目录',
    );
    expect(
      RegExp(r'if \(!referenced\)').hasMatch(src),
      isTrue,
      reason: '只有非引用（app 内部副本）才允许 delete(recursive: true)',
    );
  });
}
