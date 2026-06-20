import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：阅读器与视频两张「快速设置」sheet 的外壳骨架已抽到共享
/// `HibikiMasterDetailSettingsSheet`（TODO-583，零行为变化）。锁住下沉的骨架字符串
/// （PopScope + HibikiModalSheetFrame + 几何判据 + 窄窗 SingleChildScrollView +
/// AnimatedSize）以及返回页头 `HibikiSettingsSubPageHeader` 仍在共享文件里，防回潮。
String _between(String source, String start, String end) {
  final int s = source.indexOf(start);
  expect(s, isNonNegative, reason: 'missing marker: $start');
  final int e = source.indexOf(end, s);
  expect(e, isNonNegative, reason: 'missing marker: $end');
  return source.substring(s, e);
}

void main() {
  final String source =
      File('lib/src/settings/master_detail_settings_sheet.dart')
          .readAsStringSync();

  test('shared sheet exposes both extracted widgets', () {
    expect(source, contains('class HibikiSettingsSubPageHeader'));
    expect(source, contains('class HibikiMasterDetailSettingsSheet'));
  });

  test('master-detail shell owns the modal sheet chrome skeleton', () {
    // HibikiMasterDetailSettingsSheet 是文件最后一个类，切到文件末尾。
    final int shellStart =
        source.indexOf('class HibikiMasterDetailSettingsSheet');
    expect(shellStart, isNonNegative);
    final String shell = source.substring(shellStart);

    // 外壳骨架（从两张 sheet 下沉，BUG-096 同源）。
    expect(shell, contains('PopScope('));
    expect(shell, contains('canPop: !subPageActive || isWide'));
    expect(shell, contains('HibikiModalSheetFrame('));
    expect(shell, contains('maxHeightFactor: maxHeightFactor'));
    expect(shell, contains('scrollable: false'));
    expect(shell, contains('LayoutBuilder('));
    // 确定性几何判据：宽且高都 >= 共享阈值常量才进宽窗（与书籍/视频原判据等价）。
    expect(shell,
        contains('constraints.maxWidth >= kHibikiSettingsWideThreshold'));
    expect(shell,
        contains('constraints.maxHeight >= kHibikiSettingsWideMinHeight'));
    // 宽/窄分发：宽窗交给调用方 wideBuilder（两边发散），窄窗在外壳包
    // SingleChildScrollView + AnimatedSize（200ms / topCenter）。
    expect(shell, contains('return wideBuilder(context, constraints);'));
    expect(shell, contains('SingleChildScrollView('));
    expect(shell, contains('key: narrowKey()'));
    expect(shell, contains('padding: narrowPadding(context, constraints)'));
    expect(shell, contains('AnimatedSize('));
    expect(shell, contains('duration: const Duration(milliseconds: 200)'));
    expect(shell, contains('alignment: Alignment.topCenter'));
    expect(shell, contains('child: narrowChild(context, constraints)'));
    // 几何判定结果回写给调用方，供 PopScope.canPop 下一帧读取。
    expect(shell, contains('onWideChanged(wide)'));

    // 默认 maxHeightFactor 0.80（两张 sheet 原值）。
    expect(source, contains('this.maxHeightFactor = 0.80'));
  });

  test('extracted sub-page back header keeps the platform-adaptive chrome', () {
    final String header = _between(
      source,
      'class HibikiSettingsSubPageHeader',
      'class HibikiMasterDetailSettingsSheet',
    );
    // Cupertino 用 navTitleTextStyle，其余平台用主题 titleMedium（不写死字号）。
    expect(header, contains('navTitleTextStyle'));
    expect(header, isNot(contains('fontSize: 17')));
    // 返回按钮：Cupertino 走 CupertinoButton，其余走共享 HibikiIconButton。
    expect(header, contains('CupertinoButton('));
    expect(header, contains('HibikiIconButton('));
    expect(header, isNot(contains('return IconButton(')));
    expect(header, contains('overflow: TextOverflow.ellipsis'));
  });
}
