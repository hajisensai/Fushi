// BUG-4906：调试版流水线面板要对「本机跑的就是调试包」的人可见，不只看通道设置。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/updates_center_open.dart'
    show debugPulseUpdateChannel, showsDebugPulsePanel;
import 'package:fushi/src/utils/misc/platform_updater.dart' show UpdateChannel;

void main() {
  test('TestFlight / 调试 APK：通道没改（stable）但跑的是调试包 → 显示', () {
    expect(
      showsDebugPulsePanel(
        configuredChannel: UpdateChannel.stable,
        runningVersion: '3.4.0-debug.29190',
      ),
      isTrue,
    );
    expect(
      showsDebugPulsePanel(
        configuredChannel: UpdateChannel.beta,
        runningVersion: '3.4.0-debug.29190',
      ),
      isTrue,
    );
  });

  test('选了 debug 通道、还跑着正式包 → 显示（马上会收到调试包）', () {
    expect(
      showsDebugPulsePanel(
        configuredChannel: UpdateChannel.debug,
        runningVersion: '3.3.0',
      ),
      isTrue,
    );
  });

  test('正式 / 预发布包且没选 debug 通道 → 不显示', () {
    expect(
      showsDebugPulsePanel(
        configuredChannel: UpdateChannel.stable,
        runningVersion: '3.3.0',
      ),
      isFalse,
    );
    expect(
      showsDebugPulsePanel(
        configuredChannel: UpdateChannel.beta,
        runningVersion: '3.4.0-beta.2',
      ),
      isFalse,
    );
  });

  test('面板「更新」按钮恒按 debug 时间线查，不跟设置通道走', () {
    // 没有安装绑定（安卓 APK / iOS / Windows / macOS）：不管设置选的是哪条，都按 debug 查。
    expect(
      debugPulseUpdateChannel(installationChannel: null),
      UpdateChannel.debug,
    );
    expect(
      debugPulseUpdateChannel(installationChannel: UpdateChannel.debug),
      UpdateChannel.debug,
    );
    // 安装方式钉死在别的轨上（Flatpak branch）：检查层会改查那条轨，按钮就不给。
    expect(
      debugPulseUpdateChannel(installationChannel: UpdateChannel.stable),
      isNull,
    );
    expect(
      debugPulseUpdateChannel(installationChannel: UpdateChannel.beta),
      isNull,
    );
  });

  test('面板按钮把 debug 通道显式传进检查编排，编排据它而非设置去查', () {
    final String open = File(
      'lib/src/pages/implementations/updates_center_open.dart',
    ).readAsStringSync();
    expect(
      open,
      contains('checkAppUpdateNow(context, appModel, channel: updateChannel)'),
      reason: '面板按钮不能落回按设置通道检查（stable 通道 + 调试包会拿正式版比）',
    );
    final String check = File(
      'lib/src/updates/app_update_check.dart',
    ).readAsStringSync();
    expect(check, contains('channel ?? appUpdateChannelOf(appModel)'));
    expect(
      check,
      contains('debugChannel: effectiveChannel == UpdateChannel.debug'),
      reason: '显式通道必须一路传到 scheduleCheck，不能又读回设置',
    );
    expect(check, isNot(contains('debugChannel: appModel.updateDebugChannel')));
  });
}
