import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：首页必须挂一个定时轮询把 app-open 全量同步周期性重跑，让「手机 / 电脑一直
/// 开着、另一端改了数据」这种没有任何事件触发的场景也能自动拉到远端改动（此前同步纯事件
/// 驱动——只在 app 打开 / 进入后台 / 关书时触发，设备静止不动就永远不同步，只能手动点
/// 「立即同步」）。
///
/// 不变式：
/// - 存在共用入口 `_triggerFullAutoSync()`，postFrame 首帧与定时器都走它（单一逻辑）。
/// - `Timer.periodic` 把该入口按 `_periodicSyncInterval` 周期触发。
/// - 轮询间隔 < `_runAutoSyncAll` 的 5 分钟冷却窗，否则 tick 卡在冷却下沿被跳过、有效周期
///   翻倍——此处固化「间隔 = 1 分钟」小于冷却。
/// - `dispose` 里 `_periodicSyncTimer?.cancel()`，避免页面销毁后 timer 泄漏。
///
/// headless widget 测试要拉起完整 AppModel 初始化 + fake time，成本高且脆；用接线守卫固化
/// 不变式防回归（对齐 home_resumed_focus_reclaim_static_test.dart 的风格）。
void main() {
  late String src;
  setUpAll(() {
    final File f = File('lib/src/pages/implementations/home_page.dart');
    expect(f.existsSync(), isTrue, reason: '文件不存在');
    src = f.readAsStringSync();
  });

  test('存在共用全量同步入口 _triggerFullAutoSync', () {
    expect(src, contains('void _triggerFullAutoSync()'),
        reason: 'postFrame 首帧与定时轮询应共用同一全量同步入口');
    expect(src, contains('triggerAutoSyncOnAppOpen('),
        reason: '入口应触发 app-open 语义的全量双向同步');
  });

  test('定时器把全量同步按 _periodicSyncInterval 周期触发', () {
    expect(src, contains('Timer? _periodicSyncTimer'),
        reason: '应持有可取消的周期同步 timer 字段');
    expect(
        src,
        contains(
            'Timer.periodic(_periodicSyncInterval, (_) => _triggerFullAutoSync())'),
        reason: '定时器必须周期性重跑共用全量同步入口');
  });

  test('轮询间隔小于 5 分钟冷却窗（避免卡冷却下沿被跳过、周期翻倍）', () {
    expect(
        src,
        contains(
            'static const Duration _periodicSyncInterval = Duration(minutes: 1)'),
        reason: '轮询间隔应显式为 1 分钟，小于 _runAutoSyncAll 的 5 分钟冷却窗；'
            '若取成恰等于冷却窗，tick 会落在冷却下沿被跳过，把有效周期翻倍成 10 分钟');
  });

  test('dispose 取消周期同步 timer（不泄漏）', () {
    final int start = src.indexOf('void dispose()');
    expect(start, greaterThanOrEqualTo(0));
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(body, contains('_periodicSyncTimer?.cancel()'),
        reason: 'dispose 必须取消周期同步 timer，避免页面销毁后回调仍触发');
  });
}
