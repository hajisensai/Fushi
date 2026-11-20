// BUG-4906：调试版流水线面板要对「本机跑的就是调试包」的人可见，不只看通道设置。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/updates_center_open.dart'
    show showsDebugPulsePanel;
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
}
