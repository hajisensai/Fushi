import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 源码守卫（BUG-815）：看门狗「重试」与在飞的首个初始化并发竞态 → 数据全空。
///
/// 根因数据流——`main()` 冷启动 `await appModel.initialise()`。慢冷启动（首启 / 慢
/// 存储 / 大库）下这个 init 只是**慢**、并未 hang，20s 后触发加载看门狗逃生 UI。用户
/// 点「重试」→ `retryInitialise()`。修复前它**无任何 in-flight 守卫**：`_databaseOpened`
/// 为真时直接 `await _database.close()` 关掉**首个 init 正在用的 DB**，再 `initialise()`
/// 起**第二个并发 init**。两个 init 抢同一批可变字段（`_database` / repositories /
/// `_isInitialised`），谁先 `notifyListeners()` 就用谁半加载的 repo → 主页渲染空数据。
/// 重启（单次干净 init）即恢复，证明数据没真丢，是并发初始化打烂了可见状态。
///
/// 修复——两道结构不变量，让「并发双 init」根本不可能：
///   1. 公开 `initialise()` 改为**带 in-flight 守卫的同步包装**：已有 run 在飞时复用同
///      一 future，绝不起第二个；真正的一次性 init 体搬到 `_initialiseOnce()`。
///   2. `retryInitialise()` 在 `_database.close()` 教条式拆卸**之前**先检查 `_initInFlight`
///      并 `return`：init 在飞 = 慢启动而非 hang，await 它即可（成功出数据 / 失败落
///      `_initError`，其自身 Retry 那时 `_initInFlight` 已清可干净重起），绝不关它在用的 DB。
///
/// 这段 ~2900 行的初始化序列无法在 host 单测里真实驱动（要打开真 DB、注册全部媒体源、
/// 跑搜索预热、平台通道等），故沿用 BUG-207 的源码扫描守卫范式钉住上述结构不被回退。
/// 配套 widget 测试 test/startup/loading_watchdog_view_test.dart 覆盖移动端文案分支。
void main() {
  final String src = File('lib/src/models/app_model.dart').readAsStringSync();

  test(
    '公开 initialise() 是带 in-flight 守卫的包装，init 体在 _initialiseOnce() (BUG-815)',
    () {
      // 公开入口必须是同步返回的守卫包装（`Future<void> initialise() {`，非 async），
      // 而不是直接把 ~2900 行 init 体挂在 initialise() 上（那样无法串行化并发调用）。
      final int wrapIdx = src.indexOf('Future<void> initialise() {');
      expect(
        wrapIdx,
        greaterThanOrEqualTo(0),
        reason:
            'initialise() 必须是带 in-flight 守卫的同步包装（Future<void> initialise() {）——'
            '被改回 `initialise() async { try {…}` 会失去串行化，重试可再起并发 init。',
      );

      // 真正的一次性 init 体搬到 _initialiseOnce()。
      final int onceIdx = src.indexOf('Future<void> _initialiseOnce() async {');
      expect(
        onceIdx,
        greaterThan(wrapIdx),
        reason: 'init 体必须在 _initialiseOnce() 内，由 initialise() 经守卫调用。',
      );

      // 守卫包装体必须引用 _initInFlight（复用在飞 run 的证据）。
      final String wrapperBody = maskCommentsAndStrings(
        methodBody(src, 'Future<void> initialise()'),
      );
      expect(
        wrapperBody.contains('_initInFlight'),
        isTrue,
        reason: 'initialise() 包装必须用 _initInFlight 串行化并发调用（复用在飞 future）。',
      );
    },
  );

  test('retryInitialise() 在 _database.close() 之前先短路在飞 init (BUG-815)', () {
    // 由真实方法体的配对括号决定窗口；新增 flush / 错误处理不能把 close 挤出固定
    // 字符范围。掩掉注释和字符串，避免说明文字替代实际的控制流通过守卫。
    final String retryRegion = maskCommentsAndStrings(
      methodBody(src, 'Future<void> retryInitialise()'),
    );
    final int inFlightReadIdx = retryRegion.indexOf(
      'final Future<void>? inFlight = _initInFlight;',
    );
    final RegExpMatch? inFlightCheck = RegExp(
      r'if\s*\(\s*inFlight\s*!=\s*null\s*\)\s*\{',
    ).firstMatch(retryRegion);
    expect(
      inFlightReadIdx,
      greaterThanOrEqualTo(0),
      reason: 'retryInitialise() 必须读取当前在飞的初始化 Future。',
    );
    expect(
      inFlightCheck,
      isNotNull,
      reason: 'retryInitialise() 必须先检查 _initInFlight（在飞 init 短路）。',
    );
    final int inFlightCheckIdx = inFlightCheck!.start;
    final int closeIdx = retryRegion.indexOf('_database.close()');

    expect(inFlightCheckIdx, greaterThan(inFlightReadIdx));
    expect(
      closeIdx,
      greaterThanOrEqualTo(0),
      reason: 'retryInitialise() 仍应保留 error 后的干净重起（_database.close()）。',
    );

    // 关键不变量：in-flight 检查必须早于 _database.close()。否则慢启动下重试会关掉
    // 首个在飞 init 正在用的 DB，并起第二个并发 init → 数据全空（BUG-815 症状）。
    expect(
      inFlightCheckIdx < closeIdx,
      isTrue,
      reason:
          'BUG-815 回归：retryInitialise() 在 _database.close() 之前必须先短路在飞 init，'
          '否则会关掉在飞 init 正在用的 DB → 并发双初始化 → 主页数据全空。',
    );

    // 必须在 in-flight 分支里 await 后直接 return；flush 失败分支里的 return
    // 不能冒充这个短路，否则删掉在飞守卫的 return 仍会假绿。
    final String inFlightBranch = balancedBlockFrom(
      retryRegion,
      inFlightCheckIdx,
      what: 'retryInitialise in-flight 分支',
    );
    expect(
      RegExp(
        r'\{\s*await\s+inFlight\s*;\s*return\s*;\s*\}$',
      ).hasMatch(inFlightBranch),
      isTrue,
      reason: 'in-flight 分支必须 await 同一初始化后直接 return，不得进入拆卸路径。',
    );
    final int inFlightEnd = inFlightCheckIdx + inFlightBranch.length;
    expect(inFlightEnd, lessThan(closeIdx));
    final int flushIdx = retryRegion.indexOf(
      '_flushDictionaryWritesBeforeClose()',
    );
    expect(
      flushIdx,
      greaterThan(inFlightEnd),
      reason: '在飞 init 短路必须位于 flush 之前，不得先操作正在初始化的仓库。',
    );
  });
}
