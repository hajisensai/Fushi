import 'dart:io';

import 'package:test/test.dart';

/// 设置层读平台只经 `hostPlatform`（`lib/src/platform/host_platform.dart`），
/// 不直读 `dart:io` 的 `Platform.isXxx`。
///
/// 设置项目录导出器（`settings_catalog_export_test.dart`）靠
/// `debugHostPlatformOverride` 在 Linux CI 上按四个出包平台各走一遍设置索引；
/// 设置层里任何一处直读 `Platform.isXxx` 都会让那一行的可见性 / 默认值在所有平台上
/// 静默退回 CI 宿主（Linux，不出包）的结果。
void main() {
  test('设置层不直读 Platform.isXxx', () {
    final List<File> files = <File>[
      ...Directory('lib/src/settings')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart')),
      File('lib/src/ops/settings_index.dart'),
      ...Directory('lib/src/ops').listSync().whereType<File>().where(
        (File f) =>
            f.uri.pathSegments.last.startsWith('ctl_settings_body_') &&
            f.path.endsWith('.dart'),
      ),
      // 设置行的可见性 / 默认值经这些判据间接读平台。
      File('lib/src/models/store_compliance.dart'),
      File('lib/src/sync/desktop_lookup_service.dart'),
      File('lib/src/floating_ball/floating_ball_config.dart'),
    ];
    expect(files.length, greaterThan(20), reason: '扫描范围没找到设置层源码');
    final RegExp direct = RegExp(
      r'(?<![\w.])Platform\.is(Windows|MacOS|Linux|Android|IOS|Fuchsia)\b',
    );
    final List<String> offenders = <String>[];
    for (final File file in files) {
      final List<String> lines = file.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (direct.hasMatch(line)) {
          offenders.add('${file.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '改用 hostPlatform.isXxx（见 host_platform.dart）：\n'
          '${offenders.join('\n')}',
    );
  });
}
