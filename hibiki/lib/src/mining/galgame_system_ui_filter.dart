/// galgame 文本 hook 的「系统 UI 文字 vs 真台词」启发式过滤器。
///
/// 原先内嵌在 [GalgameSessionController]（旧的单页会话实现）里，但真正落地的
/// 文本 poll 路径已迁到 [GalHookSessionController]。抽成共享独立文件，使活代码的
/// poll 路径能接上同一份真机实证过的过滤逻辑（否则读/存档菜单文字会漏进查词面板）。
library;

/// 文本 hook 抓到的一行是否是「系统 UI 文字」（读/存档界面标题、存档槽列表、时间戳），而非台词。
///
/// 真机实证（KiriKiri / Otomeki，`HIBIKI_LUNA_DIAG` 采样）：读/存档界面的载入确认句、存档槽号、
/// 存档时间戳与对话经**不同 LunaHook** 一并被抓；且在「先开菜单后进对话」的冷启动窗口里，菜单是
/// 当时唯一文本源，会被 injector 的 hook 赢家选择**误选为赢家**放行——所以 native 侧无法靠 hook
/// 区分兜住这个场景。故在喂进查词面板前，按这些**稳定且绝不与真台词重叠**的系统句式剔除。
///
/// 诚实标注：系统 UI 文字与台词无通用结构判据，本判定是**启发式**，只匹配已实证的系统串：
///   ① 载入/保存确认句「…のデータをロードします」「…をセーブします」（可能多槽拼接）；
///   ② 整行仅由存档元数据（槽号 `No.<n>` / 章节 `第N章` / 日期 `2025/01/19` / 时间 `21:58:14`）
///      拼成，去掉这些后无任何实义文字。
/// 真台词（含假名/汉字实义内容）不被误伤。
bool isGalgameSystemUiLine(String text) {
  final String s = text.trim();
  if (s.isEmpty) {
    return false;
  }
  // ① 读/存档确认句（KiriKiri 系统提示，绝不作台词出现）。
  if (RegExp(r'データを(ロード|セーブ)します').hasMatch(s)) {
    return true;
  }
  // ② 整行只由存档槽元数据构成：剥掉槽号 No.<n> / 章节 第<n>章（含全角数字）/ 日期时间数字标点
  //    后若为空 → 系统 UI（存档槽列表 / 时间戳）。只把「整行皆元数据」判为系统，含实义假名/汉字
  //    的真台词剥不空、不误伤。
  final String stripped = s.replaceAll(
    RegExp(r'No\.[0-9]+|第[0-9０-９]+章|[0-9０-９/:：\s]'),
    '',
  );
  if (stripped.isEmpty) {
    return true;
  }
  return false;
}
