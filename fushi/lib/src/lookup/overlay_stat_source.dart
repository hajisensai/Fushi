// app 外查词 / 制卡（瞬态浮窗 + 剪贴板面板）的**统计来源判据**与**跨源收藏写入**，
// 两个表面与两个值域共用这一份实现（与 overlay_bridge_handlers 同一条「绝不复制」
// 红线：判据一旦在调用点各写一遍，游戏域与阅读域就会在其中一处静默漂移）。
//
// 背景：这条链路不经任何页面，拿不到书 / 视频上下文，此前一律硬写
// `kStatSourceBook`——于是 galgame hook 会话里的查词 / 制卡 / 收藏词 / 收藏句
// 全堆进「阅读」tab，「游戏」tab 只剩游玩次数一行。
//
// 本文件刻意只依赖 fushi_core / fushi_audio / gal 会话控制器（不碰 AppModel、不碰
// widget），所以每条判据都能用内存 DB 直接测行为，而不是只能靠源码扫描守卫。

import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 纯判据（**唯一**真相源，两个包装器都委托它）：有归属的 galgame 会话 id 非空
/// → 游戏域，否则 → 书域。
///
/// 单独抽出来是为了可测：[GalHookSessionController.instance] 是 static final 单例，
/// 构造时会挂 TexthookerService / TexthookerWsClientManager 的监听，测试里不能替换
/// 也不该实例化；判据本身是纯函数，两态都能直接测。
bool _isGameSurface(String? activityGameKey) =>
    activityGameKey != null && activityGameKey.isNotEmpty;

/// 统计来源值域（`favorite_words` / `mining_statistics` /
/// `lookup_mining_counters` 的 `source_type`）下的判据；见 [overlayStatSourceType]。
String statSourceTypeForGameKey(String? activityGameKey) =>
    _isGameSurface(activityGameKey) ? kStatSourceGame : kStatSourceBook;

/// 收藏句 / 制卡句值域（`mined_sentences.source`、`FavoriteSentence.source`）下的
/// **同一个**判据。两个值域的 `'book'` / `'video'` / `'game'` 虽逐字节同值，但列的
/// 语义不同（那一列还有 audiobook / lyrics），故按列各取各的常量，不共用字面量。
String minedSentenceSourceForGameKey(String? activityGameKey) =>
    _isGameSurface(activityGameKey)
        ? kFavoriteSentenceSourceGame
        : kFavoriteSentenceSourceBook;

/// app 外查词 / 制卡的统计来源：有归属的 galgame 会话在跑时算游戏域，否则算书域。
///
/// 已知限制（如实记录，不是遗漏）：这是**会话级**判据，不是逐次查词的来源标记。
/// 游戏在跑期间用户切到浏览器 / PDF 里划词查，那次查词同样会记进游戏域。要精确到
/// 「这次查词的句子确实来自 hook」，得把来源标记从捕获侧一路穿过 overlay bridge
/// （C++ 浮窗 → popup.js → Dart handler）再落到每个写入点，成本与收益不成比例，
/// 暂不做。反过来，会话没在跑时绝不会误记游戏域（key 恒 null）。
String overlayStatSourceType() =>
    statSourceTypeForGameKey(GalHookSessionController.instance.activityGameKey);

/// [overlayStatSourceType] 的收藏句 / 制卡句值域版本（`addMinedSentence` 的
/// `source` 参数用它，那一列不是 `StatSourceKind` 值域）。
String overlayMinedSentenceSource() => minedSentenceSourceForGameKey(
      GalHookSessionController.instance.activityGameKey,
    );

/// app 外浮窗的收藏词读 / 切换（`favoriteCheck` / `favoriteEntry` 两个桥共用）。
/// 返回**切换后**的收藏态；[toggle] 为 false 时只读、不写。
///
/// `favorite_words` 的唯一键是 (expression, reading, sourceType)，所以同一个词在
/// book 源与 game 源是**两行**。★ 的可见行为必须与只有 book 源时逐字节一致，同时
/// 不产生重复计数——三条纪律：
///
///  ① **判**「已收藏」跨源：book 源或 game 源任一有行就算已收藏。否则「书里收藏过、
///     游戏里显示没收藏」，星标会随 hook 会话起停闪。
///  ② **删**跨源：取消收藏时把两个源里存在的都删掉。只删当前源会留下另一源的孤儿
///     行——★ 灭了，收藏夹里还在，统计还计着。
///  ③ **写**单源：新增只写 [addSourceType]（调用方传 [overlayStatSourceType] 的结果）。
///     两源各写一行才是真正的重复计数（收藏夹两条、两个统计域各 +1）。
Future<bool> overlayToggleOrCheckFavoriteWord({
  required FushiDatabase db,
  required bool toggle,
  required String expression,
  required String reading,
  required String addSourceType,
  required String dateKey,
}) async {
  // ① 跨源判定。
  final bool inBook = await db.isFavoriteWord(
    expression: expression,
    reading: reading,
    sourceType: kStatSourceBook,
  );
  final bool inGame = await db.isFavoriteWord(
    expression: expression,
    reading: reading,
    sourceType: kStatSourceGame,
  );
  final bool already = inBook || inGame;
  if (!toggle) {
    return already; // favoriteCheck: report the current state, no write.
  }
  if (already) {
    // ② 两源都清，绝不留孤儿行。
    if (inBook) {
      await db.removeFavoriteWord(
        expression: expression,
        reading: reading,
        sourceType: kStatSourceBook,
      );
    }
    if (inGame) {
      await db.removeFavoriteWord(
        expression: expression,
        reading: reading,
        sourceType: kStatSourceGame,
      );
    }
    return false;
  }
  // ③ 只写当前源。
  await db.addFavoriteWord(
    expression: expression,
    reading: reading,
    glossary: '',
    sourceType: addSourceType,
    dateKey: dateKey,
  );
  return true;
}
