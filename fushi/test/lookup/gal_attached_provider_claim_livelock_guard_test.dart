// BUG-2142：被抢占的旧轮次不得撤回 attached provider 认领。
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
//
// **锚点纪律**（本守卫此前栽在这上面）：
//   · `indexOf('_claimAttachedProvider(')` 命中的是**调用点**（:692），不是定义
//     （:1919）；随后 `indexOf('}) async {')` 又落到另一个函数的参数表收口上，
//     切出来的"函数体"横跨十几个函数，正向断言被无关函数满足——把真正的认领整行
//     删掉守卫照样绿。
//   · 所以一律走 helper：`methodBody` 找不到签名会 fail（不静默漂），
//     `balancedBlockFrom` 按花括号配对取分支（不会被第一个嵌套 `}` 截断）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  late String claimBody;

  setUpAll(() {
    final File source = File(
      'lib/src/lookup/gal_attached_text_controller.dart',
    );
    expect(source.existsSync(), isTrue, reason: '控制器源码必须存在');
    claimBody = methodBody(
      source.readAsStringSync(),
      'Future<bool> _claimAttachedProvider(',
    );
  });

  test('切出来的确实只是这一个函数（锚点自检）', () {
    // 没有这条，锚点一旦漂开就会切出半个文件，而下面两条断言照样能被无关代码满足。
    expect(
      claimBody.contains('Future<bool> _claimAttachedProvider('),
      isTrue,
      reason: 'methodBody 应当把签名一起带出来',
    );
    expect(
      '_setAttachedProviderClaim('.allMatches(claimBody).length,
      lessThan(6),
      reason: '本函数里只该有个位数的认领调用；数量爆掉说明切面横跨了别的函数'
          '（整个控制器里有十几处），此时下面的断言都是假覆盖',
    );
    expect(
      claimBody.contains('void _setAttachedProviderClaim('),
      isFalse,
      reason: '切面不该把 _setAttachedProviderClaim 的定义也吞进来',
    );
  });

  test('BUG-2142 被抢占的认领轮次不得撤回 attached provider 认领', () {
    const String supersededHead =
        'if (stillCurrent != null && !stillCurrent()) {';
    final int supersededAt = claimBody.indexOf(supersededHead);
    expect(
      supersededAt,
      greaterThanOrEqualTo(0),
      reason: '找不到被抢占分支；本守卫的锚点失效了，请按行为重新推导',
    );
    // 按花括号配对取整个分支体——旧实现用 `indexOf('}')` 取，第一个嵌套右括号就截断了，
    // 撤回调用只要藏在任何一层嵌套里就查不到。
    final String supersededBranch = balancedBlockFrom(
      claimBody,
      supersededAt,
      what: '被抢占分支',
    );

    expect(
      supersededBranch.contains('_setAttachedProviderClaim(false)'),
      isFalse,
      reason: '被抢占的旧轮次撤回认领会撤掉新轮次刚发出的那份，'
          '让注入侧 registry 永远授不出 attached provider（活锁）',
    );
  });

  test('认领本身仍必须发出', () {
    expect(
      claimBody.contains('_setAttachedProviderClaim(true'),
      isTrue,
      reason: '认领必须真的发出，否则 registry 永远没有可授予的对象',
    );
  });
}
