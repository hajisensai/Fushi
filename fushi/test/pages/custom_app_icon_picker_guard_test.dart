import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1239 源码守卫：自定义应用图标选图必须走 `file_picker`，不得用
/// `image_picker`。
///
/// 根因：`image_picker` 在桌面（Windows）无平台实现，直接调
/// `ImagePicker().pickImage(...)` 会抛
/// `MissingPluginException: No implementation found for method pickImage`，
/// 导致「自定义应用图标」点击无反应。自定义图标入口对 Android + Windows 都开放
/// （见 `MiscellaneousSettingsBody` 的 `Platform.isAndroid || Platform.isWindows`
/// 门控），故必须用两个平台都有实现、且已是本仓库依赖的 `file_picker`。
/// 若有人把这里改回 `image_picker`，桌面路径立刻回归到 MissingPluginException。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  const String page =
      'lib/src/pages/implementations/miscellaneous_settings_page.dart';

  test('自定义图标页不得引入 / 使用 image_picker', () {
    final String src = read(page);
    expect(src.contains('package:image_picker/image_picker.dart'), isFalse,
        reason: 'image_picker 桌面无实现，自定义图标页禁止 import image_picker（TODO-1239）');
    expect(src.contains('ImagePicker('), isFalse,
        reason: 'image_picker 桌面无实现，禁止调 ImagePicker()（TODO-1239）');
    expect(src.contains('.pickImage('), isFalse,
        reason: 'pickImage 在桌面抛 MissingPluginException，禁止使用（TODO-1239）');
  });

  test('自定义图标选图走 file_picker 的 pickFiles(FileType.image)', () {
    final String src = read(page);
    expect(src.contains('package:file_picker/file_picker.dart'), isTrue,
        reason: '必须 import file_picker（两平台均有实现）');
    expect(src.contains('FilePicker.platform.pickFiles('), isTrue,
        reason: '必须用 FilePicker.platform.pickFiles 选图');
    expect(src.contains('FileType.image'), isTrue,
        reason: '选图必须限定 FileType.image');
  });
}
