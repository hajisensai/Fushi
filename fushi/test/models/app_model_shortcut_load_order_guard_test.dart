import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-207）：自定义快捷键重启后丢失 / 不生效。
///
/// 根因——冷启动 `AppModel.initialise()` 里 `loadShortcutRegistry(...)` 原本在那批
/// `source.initialise()` 的 `Future.wait` **之前**调用。`source.initialise()` 才会
/// 跑 `_loadPreferencesFromDb()` 把 DB 偏好装进内存缓存 `_preferences`；早于它调用
/// 时缓存为空，`getPreference<String?>('shortcut_bindings_json')` 返回 null →
/// `loadShortcutRegistry` 走 `resetToDefaults`，用户已存的自定义键本会话整段失效，
/// 之后任意改键 `saveShortcutRegistry` 又用默认基底整体覆盖掉持久化 JSON。
///
/// 修复——把冷启动里第一处 `loadShortcutRegistry(` 移到那批 `source.initialise()`
/// 的 `Future.wait` **之后**（与 profile 切换路径「先 refresh 缓存再 load」对称）。
///
/// 这段 ~2900 行的初始化序列无法在 host 单测里真实驱动（要打开真 DB、注册全部媒体
/// 源、跑搜索预热等），故用源码扫描守卫钉住调用顺序不被回退。撤修复（把第一处
/// loadShortcutRegistry 移回 source.initialise() 那批 wait 之前）→ offset 比较翻转
/// → 本守卫红。配套行为测试 test/shortcuts/shortcut_load_order_test.dart 证明「缓存
/// 未装载时调用 loadShortcutRegistry 会丢自定义键」这条根因数据流成立。
void main() {
  test(
      'cold-start loadShortcutRegistry runs AFTER source.initialise() hydrates '
      'the preference cache (BUG-207)', () {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();

    // 锚点 1：那批 source 初始化里的 `source.initialise()` 调用（缓存装载发生处）。
    final int sourceInitIdx = src.indexOf('source.initialise()');
    expect(
      sourceInitIdx,
      greaterThanOrEqualTo(0),
      reason: '找不到 source.initialise() —— 媒体源初始化批被改名/移除了？',
    );

    // 锚点 2：第一处 `loadShortcutRegistry(`（冷启动路径；第二处是 profile 切换）。
    final int firstLoadIdx = src.indexOf('loadShortcutRegistry(');
    expect(
      firstLoadIdx,
      greaterThanOrEqualTo(0),
      reason: '找不到 loadShortcutRegistry( —— 启动里加载快捷键注册表的调用被删了？',
    );

    // 根因守卫：冷启动里 loadShortcutRegistry 必须晚于 source.initialise()，
    // 否则它在偏好缓存装载前读 shortcut_bindings_json，拿到 null 退回默认而丢键。
    expect(
      firstLoadIdx > sourceInitIdx,
      isTrue,
      reason: 'BUG-207 回归：loadShortcutRegistry( 出现在 source.initialise() 之前 —— '
          '快捷键注册表会在 source 偏好缓存装载前加载，读不到已存自定义键而退回默认。'
          '把该调用移到那批 source.initialise() 的 Future.wait 之后。',
    );

    // 加固：确认 source.initialise() 确实被 `await Future.wait(` 包裹（不是裸调
    // 用），否则上面的 offset 比较失去「缓存已装载」的语义保证。截取到第一处
    // loadShortcutRegistry 之前的片段里，source.initialise() 必须落在一段
    // `await Future.wait(` 内。
    final String beforeLoad = src.substring(0, firstLoadIdx);
    final int lastFutureWaitIdx = beforeLoad.lastIndexOf('await Future.wait(');
    expect(
      lastFutureWaitIdx >= 0 && lastFutureWaitIdx < sourceInitIdx,
      isTrue,
      reason: 'source.initialise() 必须在一段 await Future.wait(...) 内被等待，'
          '才能保证 loadShortcutRegistry 运行前偏好缓存已装载完成',
    );
  });
}
