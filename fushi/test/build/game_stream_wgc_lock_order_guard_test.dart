// BUG-2909 源码守卫：游戏串流停止时整个 app 卡死（主线程停泵，看门狗抓到 hang dump）。
//
// 两份用户 dump 的主线程都停在 track dispose → FushiGameStreamCaptureImpl::Stop
// → thread_.join()。被 join 的捕获线程在 IdleTick 里先拿 frame_mutex_、再在
// ID3D11DeviceContext::Unmap 里等 D3D11 设备锁；而 WGC 的 PresentThread 是
// **先持设备锁**（ContentUpdated → FirePresentEvent）再回调 FrameArrived 去拿
// frame_mutex_——锁序反转（ABBA），两边永远等对方。
// C++ 无法在 Dart 测试里执行，故在源码层锁死锁序：
//   ① 设备显式开启多线程保护，设备锁可被我们自己按序获取；
//   ② 每个「拿 frame_mutex_ 后会碰 D3D」的入口，都先进设备锁再拿 frame_mutex_；
//   ③ StartCapture 不得在持 frame_mutex_ 的建会话段里调用（会话一开，回调就会
//      带着设备锁来拿 frame_mutex_）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 取类内（两格缩进）方法体：从签名到第一个两格缩进的闭合花括号。
String methodBody(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: '找不到方法：$signature');
  final int end = source.indexOf('\n  }\n', start);
  expect(end, isNonNegative, reason: '找不到方法结尾：$signature');
  return source.substring(start, end);
}

void main() {
  final String capture = File(
    'windows/runner/game_stream_webrtc_capture.cpp',
  ).readAsStringSync();

  const String deviceLock = 'DeviceLock device_lock(multithread_);';
  const String frameLock = 'std::lock_guard<std::mutex> lock(frame_mutex_);';

  test('① 设备开启多线程保护并保存 ID3D11Multithread', () {
    final String setup = methodBody(capture, 'std::string SetupCaptureLocked() {');
    expect(setup.contains('d3d_.As(&multithread_)'), isTrue);
    expect(
      setup.contains('multithread_->SetMultithreadProtected(TRUE);'),
      isTrue,
      reason: '不开保护时设备锁不生效，WGC 与本线程共用 immediate context 无序',
    );
  });

  test('② 会碰 D3D 的 frame_mutex_ 入口一律先进设备锁', () {
    for (final String signature in <String>[
      'HRESULT OnFrameArrived(WGC::IDirect3D11CaptureFramePool* pool) {',
      'void IdleTick() {',
    ]) {
      final String body = methodBody(capture, signature);
      final int deviceAt = body.indexOf(deviceLock);
      final int frameAt = body.indexOf(frameLock);
      expect(deviceAt, isNonNegative, reason: '$signature 缺设备锁');
      expect(frameAt, isNonNegative, reason: '$signature 缺 frame_mutex_');
      expect(
        deviceAt < frameAt,
        isTrue,
        reason: '$signature 必须先设备锁后 frame_mutex_（与 WGC 回调同序）',
      );
    }

    // Teardown 的收尾块在 frame_mutex_ 下释放 D3D 资源，同样先进设备锁；
    // 开头只置 teardown_ 的那一段不碰 D3D，不受约束。
    final String teardown = methodBody(capture, 'void TeardownCapture() {');
    final int lastFrame = teardown.lastIndexOf(frameLock);
    final int lastDevice = teardown.lastIndexOf(deviceLock);
    expect(lastDevice, isNonNegative, reason: 'Teardown 收尾块缺设备锁');
    expect(lastDevice < lastFrame, isTrue);
    expect(
      teardown.substring(lastDevice, lastFrame).trim(),
      deviceLock,
      reason: '设备锁必须紧挨着收尾块的 frame_mutex_',
    );
  });

  test('② 其余持 frame_mutex_ 的段不碰 D3D', () {
    // 全文件里每个 frame_mutex_ 要么紧跟在设备锁之后，要么属于下面这些不碰
    // immediate context 的段（置 teardown_ / 建会话前的初始化）。
    final RegExp frameLockLine = RegExp(
      r'^([ \t]*)std::lock_guard<std::mutex> lock\(frame_mutex_\);$',
      multiLine: true,
    );
    final List<String> lines = capture.split('\n');
    int guarded = 0;
    int exempt = 0;
    for (int i = 0; i < lines.length; i++) {
      if (!frameLockLine.hasMatch(lines[i])) continue;
      final String previous = lines[i - 1].trim();
      final String next = lines[i + 1].trim();
      if (previous == deviceLock) {
        guarded++;
      } else if (next == 'teardown_ = true;' || next == 'teardown_ = false;') {
        exempt++;
      } else {
        fail('第 ${i + 1} 行持 frame_mutex_ 却没先进设备锁：${lines[i + 1]}');
      }
    }
    expect(guarded, 3, reason: 'OnFrameArrived / IdleTick / Teardown 收尾');
    expect(exempt, 2, reason: 'Teardown 开头置位 + ThreadMain 建会话段');
  });

  test('③ StartCapture 在 frame_mutex_ 之外调用', () {
    final String setup = methodBody(capture, 'std::string SetupCaptureLocked() {');
    expect(
      setup.contains('StartCapture()'),
      isFalse,
      reason: '持 frame_mutex_ 开会话，首帧回调带着设备锁来拿 frame_mutex_',
    );
    final String threadMain = methodBody(capture, 'void ThreadMain() {');
    final int setupAt = threadMain.indexOf('error = SetupCaptureLocked();');
    final int startAt = threadMain.indexOf('error = StartCaptureSession();');
    expect(setupAt, isNonNegative);
    expect(startAt, isNonNegative);
    final String between = threadMain.substring(setupAt, startAt);
    expect(
      between.contains('}'),
      isTrue,
      reason: 'StartCaptureSession 必须在 frame_mutex_ 作用域闭合之后',
    );
  });
}
