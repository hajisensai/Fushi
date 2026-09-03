import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2097 回归守卫：推荐包下载**不得**再由新手引导页持有。
///
/// 根因形态是结构性的，不是某一行文案：下载器、进度 notifier 和 `CancelToken`
/// 曾是 `_OnboardingWizardPageState` 的字段，而它的 `dispose()` 里有一句
/// `_packCancelToken?.cancel()`。于是「点下载 → 走下一步 → 走完向导」这条最普通
/// 的路径上，向导一 pop 就把 9.5 GB 的下载静默掐断，用户既没被告知、也没有任何
/// 地方还能看到它。所以这里守三件事：
/// 1. 向导页自己不再持有取消令牌/下载器（否则「后台下载」随时可能被 dispose 掐断）；
/// 2. 任务的所有权在 `AppModel` 上的 controller 里；
/// 3. 存在一个**不依赖向导**的可见入口（设置 → 系统那一行），否则「在后台跑」
///    等于没跑。
void main() {
  String read(String relativePath) =>
      maskCommentsAndStrings(File(relativePath).readAsStringSync());

  const String wizardPath =
      'lib/src/pages/implementations/onboarding_wizard_page.dart';
  const String appModelPath = 'lib/src/models/app_model.dart';
  const String systemSchemaPath =
      'lib/src/settings/settings_schema_system.dart';
  const String detailPagePath = 'lib/src/settings/settings_detail_page.dart';

  test('新手引导页不再持有推荐包下载的取消令牌与下载器', () {
    final String code = read(wizardPath);
    expect(
      code.contains('CancelToken'),
      isFalse,
      reason:
          '向导页一旦自己拿着取消令牌，它的 dispose 就能把后台下载掐断'
          '——BUG-2097 的根因就是这个形状',
    );
    expect(
      code.contains('RecommendedPackDownloader('),
      isFalse,
      reason: '下载器实例必须由 app 级 controller 持有，页面只是视图',
    );
    expect(
      code.contains('_packController.start('),
      isTrue,
      reason: '下载入口必须走 app 级 controller，页面不再自己发起',
    );
  });

  test('推荐包下载任务的所有权挂在 AppModel 上', () {
    final String code = read(appModelPath);
    expect(
      code.contains('RecommendedPackDownloadController('),
      isTrue,
      reason: '任务生命周期必须与 app 一致，不能与某个页面的 State 同生共死',
    );
    expect(
      code.contains('recommendedPackDownloadController.dispose()'),
      isTrue,
      reason: 'app 级 controller 必须在 AppModel.dispose 里收口',
    );
  });

  test('存在一个不依赖新手引导的进度入口，且随阶段实时显隐', () {
    final String schema = read(systemSchemaPath);
    expect(
      schema.contains('RecommendedPackDownloadRow('),
      isTrue,
      reason: '「在后台下载」如果没有任何地方看得到，等于没在下载',
    );
    expect(
      schema.contains('recommendedPackDownloadController'),
      isTrue,
      reason: '设置里那一行必须读同一个 app 级 controller，不能自建状态',
    );
    final String detail = read(detailPagePath);
    expect(
      detail.contains('recommendedPackDownloadController.stage.addListener'),
      isTrue,
      reason: '下载阶段是异步事件，不订阅它那一行就停在进页面那一刻的旧状态',
    );
    expect(
      detail.contains('recommendedPackDownloadController.stage.removeListener'),
      isTrue,
      reason: '订阅必须在 dispose 里摘掉，否则页面走了还在拉活它',
    );
  });
}
