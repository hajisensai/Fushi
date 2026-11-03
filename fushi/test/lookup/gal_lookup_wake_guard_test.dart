// 游戏内点词的唤醒通道：hook 发布点击后 SetEvent，runner 的查词泵立刻读，而不是
// 等下一拍 16ms 定时器。hook 侧行为由原生测试
// （native/galgame_hook/tests/geometry_provider_registry_test.cpp 的
// TestSubmitHitWakesHostPump）覆盖；这里钉住 runner 侧的接线，它没有原生单测。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final String reader = File(
    'windows/runner/voice_hook_reader.cpp',
  ).readAsStringSync();

  test('事件名两侧同源，runner 建事件并在线程池里等它', () {
    final String ensure = compactCode(
      methodBody(reader, 'void EnsureLookupWake(uint32_t pid) {'),
    );
    expect(ensure.contains('fushi_voice_hook::LookupWakeEventName('), isTrue);
    expect(ensure.contains('CreateEventW('), isTrue);
    expect(ensure.contains('RegisterWaitForSingleObject('), isTrue);
  });

  test('唤醒只是第二个入口：同一个泵函数、只在跟手节拍下响应、定时器保留', () {
    final String proc = compactCode(
      methodBody(reader, 'LRESULT CALLBACK LookupPumpProc('),
    );
    expect(proc.contains('message==kLookupWakeMessage'), isTrue);
    expect(
      proc.contains('pump.timer_interval_ms==kLookupPumpIntervalMs'),
      isTrue,
      reason: '查词没开时泵只报准入，点击不能被提前消费',
    );
    expect(proc.contains('WM_TIMER'), isTrue);
  });

  test('会话结束停泵时一并注销等待、关闭事件', () {
    final String stop = compactCode(
      methodBody(reader, 'void StopLookupPump() {'),
    );
    expect(stop.contains('StopLookupWake();'), isTrue);
    final String sync = compactCode(
      methodBody(reader, 'void SyncLookupPump() {'),
    );
    expect(sync.contains('EnsureLookupWake(reader.CurrentPid());'), isTrue);
  });
}
