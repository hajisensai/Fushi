// 守卫（BUG-1074）：禁止在桌面可达代码里直接使用 image_picker。
//
// 本仓钉的 image_picker 0.8.7+5 只带 android/ios/for_web 实现（pubspec.lock），
// 桌面端 `ImagePicker().pickImage` 走默认 MethodChannel 直接抛
// MissingPluginException，async onTap 无人捕获 → UI 零反馈「点了没反应」。
// 图片选取必须统一走平台感知入口
// `lib/src/utils/misc/gallery_image_picker.dart`（移动端 image_picker 相册、
// 桌面端 file_picker）。
//
// 允许名单只有两个文件：
// - gallery_image_picker.dart：唯一的 image_picker 封装点（平台分流后才调用）；
// - camera_enhancement.dart：`ImageSource.camera` 无 file_picker 等价物，且已有
//   `isMobilePlatform` 门禁（`isAvailable` + enhanceCreatorParams 首行 return），
//   桌面不可达。
//
// 纯 dart:io 源码扫描，不依赖 Flutter 运行时。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/scan_scale.dart';

/// 允许直接引用 image_picker 的文件（相对 fushi/ 包根、正斜杠路径）。
const Set<String> _allowedFiles = <String>{
  'lib/src/utils/misc/gallery_image_picker.dart',
  'lib/src/creator/enhancements/camera_enhancement.dart',
};

/// 从当前 cwd 向上找 hibiki 包根（含 lib/src/utils/misc/gallery_image_picker.dart）。
Directory _packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/lib/src/utils/misc/gallery_image_picker.dart')
        .existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到 hibiki 包根（从 ${Directory.current.path} 向上）');
}

void main() {
  test('lib/ 下除允许名单外不得 import image_picker 或实例化 ImagePicker', () {
    final Directory root = _packageRoot();
    final Directory libDir = Directory('${root.path}/lib');
    final RegExp importRe = RegExp('package:image_picker/image_picker\\.dart');
    final RegExp instantiateRe = RegExp(r'\bImagePicker\s*\(');

    final List<String> violations = <String>[];
    int scanned = 0;
    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final String relative =
          entity.path.substring(root.path.length + 1).replaceAll('\\', '/');
      if (_allowedFiles.contains(relative)) continue;
      final String content = entity.readAsStringSync();
      if (importRe.hasMatch(content)) {
        violations.add('$relative: import image_picker');
      }
      if (instantiateRe.hasMatch(content)) {
        violations.add('$relative: 实例化 ImagePicker()');
      }
    }

    expectScanScale(scanned,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);

    expect(
      violations,
      isEmpty,
      reason: '桌面可达代码直接用 image_picker 会在 Windows/macOS/Linux 抛 '
          'MissingPluginException（BUG-1074）。图片选取请改走 '
          'lib/src/utils/misc/gallery_image_picker.dart 的 '
          'pickGalleryImageFile()。违规：\n${violations.join('\n')}',
    );
  });
}
