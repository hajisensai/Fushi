// BUG-2091：被抢占的旧轮次不得撤回 attached provider 认领。
//
// `_attachedProviderClaimed` 是**跨轮次共享的单一状态**，而注入侧 registry 是在自己的
// 轮询里 `Reconcile` 才把 kind=4/id=11 判成 ready 的。旧实现里 `_claimAttachedProvider`
// 在发现自己被抢占（`stillCurrent()` 为假）时会顺手 `_setAttachedProviderClaim(false)`
// ——撤掉的却是**新轮次刚发出的**那份认领。registry 下一拍看到 attachedReady=false，
// 于是永远不授予；而宿主又在等这个 ready 才肯进 activeAttached，两边互等成活锁，状态
// 永久停在 geometryProviderPending。
//
// 真机 WoH 复现（hibiki_glookup.log）：
//   attachedReady=true   request=3 applied=2
//   attachedReady=false  request=4 applied=3   ← 40ms 后被旧轮次撤回
//
// 这条不是 HUNEX 专有：attached 是所有引擎共用的兜底路径。系统级时序在 Dart 测试里
// 造不出来，这里锁住可自动证明的最强结构：被抢占分支里不得出现撤回调用。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  test('BUG-2091 被抢占的认领轮次不得撤回 attached provider 认领', () {
    final File source = File(
      'lib/src/lookup/gal_attached_text_controller.dart',
    );
    expect(source.existsSync(), isTrue, reason: '控制器源码必须存在');
    final String body = maskComments(source.readAsStringSync());

    final int claimAt = body.indexOf('_claimAttachedProvider(');
    expect(claimAt, greaterThan(0), reason: '找不到 _claimAttachedProvider');
    // 取函数定义处（带 async 体）而不是调用点。
    final int defAt = body.indexOf('}) async {', claimAt);
    expect(defAt, greaterThan(0), reason: '找不到 _claimAttachedProvider 定义体');
    final int endAt = body.indexOf(
      'void _setAttachedProviderClaim(',
      defAt,
    );
    expect(endAt, greaterThan(defAt), reason: '找不到认领函数的结束边界');
    final String claimBody = body.substring(defAt, endAt);

    // 被抢占分支：`if (stillCurrent != null && !stillCurrent()) { ... }`
    final int supersededAt =
        claimBody.indexOf('if (stillCurrent != null && !stillCurrent()) {');
    expect(
      supersededAt,
      greaterThan(0),
      reason: '找不到被抢占分支；本守卫的锚点失效了，请按行为重新推导',
    );
    final int supersededEnd = claimBody.indexOf('}', supersededAt);
    expect(supersededEnd, greaterThan(supersededAt));
    final String supersededBranch =
        claimBody.substring(supersededAt, supersededEnd);

    expect(
      supersededBranch.contains('_setAttachedProviderClaim(false)'),
      isFalse,
      reason: '被抢占的旧轮次撤回认领会撤掉新轮次刚发出的那份，'
          '让注入侧 registry 永远授不出 attached provider（活锁）',
    );

    // 正向：认领本身仍必须发出，否则 registry 永远没有可授予的对象。
    expect(
      claimBody.contains('_setAttachedProviderClaim(true'),
      isTrue,
      reason: '认领必须真的发出',
    );
  });
}
