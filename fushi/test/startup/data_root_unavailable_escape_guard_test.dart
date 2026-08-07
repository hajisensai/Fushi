import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-815）：桌面「数据位置未响应」逃生屏 + 显式用默认位置启动的接线不被回退。
///
/// 根因见 `test/storage/app_paths_data_root_timeout_test.dart`（配置根不可达 → resolve() 抛
/// [DataRootUnavailableException]，不静默开空默认库）。本守卫钉住其 UI/状态接线：
///   - `main.dart` 在**裸 loading 分支之前**渲染 dataRootUnavailable 逃生屏，且同时接
///     「重试」(`retryInitialise`) 和「仍用默认位置启动」(`retryInitialiseWithDefaultRoot`)。
///   - `app_model.dart` 的 `retryInitialiseWithDefaultRoot` 置
///     `AppPaths.forceDefaultRootForSession=true` 后再 retry；catch 到
///     `DataRootUnavailableException` 只置 `_dataRootUnavailable`（不设 `_initError`，
///     否则通用错误屏会盖住逃生屏）。
///
/// 这些是根 widget build() + init 序列的 UI/状态接线，无法在 host 单测真实驱动（要 pump 整个
/// App / 打开真 DB），故用源码扫描守卫，与 `app_model_init_retry_race_guard_test.dart` 同范式。
void main() {
  String read(String rel) {
    final File? f = <String>[rel, 'fushi/$rel']
        .map(File.new)
        .cast<File?>()
        .firstWhere((File? f) => f != null && f.existsSync(),
            orElse: () => null);
    expect(f, isNotNull, reason: '$rel not found');
    return f!.readAsStringSync();
  }

  test('main.dart：dataRootUnavailable 逃生屏在裸 loading 分支之前，且接双按钮 (BUG-815)', () {
    final String src = read('lib/main.dart');

    final int escapeIdx = src.indexOf('appModel.dataRootUnavailable');
    expect(escapeIdx, greaterThanOrEqualTo(0),
        reason: 'main.dart 必须检查 appModel.dataRootUnavailable 显逃生屏');

    // 裸 loading 分支（!appModel.isInitialised）。逃生屏必须在它之前，否则慢启动会先落到
    // loading/空态而看不到逃生屏。
    final int loadingIdx = src.indexOf('if (!appModel.isInitialised)');
    expect(loadingIdx, greaterThan(escapeIdx),
        reason: 'dataRootUnavailable 逃生屏必须在裸 loading 分支之前渲染');

    // 逃生屏窗口内必须同时接「重试」与「用默认位置启动」两个动作。
    final String region = src.substring(
        escapeIdx, loadingIdx < src.length ? loadingIdx : src.length);
    expect(region.contains('retryInitialise()'), isTrue,
        reason: '逃生屏必须有「重试」→ retryInitialise()');
    expect(region.contains('retryInitialiseWithDefaultRoot()'), isTrue,
        reason: '逃生屏必须有「仍用默认位置启动」→ retryInitialiseWithDefaultRoot()');
  });

  test(
      'app_model.dart：retryInitialiseWithDefaultRoot 置 force 开关；catch 只设 _dataRootUnavailable (BUG-815)',
      () {
    final String src = read('lib/src/models/app_model.dart');

    // 显式用默认根重试：必须置 AppPaths.forceDefaultRootForSession = true。
    final int mIdx =
        src.indexOf('Future<void> retryInitialiseWithDefaultRoot() async {');
    expect(mIdx, greaterThanOrEqualTo(0),
        reason: '缺 retryInitialiseWithDefaultRoot —— 显式默认根逃生口被删？');
    final String mBody = src.substring(mIdx, mIdx + 400);
    expect(mBody.contains('AppPaths.forceDefaultRootForSession = true'), isTrue,
        reason:
            'retryInitialiseWithDefaultRoot 必须置 forceDefaultRootForSession=true');

    // catch 子句：DataRootUnavailableException → 只设 _dataRootUnavailable。
    final int cIdx = src.indexOf('on DataRootUnavailableException catch');
    expect(cIdx, greaterThanOrEqualTo(0),
        reason: 'initialise 必须 catch DataRootUnavailableException 走逃生屏');
    // 仅限定到**本 catch 块**（下一个 `} on ` 之前），否则会越界读到相邻 downgrade
    // catch 里的 `_initError = '$e'` 造成误判。
    final int cEnd = src.indexOf('} on ', cIdx + 10);
    final String cBody = src.substring(cIdx, cEnd > cIdx ? cEnd : cIdx + 600);
    expect(cBody.contains('_dataRootUnavailable = e'), isTrue,
        reason: 'catch 必须置 _dataRootUnavailable = e');
    expect(cBody.contains('_initError = '), isFalse,
        reason: 'catch 不得设 _initError，否则通用错误屏会盖住数据位置逃生屏');
  });
}
