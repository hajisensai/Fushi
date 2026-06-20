import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../pages/reader_history_source_corpus.dart';

/// 源码守卫（Phase 3）：「新导入视频」入口必须门控在编译期常量
/// `kVideoImportEnabled` 后，且默认 `false`——防回归把入口直接挂出来。
///
/// 这是 UI 可见性约束，纯 widget 测试也能验，但用源码扫描钉死「入口被该常量
/// 门控」这一结构关系，避免有人改 build 时漏掉门控。书架仍展示已导入视频、点开
/// 仍可播放查词，不受此门控影响。
void main() {
  String read(String relPath) => File(relPath).readAsStringSync();

  test('kVideoImportEnabled 常量存在且默认 false（入口隐藏）', () {
    final String flags = read('lib/src/media/video/video_feature_flags.dart');
    expect(
      RegExp(r'const\s+bool\s+kVideoImportEnabled\s*=\s*false\s*;')
          .hasMatch(flags),
      isTrue,
      reason: 'kVideoImportEnabled 必须存在且默认 false，新导入入口才隐藏',
    );
  });

  test('书架页头的视频导入入口被 if (kVideoImportEnabled) 门控', () {
    final String page = readReaderHistorySource();
    // 门控条件出现，且其后紧跟视频导入入口（_openVideoImport）。
    final int gateAt = page.indexOf('if (kVideoImportEnabled)');
    expect(gateAt, greaterThanOrEqualTo(0),
        reason: '视频导入入口必须被 if (kVideoImportEnabled) 门控');
    final int entryAt = page.indexOf('onTap: _openVideoImport', gateAt);
    expect(entryAt, greaterThan(gateAt),
        reason: '_openVideoImport 入口必须落在 kVideoImportEnabled 门控之内');
    // 门控与入口之间不应再出现另一个 _headerAction(...) 闭合，防止门控套错了别的按钮。
    final String between = page.substring(gateAt, entryAt);
    expect(between.contains('onTap:'), isFalse,
        reason: '门控与视频入口之间不应夹着其他 action（确认门控的就是视频入口）');
  });
}
