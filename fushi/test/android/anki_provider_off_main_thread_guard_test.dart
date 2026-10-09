import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2967 source-scan guard：AnkiDroid ContentProvider 查询不得跑在 Android 主线程。
///
/// 查词弹窗渲染后会逐条探测「这个词是否已制卡」（`duplicateCheck` →
/// `AnkiRepository.isDuplicate` → `checkForDuplicates`）。AnkiDroid 后台进程被系统
/// 回收后（空闲约十分钟后真机实测已被回收），这趟跨进程查询要先把 AnkiDroid 整个冷
/// 启动；原先它在主线程执行，Hybrid Composition 下 Flutter raster 与 WebView 都绑在
/// 主线程，于是整个界面连同刚翻出的弹窗一起冻住（真机 `Choreographer: Skipped 32
/// frames`）——这就是「空闲一阵后第一次查词要等很久、一直查就没事」。
///
/// 真机线程模型在这里跑不了，故守**分发机制**：channel 只注册 `dispatch`，除白名单
/// 外一律进后台执行器，结果经 `MainThreadResult` 回投；`handleCall` 内不得再把
/// provider 查询 post 回主线程（旧写法 `new Handler(Looper.getMainLooper()).post`）。
void main() {
  // Tests run with CWD = `fushi/`.
  const String path =
      'android/app/src/main/java/app/fushi/reader/AnkiChannelHandler.java';
  late String src;
  setUpAll(() => src = maskComments(File(path).readAsStringSync()));

  String methodBody(String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThan(0), reason: 'missing $signature');
    int depth = 0;
    for (int i = src.indexOf('{', start); i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) return src.substring(start, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  test(
    'channel registers the dispatcher, not an inline main-thread lambda',
    () {
      expect(
        src,
        contains(
          '.setMethodCallHandler((call, rawResult) -> '
          'dispatch(call, rawResult, result ->',
        ),
      );
      expect(src, isNot(contains('setMethodCallHandler((call, result)')));
    },
  );

  test('dispatch sends non-whitelisted methods to the provider executor', () {
    final String body = methodBody('private void dispatch(');
    expect(body, contains('runsOnMainThread(call.method)'));
    expect(body, contains('Consumer<MethodChannel.Result> handleCall'));
    expect(body, contains('PROVIDER_IO.execute('));
    expect(body, contains('new MainThreadResult(result)'));
    // 后台线程上未捕获的异常会杀进程，且 Dart Future 必须完成。
    expect(body, contains('catch (Throwable'));
  });

  test(
    'provider executor is single-threaded (FIFO between provider calls)',
    () {
      expect(src, contains('Executors.newSingleThreadExecutor('));
    },
  );

  test('only Activity / in-process methods stay on the main thread', () {
    final String body = methodBody('static boolean runsOnMainThread(');
    final Set<String> mainOnly = RegExp(
      r'case "(\w+)":',
    ).allMatches(body).map((Match m) => m.group(1)!).toSet();
    expect(mainOnly, <String>{
      'requestAnkidroidPermissions',
      'hasAnkidroidPermission',
      'openAnkiPermissionSettings',
      'openNote',
    });
    // 查词路径上的两条制卡态探测绝不能回到主线程白名单。
    expect(mainOnly, isNot(contains('checkForDuplicates')));
    expect(mainOnly, isNot(contains('findNotesByContent')));
  });

  test('method switch never re-posts provider work onto the main looper', () {
    final String body = methodBody('public void register(');
    expect(body, contains('case "checkForDuplicates":'));
    expect(body, contains('case "findNotesByContent":'));
    expect(body, isNot(contains('Looper.getMainLooper()')));
  });

  test('MainThreadResult replies on the main looper exactly once', () {
    final String body = methodBody('static final class MainThreadResult');
    expect(body, contains('implements MethodChannel.Result'));
    expect(body, contains('Looper.getMainLooper()'));
    expect(body, contains('replied.compareAndSet(false, true)'));
  });
}
