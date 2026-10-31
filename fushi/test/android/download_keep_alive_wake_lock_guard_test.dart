import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 反馈 nLXqmvv5Fy source-scan guard：下载保活前台服务必须在前台期间持有
/// CPU / Wi-Fi 锁，且每条停止路径都放锁。
///
/// 前台服务只防进程被杀、不防 CPU 休眠：不持 PARTIAL_WAKE_LOCK 时息屏后 CPU
/// 挂起，主 isolate 里的下载循环停摆，亮屏才继续。锁的幂等逻辑由 JVM 单测
/// `android/app/src/test/kotlin/app/fushi/reader/DownloadKeepAliveLocksTest.kt`
/// 覆盖；服务生命周期（startForeground / stopSelf / onDestroy）在 flutter test
/// 里跑不了，故这里钉接线。
void main() {
  // Tests run with CWD = `fushi/`.
  const String servicePath =
      'android/app/src/main/java/app/fushi/reader/DownloadKeepAliveService.java';
  const String locksPath =
      'android/app/src/main/java/app/fushi/reader/DownloadKeepAliveLocks.java';
  late String service;
  late String locks;
  setUpAll(() {
    service = maskComments(File(servicePath).readAsStringSync());
    locks = maskComments(File(locksPath).readAsStringSync());
  });

  String methodBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThan(0), reason: 'missing $signature');
    int depth = 0;
    for (int i = src.indexOf('{', start); i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}' && --depth == 0) return src.substring(start, i + 1);
    }
    fail('unbalanced braces after $signature');
  }

  test('locks are PARTIAL_WAKE_LOCK + Wi-Fi, non reference-counted', () {
    expect(locks, contains('PowerManager.PARTIAL_WAKE_LOCK'));
    expect(locks, contains('createWifiLock('));
    expect(
      RegExp(r'setReferenceCounted\(false\)').allMatches(locks).length,
      2,
      reason: '重叠的停止路径必须一次放干净',
    );
  });

  test('locks are acquired only after entering the foreground', () {
    final String body = methodBody(service, 'public int onStartCommand(');
    final int foreground = body.indexOf('ServiceCompat.startForeground(');
    final int acquire = body.indexOf('mLocks.acquire()');
    expect(foreground, greaterThan(0));
    expect(
      acquire,
      greaterThan(foreground),
      reason: 'startForeground 被拒时直接 stopSelf，不能先拿锁',
    );
  });

  test('every stop path releases the locks', () {
    expect(
      methodBody(service, 'private void stopNow('),
      contains('releaseLocks()'),
    );
    expect(
      methodBody(service, 'public void onDestroy('),
      contains('releaseLocks()'),
    );
    expect(
      methodBody(service, 'public void onTimeout('),
      contains('stopNow()'),
      reason: 'Android 15 dataSync 超时经 stopNow 放锁',
    );
  });

  test('manifest declares WAKE_LOCK', () {
    expect(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
      contains('android.permission.WAKE_LOCK'),
    );
  });
}
