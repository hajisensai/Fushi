/// 制卡后自动按词频重排的**接线层**：一个纯委派的 Anki 仓库包装，只在
/// [mineEntry] 成功后多做一件事——把落卡牌组喂给 [AnkiAutoRepositionScheduler]。
///
/// 为什么包在仓库层而不是在制卡调用点加钩子：制卡入口有 12 处（查词弹窗、
/// 阅读器、视频、漫画、PDF、悬浮词典、浏览器扩展桥、互联转发……），它们都读同一个
/// `ankiRepositoryProvider`。包一层等于零调用点改动，也不会有人新加第 13 个入口
/// 时忘了接钩子。同样的手法见 `RemoteMiningAnkiRepository`。
///
/// **与 RemoteMining 的关键区别**：那一层是**有意**只改道一部分方法（配置类仍走
/// 本地）；本层的语义是「行为与 [inner] 完全一致，只是多一个副作用」，所以凡是
/// 后端会覆盖的成员都必须逐个委派。漏掉一个就会掉回 [BaseAnkiRepository] 的降级
/// 默认（例如 `supportsNoteTypeEditing` 变 false、`noteFields` 恒返回 null），而且
/// **不会报错**——只会表现为「开了自动重排以后某个功能莫名其妙不工作了」。
/// 委派清单只写一次，在 [DelegatingAnkiRepository]；守卫测试
/// `fushi/test/anki/auto_reposition_repository_delegation_test.dart` 钉死那份清单。
library;

import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/anki/anki_auto_reposition.dart';
import 'package:fushi/src/anki/delegating_anki_repository.dart';

/// 包装 [inner]，制卡成功后触发自动重排。
class AutoRepositionAnkiRepository extends DelegatingAnkiRepository {
  AutoRepositionAnkiRepository({
    required super.inner,
    required AnkiAutoRepositionScheduler scheduler,
  }) : _scheduler = scheduler;

  final AnkiAutoRepositionScheduler _scheduler;

  // --- 唯一一处有额外行为的方法 ---------------------------------------------

  /// 制卡成功后把**后端实际落卡**的牌组名喂给调度器。
  ///
  /// 三个前置判据都在这里挡掉，让调度器不必知道仓库：
  /// * 结果必须是成功——失败/重复/未配置都没有新卡产生。
  /// * [MineOutcome.deckName] 必须非空——它才是真正落卡的牌组（BUG-1549）；
  ///   拿设置里的 `selectedDeckName` 猜会在旧存档上猜空。
  /// * [inner] 必须支持卡片级读写——AnkiDroid / AnkiMobile / 「制卡到已配对
  ///   设备」都没有，喂进去只会让调度器空跑一轮。
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final MineOutcome outcome = await inner.mineEntry(
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
    final String? deck = outcome.deckName;
    if (outcome.result == MineResult.success &&
        deck != null &&
        deck.isNotEmpty &&
        inner.supportsDeckReposition) {
      _scheduler.notifyMined(deck);
    }
    return outcome;
  }
}
