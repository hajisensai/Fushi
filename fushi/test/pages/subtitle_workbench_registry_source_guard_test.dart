import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3000 守卫：字幕工作台的字幕来源不得绑在下载管线的生命周期上。
///
/// `AppModel.videoSubtitleRegistry` 只在下载管线启动后才有值（浏览模块关着 / 启动
/// 途中 / 启动抛错时恒为 null）。工作台曾直接读它，于是 key 明明填了，合集页报
/// 「请先填写 Jimaku API key」、单集页静默显示「找不到字幕」。生产宿主必须走
/// `AppModel.subtitleSearchRegistry()`（管线不在时按同一份工厂现建）。
void main() {
  test('AppSubtitleWorkbenchHost 经 subtitleSearchRegistry 取字幕来源', () {
    final String source = File(
      'lib/src/pages/implementations/subtitle_workbench_page.dart',
    ).readAsStringSync();
    final int start = source.indexOf('class AppSubtitleWorkbenchHost');
    expect(start, isNonNegative);
    final int end = source.indexOf('\n}\n', start);
    final String host = source.substring(start, end);

    expect(host, contains('appModel.subtitleSearchRegistry()'));
    expect(
      host,
      isNot(contains('videoSubtitleRegistry')),
      reason: '下载管线没起来时它是 null，字幕搜索不能依赖下载模块',
    );
  });
}
