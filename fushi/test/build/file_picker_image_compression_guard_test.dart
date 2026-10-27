/// 守卫（BUG-3601 复查 / 反馈 WkL9BvD7Z9）：`pickFiles(type: FileType.image)` 必须显式
/// `allowCompression: false`。
///
/// ## 为什么
///
/// file_picker 8.x 的 Dart 侧默认 `allowCompression = true`、`compressionQuality = 30`。
/// 安卓插件收到 `image/*` 结果后，在一条**没有任何异常处理的裸 `new Thread`**
/// （`FilePickerDelegate.onActivityResult`）里调 `FileUtils.compressImage`：
///
/// - `createImageFile()` 往 `Environment.getExternalStoragePublicDirectory(PICTURES)`
///   建临时文件——Android 9/10 没有运行时授予 `WRITE_EXTERNAL_STORAGE`（本仓从不申请
///   它来选图）就抛 `IOException`，被包成 `RuntimeException` 重抛；
/// - `BitmapFactory.decodeStream` 全分辨率解码，内存不足 / 格式不支持返回 null，下一行
///   `.compress` 抛 NPE。
///
/// 裸线程上的未捕获异常直接杀掉整个进程，Dart 侧零日志——这正是 Android 9 vivo 上
/// 「换应用图标闪退」、BUG-3601 修完裁剪链路后仍复现的那条路径（用户在选图这一步
/// 就死了，走不到裁剪）。压缩本身也有害（质量 30 的有损 JPEG、丢 PNG 透明通道）。
///
/// ## 守什么
///
/// 扫 `lib/` 全部 `.dart`：凡是参数里出现 `FileType.image` 的 `pickFiles(...)` 调用，
/// 参数里必须有 `allowCompression: false`。注释先等长掩掉（注释里的举例不算调用）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 从 [open]（指向 `(`）开始按括号配对，返回参数文本（不含两端括号）；配不上返回 null。
String? _argumentSpan(String code, int open) {
  int depth = 0;
  for (int i = open; i < code.length; i++) {
    final String c = code[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return code.substring(open + 1, i);
    }
  }
  return null;
}

/// [code] 里每一处 `pickFiles(` 调用的参数文本。
List<String> pickFilesArguments(String code) {
  final RegExp call = RegExp(r'\.\s*pickFiles\s*\(');
  final List<String> out = <String>[];
  for (final RegExpMatch m in call.allMatches(code)) {
    final String? args = _argumentSpan(code, m.end - 1);
    if (args != null) out.add(args);
  }
  return out;
}

/// 违规：参数里有 `FileType.image` 却没有 `allowCompression: false`。
bool violatesImageCompressionRule(String args) =>
    args.contains('FileType.image') &&
    !RegExp(r'allowCompression\s*:\s*false').hasMatch(args);

void main() {
  test('判据自检：缺 allowCompression:false 的 image 选择算违规', () {
    expect(
      pickFilesArguments(
        'await FilePicker.platform\n    .pickFiles(\n  type: FileType.image,\n);',
      ).where(violatesImageCompressionRule),
      hasLength(1),
    );
    expect(
      pickFilesArguments(
        'FilePicker.platform.pickFiles(type: FileType.image, '
        'allowCompression: false, withData: f(x))',
      ).where(violatesImageCompressionRule),
      isEmpty,
    );
    expect(
      pickFilesArguments(
        'fp.pickFiles(type: FileType.any)',
      ).where(violatesImageCompressionRule),
      isEmpty,
    );
  });

  test('lib/ 下所有 FileType.image 的 pickFiles 都关掉了安卓重压缩', () {
    final List<File> files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();
    int imageCalls = 0;
    final List<String> offenders = <String>[];
    for (final File f in files) {
      final String code = maskCommentsAndScriptLines(f.readAsStringSync());
      for (final String args in pickFilesArguments(code)) {
        if (args.contains('FileType.image')) imageCalls++;
        if (violatesImageCompressionRule(args)) {
          offenders.add(f.path.replaceAll(r'\', '/'));
        }
      }
    }
    // 扫描面哨兵：现有三处（应用图标 / 书封面 / 制卡图片桌面分支），扫不到说明守卫空转。
    expect(
      imageCalls,
      greaterThanOrEqualTo(3),
      reason: '没扫到 FileType.image 的 pickFiles 调用，守卫可能空转',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'file_picker 安卓默认在裸线程里重压缩 image/*，Android 9/10 缺存储写权限或'
          '解码失败时直接杀进程（BUG-3601 复查 / WkL9BvD7Z9）。给这些调用加 '
          '`allowCompression: false`。',
    );
  });
}
