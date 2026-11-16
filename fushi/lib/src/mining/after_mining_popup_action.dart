import 'package:fushi/src/models/module_id.dart';

/// 查词弹窗里一张卡被收下（成功 / 进后台 / 进待发队列）之后，弹窗与播放怎么处理。
///
/// 拍板台 8ldy3d8XFA（维护者 2026-11-16 拍 C）：此前是两个语义交叉的东西——阅读器偏好
/// 「制卡后关闭查词弹窗」（`close_popup_after_mining`，默认关）+ 视频页把它写死成 true
/// 再借「查词时暂停」的续播路径续播，设置界面的值和视频里的实际行为对不上。现在合成
/// 这一个单选，**按模块存**（模块 = 查词宿主的 `lookupHostModule`，与「底部停靠」按
/// 模块细分同一真值），视频默认 [closeAndResume]。
///
/// 续播只在这次查词确实暂停过播放（「查词时暂停」开着且当时在播）时发生，和手动关
/// 弹窗走同一条续播路径；[close] 关弹窗但先撤掉「因查词暂停」的标记、保持暂停。
enum AfterMiningPopupAction {
  /// 弹窗留着（各模块原先的默认）。
  keepOpen('keep'),

  /// 关掉整个查词弹窗栈，不续播。
  close('close'),

  /// 关掉整个查词弹窗栈；查词暂停过播放就续播。
  closeAndResume('close_resume');

  const AfterMiningPopupAction(this.wireName);

  /// 偏好持久化用的稳定字符串（勿随枚举名改动）。
  final String wireName;

  /// 是否关弹窗栈。
  bool get closesPopup => this != keepOpen;

  /// 关弹窗后是否按「因查词暂停」的标记续播。
  bool get resumesPlayback => this == closeAndResume;

  /// 严格解析：未知 / null → null（交给 [resolveAfterMiningPopupAction] 走默认）。
  static AfterMiningPopupAction? tryParse(String? raw) {
    for (final AfterMiningPopupAction action in AfterMiningPopupAction.values) {
      if (action.wireName == raw) return action;
    }
    return null;
  }
}

/// 一张卡被收下后按 [action] 处理弹窗：要关就先（不续播时）[dropPauseMark] 撤掉「因
/// 查词暂停」的标记，再 [closeAll] 关栈——续播与否交给关栈汇聚点按标记决定，与手动关
/// 弹窗同一条路径。宿主自己的弹窗栈（`closePopupAfterAcceptedMine`）与 app 外顶层查词
/// 窗口（网页视频窗口宿主档）都走这一个判据。
void applyAfterMiningPopupAction(
  AfterMiningPopupAction action, {
  required void Function() dropPauseMark,
  required void Function() closeAll,
}) {
  if (!action.closesPopup) return;
  if (!action.resumesPlayback) dropPauseMark();
  closeAll();
}

/// 有自己一行「制卡后行为」的模块，顺序 = 设置里的展示顺序。不属于其中任何一个的
/// 查词宿主（查词页 / 外部弹窗 / 悬浮球与截屏识字 / 复习卡等，宿主模块为 `null`）一律
/// 归 [ModuleId.lookup] 那一行。悬浮歌词查词宿主按请求来源归行（音乐桌面歌词 = 音乐，
/// 其余为查词），网页视频窗口宿主档的顶层查词窗口归视频。
const List<ModuleId> kAfterMiningPopupModules = <ModuleId>[
  ModuleId.books,
  ModuleId.manga,
  ModuleId.video,
  ModuleId.music,
  ModuleId.games,
  ModuleId.lookup,
];

/// 查词宿主所属模块 → 它听哪一行。
ModuleId afterMiningPopupModuleFor(ModuleId? hostModule) =>
    hostModule != null && kAfterMiningPopupModules.contains(hostModule)
    ? hostModule
    : ModuleId.lookup;

/// [module] 那一行的偏好键（阅读器 MediaSource 偏好通道，与旧键同一通道）。逐个写死，
/// 不用 `.name` 拼：枚举改名不能悄悄换键。不在 [kAfterMiningPopupModules] 里的模块
/// 先经 [afterMiningPopupModuleFor] 归行。
String afterMiningPopupPrefKey(ModuleId module) =>
    switch (afterMiningPopupModuleFor(module)) {
      ModuleId.books => 'after_mining_popup_books',
      ModuleId.manga => 'after_mining_popup_manga',
      ModuleId.video => 'after_mining_popup_video',
      ModuleId.music => 'after_mining_popup_music',
      ModuleId.games => 'after_mining_popup_games',
      _ => 'after_mining_popup_lookup',
    };

/// [module] 的宿主会不会因查词暂停播放：小说（有声书 / 音频书）、视频、音乐会；
/// 漫画、游戏（galgame 文本 hook）、查词页没有会被查词暂停的播放。
bool afterMiningPopupModuleHasPlayback(ModuleId module) =>
    switch (afterMiningPopupModuleFor(module)) {
      ModuleId.books || ModuleId.video || ModuleId.music => true,
      _ => false,
    };

/// [module] 在设置里可选的值。没有播放的模块「关闭并续播」与「关闭」一样，不给这一档
/// 免得误导。
List<AfterMiningPopupAction> afterMiningPopupOptions(ModuleId module) =>
    afterMiningPopupModuleHasPlayback(module)
    ? AfterMiningPopupAction.values
    : const <AfterMiningPopupAction>[
        AfterMiningPopupAction.keepOpen,
        AfterMiningPopupAction.close,
      ];

/// [module] 的出厂默认。视频 = [AfterMiningPopupAction.closeAndResume]（拍板台
/// 8ldy3d8XFA；也是视频页此前写死的实际行为）。其余模块承接旧全局开关
/// `close_popup_after_mining`：开过的人得到原本的行为——关栈后走关弹窗汇聚点，查词
/// 暂停过就续播（= [AfterMiningPopupAction.closeAndResume]；没有播放的模块落到
/// [AfterMiningPopupAction.close]）；没开过（旧默认）= [AfterMiningPopupAction.keepOpen]。
AfterMiningPopupAction afterMiningPopupDefault(
  ModuleId module, {
  required bool legacyCloseAfterMining,
}) {
  final ModuleId row = afterMiningPopupModuleFor(module);
  if (row == ModuleId.video) return AfterMiningPopupAction.closeAndResume;
  if (!legacyCloseAfterMining) return AfterMiningPopupAction.keepOpen;
  return afterMiningPopupModuleHasPlayback(row)
      ? AfterMiningPopupAction.closeAndResume
      : AfterMiningPopupAction.close;
}

/// 生效值：存过且在该模块的可选范围内就用存的，否则用 [afterMiningPopupDefault]。
AfterMiningPopupAction resolveAfterMiningPopupAction(
  ModuleId module, {
  required String? stored,
  required bool legacyCloseAfterMining,
}) {
  final AfterMiningPopupAction? parsed = AfterMiningPopupAction.tryParse(
    stored,
  );
  if (parsed != null && afterMiningPopupOptions(module).contains(parsed)) {
    return parsed;
  }
  return afterMiningPopupDefault(
    module,
    legacyCloseAfterMining: legacyCloseAfterMining,
  );
}
