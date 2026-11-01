import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart'
    show kStatSourceBook, kStatSourceMusic, kStatSourceVideo;
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/anki_mined_card_action_sheet.dart';
import 'package:fushi/src/diagnostics/lookup_perf_trace.dart';
import 'package:fushi/src/floating_ball/screen_ocr_card_image.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/media/favorites/favorite_lookup_context.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart'
    show SentenceContextSlot;
import 'package:fushi/src/pages/base_source_page.dart'
    show lookupHighlightCharCount;
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show
        MinePopupResult,
        DictionaryPopupWebViewState,
        QueuedOverwriteReply,
        closePopupAfterAcceptedMine;
import 'package:fushi/src/anki/advanced_mining_deck_section.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_dialog.dart';
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/utils/components/fushi_deferred_loading.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart';
import 'package:fushi/src/utils/misc/lookup_auto_read_coordinator.dart';
import 'package:fushi/utils.dart';

// 弹窗条目统一为共享的 [DictionaryPopupEntry]（见 dictionary_popup_controller.dart）；
// 旧的 NestedPopupEntry / _PopupStackItem 两份重复类型已收口为它一个。

/// 搜索期加载占位卡（[DictionaryPageMixin.buildPopupLoadingPlaceholder]）在宿主 Stack
/// 里的稳定身份 key。与 reader 车道 `base-source-popup-loading-placeholder` 同用途，
/// 也是 BUG-1364 行为测试定位该层的锚点。
const ValueKey<String> kLookupSearchPlaceholderKey = ValueKey<String>(
  'mixin-popup-loading-placeholder',
);

/// Non-generic mixin that consolidates the popup stack management, Anki mining,
/// and audio auto-read logic shared across PopupDictionaryPage
/// and HomeDictionaryPage.
///
/// No `on` constraint is used so it can be applied to all three state classes
/// regardless of their different base class hierarchies.
mixin DictionaryPageMixin {
  // ---------------------------------------------------------------------------
  // Abstract members — satisfied by State / ConsumerState superclass
  // ---------------------------------------------------------------------------

  WidgetRef get ref;
  bool get mounted;
  BuildContext get context;
  void setState(VoidCallback fn);

  // ---------------------------------------------------------------------------
  // Abstract members — subclass must provide explicitly
  // ---------------------------------------------------------------------------

  /// The AppModel instance. Each page accesses it differently, so the subclass
  /// exposes it through this getter.
  AppModel get mixinAppModel;

  /// The active ThemeData. Used to determine dark/light mode for popups.
  ThemeData get mixinTheme;

  /// 收藏/制卡计入统计时的来源标识。默认 [kStatSourceBook]（书内阅读、独立查词页
  /// 都归书籍统计）；视频页覆写为 [kStatSourceVideo]，使收藏/制卡落各自统计。
  String get dictionarySourceType => kStatSourceBook;

  /// 诊断流水里标记查词来源的宿主名（2026-09-22）。默认取 [dictionarySourceType]——
  /// 它已经区分了书 / 视频，而这正是排查「视频页查词卡」时唯一要分的两类。宿主想更
  /// 细分（首页词典 tab、悬浮歌词）可覆写；纯标签，不参与任何判决。
  String get lookupDiagHost => dictionarySourceType;

  /// 本页所属的媒体模块，决定「底部停靠」按模块细分开关听哪一个
  /// （[AppModel.popupBottomDockedFor]）。默认 `null` = 只听总开关（查词页 /
  /// 外部弹窗 / 悬浮歌词）；视频页、texthooker 覆写。与 `BaseSourcePageState`
  /// 的同名钩子对称。
  ModuleId? get popupDockModule => null;

  /// 本页查词弹窗实际是否底部停靠（总开关 ∧ [popupDockModule] 的细分开关）。
  bool get _popupBottomDocked =>
      mixinAppModel.popupBottomDockedFor(popupDockModule);

  /// BUG-1269：本页的快捷键作用域。非空即启用「弹窗内输入交回宿主」的桥。
  ///
  /// 词典弹窗是纯原生 WebView：指针落在它上面时，键盘与鼠标事件只存在于弹窗 DOM
  /// 里，宿主的 Flutter `Focus` / `Listener` 一个都收不到。点词后弹窗恰好贴在光标旁，
  /// 所以这是常态——不装这座桥，「关掉词典」的键与鼠标键在弹窗持焦时全部落空。
  ///
  /// 与 `BaseSourcePage` 的同名钩子是同一套契约（两个宿主各建一次
  /// [DictionaryPopupLayer]，此处保持对称）。
  ShortcutScope? get dictionaryPopupInputScope => null;

  /// 弹窗可见时仍要生效的动作。token 表由注册表**当前**绑定实时导出，改键立即跟随。
  Set<ShortcutAction> get dictionaryPopupForwardedActions =>
      const <ShortcutAction>{};

  /// 当前要下发给弹窗的输入表。作用域缺席时为空表——空表**仍会**注入，用来清掉热槽
  /// WebView 上残留的旧表。
  DictionaryPopupInputSpec get dictionaryPopupInputSpec =>
      dictionaryPopupInputScope == null
      ? const DictionaryPopupInputSpec()
      : dictionaryPopupInputSpecFor(
          registry: mixinAppModel.shortcutRegistry,
          actions: dictionaryPopupForwardedActions,
        );

  /// 弹窗回传 token 的落地点。
  ///
  /// 默认 no-op：本 mixin 的关栈入口（[popNestedPopupAt]）需要调用方持有的
  /// [DictionaryPopupController]，mixin 自身拿不到，故不在这里替宿主决定怎么关。
  /// 声明了 [dictionaryPopupInputScope] 的宿主必须覆写它（视频页覆写成「只关顶层」，
  /// 与 `guardVideoShortcutsWithPopupDismiss` 同一执行体）。用
  /// [resolveDictionaryPopupInputToken] 把 token 解析成动作——那与键盘路径是同一个
  /// `resolve*`，改键对两条路径同时生效。
  ///
  /// 返回**本次是否真的执行了**动作（BUG-2031：鼠标那条路靠它决定要不要认领这次
  /// 按下）。默认 no-op 故恒 false。
  bool onDictionaryPopupInputToken(String token) => false;

  /// 指针落在**弹窗矩形之外**、按下鼠标非主键（挂在 [LookupDismissBarrier] 上）。
  ///
  /// 与 `BaseSourcePageState` 的同名钩子同一套契约：弹窗可见期间 barrier 的命中行为是
  /// opaque，宿主页面根那层 [Listener] 一个指针事件都收不到，故「矩形之外」这半边只能
  /// 在这里接。折 token / 落地全部复用弹窗表面那条路的同一份判据，两个表面不会各判各的。
  ///
  /// BUG-2031：barrier 的祖先是 `wrapWithGlobalNavigation` 的鼠标兜底 [Listener]，
  /// 祖先不被后代 opaque 排除（实测派发序列 `[barrier, root]`），故本入口必须认领
  /// 这次按下，否则一次侧键 = 关词典 + 退出整页，与键盘 Esc 分叉。
  void onDismissBarrierNonPrimaryButton(PointerDownEvent event) {
    dispatchClaimedMouseAction(event, () {
      final String? token = dictionaryPopupPointerToken(
        buttons: event.buttons,
        spec: dictionaryPopupInputSpec,
      );
      if (token == null) return false;
      return onDictionaryPopupInputToken(token);
    });
  }

  /// 查词浮层顶部可选的 header 行（如视频「收藏当前字幕句」星标）。默认 null（书内查词
  /// 已有自己的 [BaseSourcePageState.buildPopupAudioControls]，不走 mixin；独立查词页 /
  /// 词典页无句子概念，返回 null）。视频页覆写返回顶层（[index] == 0）的句子收藏星标，
  /// 注入到 [DictionaryPopupLayer.headerWidget]——嵌套递归查词层（index > 0）不属于某条
  /// 字幕句，覆写方应只对 index == 0 返回非 null。
  Widget? buildPopupHeaderFor(int index) => null;

  /// TODO-270 E「查词窗口多句合一制卡」(乙方案·视频车道)：弹窗「+句」追加当前正查句到
  /// 本表面会话级制卡草稿，返回累积句数（含本句）。默认 null = 不支持（纯查词页 / 首页
  /// 词典页无句子概念，不渲染「+句」）。视频页覆写返回非空闭包：把当前字幕句 + 其 cue
  /// 音频/画面区间推进 [MiningSentenceDraft]，制卡时合并成一张卡。
  ///
  /// 与 reader 车道（[BaseSourcePageState.supportsSentenceDraft] +
  /// [BaseSourcePageState.onAppendSentenceToDraft]）对称：reader 走 base_source_page
  /// 的弹窗构造，视频/首页查词走本 mixin 的 [buildNestedPopupLayer]，故各自有一个收口
  /// 入口；popup.js「+句」按钮、`appendSentence` JS 处理器、`MiningSentenceDraft` 草稿
  /// 模型三者均平台无关，两条车道共用。非空时弹窗才渲染「+句」（经
  /// `window.sentenceDraftEnabled`）。
  Future<int> Function()? get onAppendSentenceToDraft => null;

  /// TODO-393「上 N 句 / 下 N 句」上下文选择（视频/首页查词车道）：弹窗选「上 N 句 /
  /// 下 N 句」把当前正查句之前/之后的字幕 cue 作上下文**整体设置**进本表面草稿（不掺
  /// 历史累积），返回上下文句总数（上 N + 下 N）。默认 null = 不支持（纯查词页无 cue
  /// 上下文）。视频页覆写返回非空闭包：用 [VideoPlayerController.cues] 在当前 cue 前后
  /// 取 N 条。与 reader 车道（[BaseSourcePageState.onSetSentenceContextToDraft]）对称。
  Future<int> Function(int prevCount, int nextCount)?
  get onSetSentenceContextToDraft => null;

  /// TODO-382「+句」可撤销（视频车道）：弹窗点「清空已加句子」清掉本表面会话级制卡
  /// 草稿，返回清空后的句数（恒 0）。默认 null = 不支持（与 [onAppendSentenceToDraft]
  /// 对称，纯查词页不渲染清空入口）。视频页覆写返回非空闭包清掉 [MiningSentenceDraft]。
  Future<int> Function()? get onClearSentenceDraftToDraft => null;

  /// Niratan「制卡前调整·选择句子上下文」（视频/首页查词车道）：弹窗打开模态时拉取当前
  /// 草稿真实上下文句 + 当前正查句 + 词偏移做预览。默认 null = 不支持（纯查词页无草稿）。
  /// 视频页覆写返回非空闭包（[buildSentenceContextPreview]）。与 reader 车道
  /// （[BaseSourcePageState.onSentenceContextPreviewFromDraft]）对称。
  Future<Map<String, Object?>> Function()?
  get onSentenceContextPreviewToDraft => null;

  /// 「高级制卡」对话框里本页面提供的句子 / 音频 / 图片分区（契约见
  /// [AdvancedMiningCapabilities]）。默认什么都不提供——对话框只有卡组分区。
  /// 视频页覆写。[matched] 是查到的词在句中的表现形。
  @protected
  Future<AdvancedMiningSections> buildAdvancedMiningSections({
    required String matched,
  }) async => AdvancedMiningSections.none;

  /// 「高级制卡」对话框里能不能为这张卡选卡组。默认 true（卡组取本机 Anki 设置）；
  /// 卡组由别的设备决定的表面覆写成 false（手机遥控页：遥控制卡落在电脑端、用电脑的
  /// Anki 配置），对话框就不渲染卡组分区。
  @protected
  bool get advancedMiningDeckChoiceAvailable => true;

  /// 「制卡前调整·选择句子上下文」里**手改某一句文本**（视频/首页查词车道）：把 [slot]
  /// （上文/当前/下文）第 index 句的文本改成给定文本，写回本表面会话级制卡草稿。
  ///
  /// 只改**会写进卡片的那段文本**，不动该句的音频/画面区间与身份——改完仍是同一条
  /// cue、同一段时间窗，GIF 与句子音频的裁法完全不变。默认 null = 不支持（纯查词页
  /// 无草稿），对话框据此不渲染编辑入口。视频页覆写返回非空闭包。与 reader 车道
  /// （[BaseSourcePageState.onEditSentenceContextText]）对称。
  Future<void> Function(SentenceContextSlot slot, int index, String text)?
  get onEditSentenceContextText => null;

  /// 「制卡前调整·选择句子上下文」里把上文/下文第 index 句从卡片里移除或恢复
  /// （视频/首页查词车道）。默认 null = 不支持，对话框不渲染移除入口。视频页覆写。
  /// 与 reader 车道（[BaseSourcePageState.onRemoveSentenceContext]）对称。
  Future<void> Function(SentenceContextSlot slot, int index, bool removed)?
  get onRemoveSentenceContext => null;

  /// 「制卡前调整·选择句子上下文」里的「试听」（视频/首页查词车道）：放这张卡会写进
  /// 去的那段句子音频（草稿上下文 + 当前句合并后的区间），返回 false = 没有可试听
  /// 的音频。默认 null = 不支持，对话框不渲染试听按钮。视频页放本机播放器；手机遥控
  /// 页经遥控协议让电脑端播放器放（手机上没有视频音频）。与 reader 车道
  /// （[BaseSourcePageState.onPreviewSentenceAudio]）对称。
  Future<bool> Function()? get onPreviewSentenceAudioToDraft => null;

  /// 停止 [onPreviewSentenceAudioToDraft] 起的试听。与之同时为 null 或同时非 null。
  Future<void> Function()? get onStopSentenceAudioPreviewToDraft => null;

  /// BUG-797 / BUG-1040：有多少个「必须盖住查词弹窗」的 Flutter 对话框正开着。
  ///
  /// 查词弹窗是**原生平台视图**（桌面 WebView2 / Android platform view），靠 airspace 永远
  /// 画在 Flutter overlay 之上——任何 `showAppDialog` 弹出来的对话框都会被它盖住（用户报
  /// 「层级不对/看不见」）。这些对话框期间据此把弹窗 [parkedPopupLayer] 的 `visible` 强制
  /// 翻假 → 停靠屏外（BUG-135 停靠语义，webview 仍存活、回点制卡照常），让对话框独占屏幕。
  ///
  /// BUG-1040 从 bool 改成**计数**：制卡动作对话框里还能再叠一层 note viewer 对话框，用
  /// bool 会被内层的 `finally` 提前复位、外层对话框当场被弹窗盖住。计数天然支持嵌套。
  int _popupHidingDialogDepth = 0;

  /// 是否有「必须盖住查词弹窗」的对话框正开着（[runWithLookupPopupHidden] 期间为真）。
  ///
  /// BUG-1327：宿主页除了弹窗层本身，还会画**整屏 dismiss barrier**（点弹窗外面关栈）。
  /// 视频页把整棵浮层子树挂在**根 Overlay**（为了盖过 media_kit 全屏路由），而根 Overlay
  /// 里手动 `insert` 的 entry 永远排在 `showAppDialog` 推的路由之上——对话框看得见却点不
  /// 着：点击先被 barrier 吃掉，再被判成「点弹窗外面」直接清整栈。故 barrier 必须与
  /// [parkedPopupLayer] 的 `visible` 共用同一门控：对话框期间整棵浮层既不显示也不拦点击。
  ///
  /// BUG-3685：同一道门也管「宿主路由被别的路由盖住」（[lookupOwnerRoute]）。浮层 entry
  /// 手动插在根 Overlay 上，`Navigator` 每次 push 都经 `Overlay.rearrange` 把非路由
  /// entry 排回最顶——之后推进来的整页（反馈 / 设置……）照样被浮层与整屏 barrier 压住：
  /// 看得见浮层、点不着页面，点击还被判成「点浮层外面」关栈并恢复播放。与对话框同一种
  /// 让位：停靠屏外、撤 barrier，查词会话（含「因查词暂停」）原样保留，宿主路由回到
  /// 栈顶即复原。
  @protected
  bool get lookupPopupHiddenByDialog =>
      _popupHidingDialogDepth > 0 || lookupOwnerRouteCovered;

  /// 查词浮层所属的路由（BUG-3685）。浮层挂在根 Overlay、跨路由生存的宿主覆写它（视频页：
  /// 窗口模式是本页路由，全屏期间是全屏路由）；null = 不跟随路由（默认，浮层与宿主同在
  /// 一个路由里，或宿主本就常驻在导航之上）。
  ///
  /// 覆写方还要保证「路由栈顶状态变化」能让浮层重建：订阅 `ModalRoute.isCurrentOf`
  /// 并在变化后刷新浮层 entry——本 getter 只在浮层 build 时被读取。
  @protected
  ModalRoute<Object?>? get lookupOwnerRoute => null;

  /// [lookupOwnerRoute] 还在栈上、但已不是栈顶（被别的路由盖住）。宿主的查词入口
  /// （含 extension part）据此拒绝起新查词，故不标 `@protected`。
  bool get lookupOwnerRouteCovered {
    final ModalRoute<Object?>? route = lookupOwnerRoute;
    return route != null && route.isActive && !route.isCurrent;
  }

  /// BUG-1040：在 [body] 执行期间把查词弹窗停靠屏外的统一入口（收口 setState 增减，杜绝
  /// 各调用点各写一份 try/finally 漏复位）。[body] 抛错时照常复位。
  Future<T> runWithLookupPopupHidden<T>(Future<T> Function() body) async {
    if (mounted) setState(() => _popupHidingDialogDepth++);
    try {
      return await body();
    } finally {
      if (mounted) {
        setState(
          () => _popupHidingDialogDepth = _popupHidingDialogDepth > 0
              ? _popupHidingDialogDepth - 1
              : 0,
        );
      }
    }
  }

  /// 「高级制卡」（视频 / 首页查词车道）：点某词条的「高级制卡」→ 弹 **app 原生顶层
  /// 对话框**（[showAdvancedMiningDialog]，BUG-763/766：不画在查词弹窗 WebView 内）。
  /// 卡组分区按 Anki 设置统一组装；句子 / 音频 / 图片分区由页面覆写
  /// [buildAdvancedMiningSections] 提供；「确认」回 [webViewKey] 那层弹窗精确点中第
  /// [entryIndex] 个词条的「+」并带上覆盖项。与 reader 车道
  /// （`BaseSourcePageState._openAdvancedMiningDialog`）对称。
  ///
  /// 结果来自别的设备（[popupResourceSource] 非 null）或表面声明卡组不由本机决定
  /// （[advancedMiningDeckChoiceAvailable] 为 false）时卡片落在那台设备、用它的 Anki
  /// 配置，本机的卡组列表对它没有意义——不给卡组分区。
  Future<void> _openAdvancedMiningDialog({
    required GlobalKey<DictionaryPopupWebViewState> webViewKey,
    required int entryIndex,
    required String matched,
    required String expression,
  }) async {
    if (!mounted) return;
    // 本 mixin 没有 State 的 mounted 语义可借（mounted 是抽象成员），按 lint 的要求
    // 用 BuildContext 自己的 mounted 判断跨 await 之后还能不能弹窗。
    final BuildContext dialogContext = context;
    // BUG-797：对话框期间把弹窗 WebView 停靠屏外，否则原生平台视图盖住对话框。
    await runWithLookupPopupHidden<void>(() async {
      final AdvancedMiningDeckSection? deck =
          popupResourceSource == null && advancedMiningDeckChoiceAvailable
          ? await loadAdvancedMiningDeckSection(ref)
          : null;
      // 卡片字段与卡组同一门槛：远端制卡（popupResourceSource）的字段映射在另一台
      // 机器上，这里的映射对不上，不给改。
      final AdvancedMiningFieldsSection? fields =
          popupResourceSource == null && advancedMiningDeckChoiceAvailable
          ? await loadAdvancedMiningFieldsSection(
              ref,
              fetchPayload: () async =>
                  webViewKey.currentState?.buildMinePayloadByIndex(entryIndex),
              fallbackSentence: () => favoriteLookupContext?.sentence ?? '',
            )
          : null;
      final AdvancedMiningSections sections = await buildAdvancedMiningSections(
        matched: matched,
      );
      if (!dialogContext.mounted) {
        await sections.onClosed?.call();
        return;
      }
      await showAdvancedMiningDialog(
        context: dialogContext,
        capabilities: AdvancedMiningCapabilities(
          matched: matched,
          expression: expression.isEmpty ? null : expression,
          deck: deck,
          fields: fields,
          sections: sections,
          // BUG-2627：回传「有没有真的点到制卡按钮」。弹窗层在这次往返途中被关栈
          // （或 State 已卸载）时为 false，对话框据此提示，不再静默关窗。
          onConfirm: (MiningRequestOverrides overrides) async =>
              await webViewKey.currentState?.mineEntryByIndex(
                entryIndex,
                // BUG-2634 第二轮：_onMineEntryImpl 在 await _mineVideoCard
                // 之前就把草稿 / cue / 历史快照读完，连当前帧截图的 Future 都
                // 在点击当下同步启动，所以提前关窗不会截到别的帧。
                releaseWhenPayloadConsumed: true,
                overrides: overrides,
              ) ??
              false,
        ),
      );
    });
  }

  // 今日统计 dateKey 走 stat_activity 的权威实现（statTodayKey），不在此重复格式化。
  String _statTodayKey() => statTodayKey();

  // ---------------------------------------------------------------------------
  // Concrete helpers
  // ---------------------------------------------------------------------------

  /// Returns [rect] unchanged when it is non-zero, otherwise returns a tiny
  /// 1×1 rect at (12, 12) that avoids placement calculations breaking on zero.
  Rect fallbackSelectionRect(Rect rect) {
    if (rect != Rect.zero) return rect;
    return const Rect.fromLTWH(12, 12, 1, 1);
  }

  /// TODO-108：video 家族（及独立查词页 / 首页查词）查词弹窗位置计算的单一收口点——
  /// 等价于 base_source_page._calculatePopupPosition 之于 reader 家族。底部固定模式时
  /// 忽略选区位置返回屏幕底部全宽 dock 面板（[dockedPopupRect]），否则沿用原跟随逻辑
  /// （[calcPopupPosition]，尺寸随界面大小放大）。在共享 mixin 收口而非 video_fushi_page，
  /// 一处分流即覆盖 buildNestedPopupLayer / buildPopupLoadingPlaceholder 两个调用点，且
  /// 不触碰 video 页本体。盒子尺寸口径与原两处一致（maxWidth/Height × appUiScale，padding
  /// 与 reserve 走 calcPopupPosition 默认 6/0）。
  Rect _calcMixinPopupPosition(
    Rect selectionRect,
    Size screen, {
    double? autoFitHeight,
  }) {
    // 与 base_source_page._calculatePopupPosition 共用 [resolvePopupRect]。mixin
    // 家族（video/首页/texthooker）不预留 reserve、不竖排避让（全用默认），盒子尺寸
    // 随界面大小放大（同 base 的 popupMaxWidth/Height）。Phase B 拖把手时用预览态
    // [_popupResizePreview] 临时覆盖偏好实时预览（松手落库，见 [_onMixinPopupResizeEnd]）。
    final double preferredMaxHeight =
        (_popupResizePreview?.height ?? mixinAppModel.popupMaxHeight) *
        mixinAppModel.appUiScale;
    final double effectiveMaxHeight = _popupResizePreview != null
        ? preferredMaxHeight
        : (autoFitHeight ?? preferredMaxHeight)
              .clamp(0.0, preferredMaxHeight)
              .toDouble();
    // 选区是屏幕 rect（`localToGlobal`），浮层坐标系是根 Overlay（中和后净缩放 1、
    // 原点与根 Overlay 重合）。Windows 自绘标题栏把根 Overlay 压低 32px 时两者不同
    // 系，整栈弹窗会集体下移压进被查词（BUG-2092）。在唯一收口处减去偏移，首层 /
    // 嵌套 / 搜索占位三条入口一并归正；无偏移时是零位移，历史行为不变。
    final Rect layerSelection = selectionRect.shift(
      -rootOverlayScreenOrigin(context),
    );
    final Rect anchored = resolvePopupRect(
      selectionRect: layerSelection,
      screen: screen,
      bottomDocked: _popupBottomDocked,
      maxWidth:
          (_popupResizePreview?.width ?? mixinAppModel.popupMaxWidth) *
          mixinAppModel.appUiScale,
      maxHeight: effectiveMaxHeight,
    );
    // Phase B 拖拽尺寸（2026-07-15）：被拖的那张卡（选区匹配）冻结左上角，从右下生长，
    // 消除「词靠右缘时贴词定位把左缘左移」的 bug（同 base_source_page）。dock 模式不冻结。
    if (!_popupBottomDocked &&
        _popupResizeAnchorTopLeft != null &&
        _popupResizeAnchorSelection == selectionRect) {
      return anchorPopupTopLeft(
        anchored: anchored,
        topLeft: _popupResizeAnchorTopLeft!,
        screen: screen,
        inset: 6.0,
      );
    }
    return anchored;
  }

  /// Phase B 尺寸拖拽的预览态（基准逻辑像素，未缩放）。非空 = 正在拖右下角把手；
  /// null = 未拖，用已落库真值。reader 家族的对应态在 [BaseSourcePageState]。
  LookupSize? _popupResizePreview;

  /// Phase B 拖拽尺寸的**冻结原点**（2026-07-15，同 base_source_page）：拖右下把手时把
  /// 弹窗左上角钉在拖拽起点、只往右下生长，持续到换词/关窗。[_popupResizeAnchorSelection]
  /// 记它属于哪张卡；[_topPopupAnchoredRect]/[_topPopupSelectionRect] 是供起手取当前左上角
  /// 的顶层卡缓存。
  Offset? _popupResizeAnchorTopLeft;
  Rect? _popupResizeAnchorSelection;
  Rect? _topPopupAnchoredRect;
  Rect? _topPopupSelectionRect;

  /// 拖把手起手：存当前偏好基准尺寸为预览起点，并冻结顶层卡当前左上角。
  void _onMixinPopupResizeStart() {
    setState(() {
      _popupResizePreview = LookupSize(
        mixinAppModel.popupMaxWidth,
        mixinAppModel.popupMaxHeight,
      );
      _popupResizeAnchorTopLeft = _topPopupAnchoredRect?.topLeft;
      _popupResizeAnchorSelection = _topPopupSelectionRect;
    });
  }

  /// 拖把手进行：盒坐标系增量位移 [deltaPx] 经 [resolveDraggedLookupSize] 折算回基准
  /// （除 appUiScale）并 clamp，驱动实时重建。
  void _onMixinPopupResizeUpdate(Offset deltaPx) {
    final LookupSize base =
        _popupResizePreview ??
        LookupSize(mixinAppModel.popupMaxWidth, mixinAppModel.popupMaxHeight);
    setState(() {
      _popupResizePreview = resolveDraggedLookupSize(
        currentBaseWidth: base.width,
        currentBaseHeight: base.height,
        deltaWidthPx: deltaPx.dx,
        deltaHeightPx: deltaPx.dy,
        uiScale: mixinAppModel.appUiScale,
      );
    });
  }

  /// 松手：预览尺寸一次性落偏好（`setPopupMaxWidth/Height`，与设置滑杆同源真值）后清空。
  void _onMixinPopupResizeEnd() {
    final LookupSize? committed = _popupResizePreview;
    setState(() => _popupResizePreview = null);
    if (committed != null) {
      mixinAppModel.setPopupMaxWidth(committed.width);
      mixinAppModel.setPopupMaxHeight(committed.height);
    }
  }

  /// 拖拽被竞技场中途取消：丢弃预览态回到「读真值」，不落偏好；一并撤销冻结原点（回贴词）。
  void _onMixinPopupResizeCancel() {
    if (_popupResizePreview == null) return;
    setState(() {
      _popupResizePreview = null;
      _popupResizeAnchorTopLeft = null;
      _popupResizeAnchorSelection = null;
    });
  }

  /// Mines the current dictionary entry to Anki.
  ///
  /// Shows a Fluttertoast for each outcome and returns `true` on success.
  /// 把统计来源标识（[kStatSourceBook]/[kStatSourceVideo]）映射成 [AnkiMiningSource]，
  /// 用于给制出的卡片追加分类标签（书籍→`book`，视频→`video`，音乐→`music`）。未知来源返回
  /// [AnkiMiningSource.book]（保守归书籍，与默认 [dictionarySourceType] 一致）。
  ///
  /// 可覆写（BUG-1137）：统计来源与制卡分类标签是两个维度——texthooker 页统计仍归
  /// 书籍桶，但制出的卡应打 `game` 分类标签，故覆写本 getter 而非动统计口径。
  @protected
  AnkiMiningSource get miningSource => switch (dictionarySourceType) {
    kStatSourceVideo => AnkiMiningSource.video,
    kStatSourceMusic => AnkiMiningSource.music,
    _ => AnkiMiningSource.book,
  };

  /// 制卡来源标题（卡面 `{document-title}`，无库内定位时也是 `{source-link}` 的链接
  /// 文字）。默认 null = 不带标题（独立查词页 / 复习卡面）；app 内浏览器经查词宿主覆写成
  /// 当前网页标题。
  @protected
  String? get miningDocumentTitle => null;

  /// 制卡来源网址（[AnkiMiningContext.sourceUrl]，`{source-link}` 渲染成指向它的链接）。
  /// 默认 null；app 内浏览器经查词宿主覆写成当前网页网址（无痕标签页不给）。
  @protected
  String? get miningSourceUrl => null;

  /// 弹窗查词的数据源注入点：首查（[pushNestedPopup]）、加载更多（[loadMoreForEntry]）
  /// 与原地跳转（[navigatePopupInPlace]）三处都只走这里。默认走本机
  /// [AppModel.searchDictionary]（含它自己的远端优先分支），行为与从前一致；手机字幕
  /// 遥控器覆写成「只问钉住的那台电脑」，嵌套查词 / 原地跳转 / 加载更多随之同源。
  @protected
  ///
  /// [rubySpans]：[term] 上来源自带的振假名（取词处的 `<ruby>` / 结构化 ruby），引擎据此
  /// 让读音吻合的同长度候选排前；空 = 与不带 ruby 的查词完全等价。
  Future<DictionarySearchResult> searchPopupDictionary({
    required String term,
    required int maximumTerms,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
  }) => mixinAppModel.searchDictionaryWithRuby(
    searchTerm: term,
    rubySpans: rubySpans,
    searchWithWildcards: true,
    overrideMaximumTerms: maximumTerms,
  );

  /// 自动发音的播放注入点（[autoReadWord] 解析 + 播放的那一步）。默认走本机音频源
  /// [autoReadWordUnified]；查词结果来自别的设备时覆写成问那台设备要发音。返回是否
  /// 真的开始播放（去重窗口靠它，BUG-1127）。
  @protected
  Future<bool> playPopupWordAudio(
    String expression,
    String reading,
    DictionaryPopupWebViewState? popupState,
  ) => autoReadWordUnified(
    mixinAppModel,
    expression,
    reading,
    playInWebView: popupState?.playWordAudioUrl,
  );

  /// 弹窗词典侧资源（样式 / 媒体 / ♪）的来源，透传给每一层 [DictionaryPopupLayer]。
  /// null（默认）= 本机词典；结果来自别的设备时宿主返回那台设备的资源源。
  @protected
  DictionaryPopupResourceSource? get popupResourceSource => null;

  /// 制卡卡图的来源（反馈 Gz7z6Y6Mbr）：截屏识字 / 拍照查词的查词宿主覆写成「这次
  /// 点字用的那张图 + 文本块」，制卡时裁出卡图走 [AnkiMiningContext.coverPath]（与漫画
  /// 卡图同一通道）。默认 null = 不带图；偏好「截屏识字制卡带图」关着时也不带。
  @protected
  ScreenOcrCardImage? get miningCardImage => null;

  /// 按 [miningCardImage] 裁出本次制卡的卡图；没有来源 / 偏好关着 / 裁不出返回 null。
  Future<({String path, Directory dir})?> _prepareMiningCover() async {
    final ScreenOcrCardImage? source = miningCardImage;
    if (source == null) return null;
    final AppModel model = mixinAppModel;
    if (!model.prefsRepo.screenOcrCardImage) return null;
    return writeScreenOcrCardImage(source, imageTier: model.miningImageQuality);
  }

  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final repo = ref.read(ankiRepositoryProvider);
    final ({String path, Directory dir})? cover = await _prepareMiningCover();
    try {
      return await _mineEntryWithCover(repo, fields, cover?.path);
    } finally {
      if (cover != null) unawaited(deleteScreenOcrCardDir(cover.dir));
    }
  }

  Future<MinePopupResult> _mineEntryWithCover(
    BaseAnkiRepository repo,
    Map<String, String> fields,
    String? coverPath,
  ) async {
    final CardSourceLink? sourceLink = miningCardSourceLink;
    final miningContext = AnkiMiningContext(
      sentence: fields['sentence'] ?? '',
      coverPath: coverPath,
      source: miningSource,
      // 有库内定位（回到出处）时标题取出处的标题；否则取宿主给的来源标题（app 内浏览器
      // = 当前网页标题，其余默认 null）。
      documentTitle: sourceLink != null
          ? minedSentenceOrigin?.title
          : miningDocumentTitle,
      sourceLink: sourceLink,
      sourceUrl: miningSourceUrl,
    );
    // TODO-1325 #6：制卡可能要走网络（AnkiConnect）+ 下音频，先弹「制卡中…」蓝色
    // pending toast 给即时反馈；结果 toast 会顶替它。
    FushiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    final outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    // 牌组名由后端随成功结果带回（outcome.deckName，BUG-1549）。
    final described = describeMineOutcome(outcome);
    // 制卡成功计入统计（按来源 book/video）。失败不影响制卡结果，吞掉并记日志。
    if (described.record) unawaited(recordMined());
    // TODO-633: also land a mined-sentence history row. This mixin path serves
    // standalone/home lookup (no book context), so locator anchors stay null
    // (shown as non-navigable in collections, same as existing lookup-only).
    if (described.record) {
      unawaited(recordMinedSentence(fields, outcome.noteId));
    }
    // TODO-1325 #6：MD3 着色 + 图标 toast。着色状态由 describeMineOutcome 单一真相
    // 带出（added 绿 / duplicate 橙 / failed 红），此处不再本地 switch。
    if (described.success) {
      FushiToast.showMine(msg: described.message, status: described.status);
      // TODO-270 D：带回 note id 让弹窗把刚制的这张标记为「最新可改」第三态
      // （AnkiConnect 非空，AnkiDroid 恒 null = 优雅降级进不了第三态）。
      return MinePopupResult.mined(outcome);
    }
    // BUG-1908/1915：重复是「卡已在 Anki 里」而不是「没有卡」，把这个确定事实带回
    // 弹窗，否则 ✓ 被画成 ＋ 且 ↗ 入口消失（弹窗侧不许回查 Anki——TODO-448）。
    // 判据只住在 .failed(outcome) 一处。失败原因交给弹窗就地说，不另弹 toast
    // （见 MinePopupResult.message）。
    return MinePopupResult.failed(outcome, message: described.message);
  }

  /// TODO-270 D：覆盖「最新制的那张卡」（[noteId]）的字段——走 repo.updateMinedNote
  /// 按 id 真实覆盖（不删旧建新、不查重、不计入统计）。后端不支持覆盖（AnkiDroid）时
  /// repo 返回明确失败 → 这里弹 toast 提示，不崩。
  Future<MinePopupResult> onUpdateEntry(
    int noteId,
    Map<String, String> fields,
  ) async {
    final repo = ref.read(ankiRepositoryProvider);
    final ({String path, Directory dir})? cover = await _prepareMiningCover();
    try {
      return await _updateEntryWithCover(repo, noteId, fields, cover?.path);
    } finally {
      if (cover != null) unawaited(deleteScreenOcrCardDir(cover.dir));
    }
  }

  Future<MinePopupResult> _updateEntryWithCover(
    BaseAnkiRepository repo,
    int noteId,
    Map<String, String> fields,
    String? coverPath,
  ) async {
    final miningContext = AnkiMiningContext(
      sentence: fields['sentence'] ?? '',
      coverPath: coverPath,
      source: miningSource,
      documentTitle: miningDocumentTitle,
      sourceUrl: miningSourceUrl,
    );
    // TODO-1325 #6：覆写同样先弹 pending。
    FushiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    final outcome = await repo.updateMinedNote(
      noteId: noteId,
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    // 覆盖路径走收口的单一真相（overwrite=true → card_overwritten + 不记账）。
    final described = describeMineOutcome(outcome, overwrite: true);
    // TODO-1325 #6：覆写成功也是 added（绿），失败按状态着色。状态取自单一真相。
    if (described.success) {
      FushiToast.showMine(msg: described.message, status: described.status);
      return MinePopupResult.mined(outcome);
    }
    return MinePopupResult.failed(outcome, message: described.message);
  }

  /// Resolves and plays the audio for [expression] / [reading]. [popupState] is
  /// the just-rendered popup WebView (when this surface renders results in a
  /// popup): auto-read then plays through its own `<audio>` element — the unified
  /// fast path shared with the manual ♪ button and every surface. Null (e.g. an
  /// inline full-page view with no popup WebView) falls back to the Dart player.
  Future<void> autoReadWord(
    String expression,
    String reading, {
    DictionaryPopupWebViewState? popupState,
  }) async {
    await LookupAutoReadCoordinator.instance.runAutomatic(
      expression: expression,
      reading: reading,
      play: () => _playAutoReadWord(expression, reading, popupState),
    );
  }

  Future<bool> _playAutoReadWord(
    String expression,
    String reading,
    DictionaryPopupWebViewState? popupState,
  ) => playPopupWordAudio(expression, reading, popupState);

  /// Checks whether a card for [expression] / [reading] already exists in Anki.
  Future<bool> checkDuplicate(String expression, String reading) async {
    final repo = ref.read(ankiRepositoryProvider);
    return repo.isDuplicate(expression, reading);
  }

  /// TODO-614：当用户把覆写范围设为「全部」（[AnkiOverwriteScope.all]）时，按与查重
  /// 同一条件反查一张可覆写的已存在 note id（多张取最近），让弹窗把更早的卡也标成
  /// 「最新可改」✓↩ 第三态、点它走 [onUpdateEntry] 按 id 覆写。范围为默认 latest 或
  /// 后端（AnkiDroid）拿不到 id 时回 null → 弹窗维持旧的两态行为（Never break userspace）。
  Future<int?> findOverwriteTargetNoteId(
    String expression,
    String reading,
  ) async {
    final repo = ref.read(ankiRepositoryProvider);
    return repo.findOverwriteTargetNoteId(expression, reading);
  }

  /// TODO-1007/1008：点 ✓（卡已存在）的编排入口（视频/首页/独立查词车道）。据当前
  /// 词条 [fields] 的 expression/reading 反查 Anki 全部命中卡，弹操作选择让用户选
  /// （覆写哪张 / 新增重复卡 / 查看·在 Anki 中打开），复用 [onMineEntry]/[onUpdateEntry]
  /// 执行，返回 [MinePopupResult] 刷新 ✓。与 reader 车道（base_source_page）对称。
  Future<MinePopupResult> onMinedCardAction(Map<String, String> fields) async {
    final repo = ref.read(ankiRepositoryProvider);
    final expression = fields['expression'] ?? '';
    final reading = fields['reading'] ?? '';
    // 「新增」分支的原始结果：进了待发队列时要原样交回弹窗（同 base_source_page）。
    MinePopupResult? minedNew;
    // 同 base_source_page：失败时原样交回，带着只在弹窗里说的失败原因。
    MinePopupResult? failed;
    final r = await runAnkiMinedCardAction(
      context: context,
      repo: repo,
      expression: expression,
      reading: reading,
      // BUG-2605：与 base_source_page 同口径——mineNew 只在用户已被告知「卡已有」
      // 并选择继续后才会被调，请求必须带 allowDuplicate。
      mineNew: () async {
        final res = await onMineEntry(
          AnkiMiningPayload.withAllowDuplicate(fields),
        );
        minedNew = res;
        if (!res.accepted) failed = res;
        return (ankiConnect: res.ankiConnect, noteId: res.noteId);
      },
      overwrite: (noteId) async {
        final res = await onUpdateEntry(noteId, fields);
        if (!res.accepted) failed = res;
        return (ankiConnect: res.ankiConnect, noteId: res.noteId);
      },
      // BUG-1040：对话框期间停靠查词弹窗，否则原生平台视图盖住它（用户报「看不见」）。
      runHidden: runWithLookupPopupHidden,
    );
    if (minedNew?.queued ?? false) return minedNew!;
    if (!r.ankiConnect && failed != null) return failed!;
    return MinePopupResult(ankiConnect: r.ankiConnect, noteId: r.noteId);
  }

  /// BUG-3492：卡还在后台写入 Anki 时的覆盖请求（弹窗显示「已加入」时再点 ✓ / 从
  /// 「高级制卡」确认）。默认不收——只有会回「已加入」并在后台落卡的宿主（视频页的在线
  /// 视频）覆写它，把请求排到那次写入之后。
  Future<QueuedOverwriteReply> onQueueOverwrite(
    Map<String, String> fields,
  ) async => const QueuedOverwriteReply();

  /// [buildNestedPopupLayer] 第 [index] 层制卡 / 覆写 / 已有卡操作 / 排队覆写之前，
  /// 让宿主按层补上它知道而弹窗 JS 不知道的上下文。默认原样返回。
  ///
  /// 反馈 1Mwaro8UTC：主窗常驻查词宿主（悬浮球拍照查词 / iOS 截屏识字 / 悬浮字幕
  /// 点字）的查词出自一整行原文，JS 制卡不带 `sentence`，此前这里没有任何入口能把那
  /// 一行交回去，卡上就只有单词、没有例句。该宿主覆写本方法按
  /// [withSourceLineSentence] 补基础层的例句。
  @protected
  Map<String, String> miningFieldsForLayer(
    int index,
    DictionaryPopupController controller,
    Map<String, String> fields,
  ) => fields;

  /// TODO-1360 / BUG-2051：已制卡的词旁 ↗「在 Anki 中打开卡片」按钮的车道入口
  /// （视频/首页/独立查词，与 reader 车道 [BaseSourcePageState.onOpenInAnkiFromPopup]
  /// 对称）。判据与画 ✓ 的查重同源，见 [BaseAnkiRepository.openWordInAnki]：直接把
  /// Anki 浏览器过滤到「Anki 认为这个词已有的卡」，不再先反查 note id、也不再由我们
  /// 弹「打开哪一张」——多张就让 Anki 浏览器列出来。结局回传给弹窗按钮就地提示。
  Future<AnkiOpenWordOutcome> onOpenInAnki(
    String expression,
    String reading,
  ) async {
    final repo = ref.read(ankiRepositoryProvider);
    return repo.openWordInAnki(expression, reading);
  }

  /// 把一次成功制卡计入统计（按 [dictionarySourceType]）。
  ///
  /// 视频页等覆写 [onMineEntry]、绕过基类成功分支的页面，在自己的成功路径上
  /// 直接调本方法记账（来源仍走各自的 [dictionarySourceType]），不必复制
  /// [FushiDatabase.recordMiningEvent] 的契约细节。
  @protected
  Future<void> recordMined() async {
    // P4 写侧收敛：全局汇总 + per-book 计数走 DB 复合入口
    // [FushiDatabase.recordMiningEvent]（同事务，dateKey 由 DB 层从 at 派生），
    // 半写漂移不再可能。best-effort 契约不变：失败吞掉记日志。
    final ({String? bookKey, String? title})? identity = lookupBookIdentity;
    try {
      await mixinAppModel.database.recordMiningEvent(
        bookKey: identity?.bookKey,
        title: identity?.title ?? '',
        sourceType: dictionarySourceType,
        at: DateTime.now(),
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] recordMiningEvent failed: $e\n$st');
    }
  }

  /// TODO-1204：本次查词 / 制卡归属的书身份（[bookKey] + [title]）。视频页覆写返回
  /// (bookUid, 剧集标题)；无书来源（首页 / 独立查词窗 / 歌词）保持 null → 只进统计页
  /// 「查词」汇总，不落 per-book / per-video tile。[title] 与各统计页 tile 的 title
  /// 聚合键对齐。
  @protected
  ({String? bookKey, String? title})? get lookupBookIdentity => null;

  /// 收藏词时的上下文（原句 + 定位锚点，口径见 [FavoriteLookupContext]）。视频页覆写
  /// 返回查词所在字幕句与 cue 时间窗；其余宿主默认 null（只落词形与释义）。
  @protected
  FavoriteLookupContext? get favoriteLookupContext => null;

  /// TODO-1204：[DictionaryPopupController.onLookupStarted] 注入点——每次查词
  /// （顶层 / 嵌套 / 重复查各一次）累加 [FushiDatabase.addLookupCount]。宿主构造
  /// controller 后调 [attachLookupCounter] 接线。best-effort。
  @protected
  void recordLookup() {
    // best-effort：连同同步阶段（[mixinAppModel.database] late 字段 getter 在 DB 未
    // 初始化时会抛 LateInitializationError）一起吞掉——查词计数是旁路埋点，任何异常
    // 都不得打断弹窗查词流程。
    try {
      final ({String? bookKey, String? title})? identity = lookupBookIdentity;
      unawaited(
        mixinAppModel.database
            .addLookupCount(
              bookKey: identity?.bookKey,
              title: identity?.title ?? '',
              sourceType: dictionarySourceType,
              dateKey: _statTodayKey(),
            )
            .catchError((Object e, StackTrace st) {
              debugPrint('[fushi-stats] addLookupCount failed: $e\n$st');
            }),
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] addLookupCount failed (sync): $e\n$st');
    }
  }

  /// TODO-1204：把 [recordLookup] 挂到 [controller] 的查词开始回调上。各 mixin 宿主
  /// （视频 / 首页 / 独立查词窗 / texthooker / 歌词浮层）在 initState 构造 controller
  /// 后调用一次。
  @protected
  void attachLookupCounter(DictionaryPopupController controller) {
    controller.onLookupStarted = recordLookup;
  }

  /// 制卡历史行的出处身份（`mined_sentences.book_key` + 标题快照）。首页 / 独立
  /// 查词窗没有出处，恒 null（行不可跳转）；texthooker 覆写为当前 galgame 会话的
  /// `galgames.id`（回到出处 = 打开该游戏详情 / 文本钩子历史）。
  @protected
  ({String key, String? title})? get minedSentenceOrigin => null;

  /// 本宿主制出的卡携带的出处链接（复习时「回到出处」）。默认 null（首页 / 独立
  /// 查词无出处）；texthooker 覆写为游戏出处。
  @protected
  CardSourceLink? get miningCardSourceLink => null;

  /// TODO-633: land one mined-sentence history row. Locator = [minedSentenceOrigin]
  /// (null for home/standalone lookup). Best-effort; failure is swallowed + logged.
  @protected
  Future<void> recordMinedSentence(
    Map<String, String> fields,
    int? noteId,
  ) async {
    try {
      final ({String key, String? title})? origin = minedSentenceOrigin;
      await mixinAppModel.database.addMinedSentence(
        source: dictionarySourceType,
        dateKey: _statTodayKey(),
        bookKey: origin?.key,
        documentTitle: origin?.title,
        expression: fields['expression'] ?? '',
        reading: fields['reading'] ?? '',
        glossary: fields['glossary'] ?? '',
        sentence: fields['sentence'] ?? '',
        noteId: noteId,
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] addMinedSentence failed: $e\n$st');
    }
  }

  /// 切换收藏当前词条：已收藏则取消，否则收藏。返回切换后的新状态（true=已收藏）。
  /// 收藏按来源（book/video）落 DB，并计入各自统计。
  Future<bool> onFavoriteEntry(Map<String, String> fields) async {
    final String expression = fields['expression'] ?? '';
    final String reading = fields['reading'] ?? '';
    if (expression.isEmpty) return false;
    final db = mixinAppModel.database;
    final bool already = await db.isFavoriteWord(
      expression: expression,
      reading: reading,
      sourceType: dictionarySourceType,
    );
    if (already) {
      await db.removeFavoriteWord(
        expression: expression,
        reading: reading,
        sourceType: dictionarySourceType,
      );
      // TODO-956 A：与 [base_source_page] 同因——桌面 callHandler 返回值不一定回传
      // JS，弹窗 ☆→★ 变色不可靠。视频弹窗走本 mixin，DB 写成功后同样解耦弹 toast，
      // 保证 reader / 有声书 / 视频三宿主收藏反馈一致。
      FushiToast.show(
        msg: t.word_favorite_removed,
        severity: ToastSeverity.success,
      );
      return false;
    }
    // TODO-1252：把当前书 / 视频身份（视频页覆写 lookupBookIdentity）随收藏落库，供
    // 统计页 per-book/video tile 聚合「收藏 N」；无书来源为 null / '' → 只进汇总。
    final ({String? bookKey, String? title})? favIdentity = lookupBookIdentity;
    final FavoriteLookupContext? favContext = favoriteLookupContext;
    await db.addFavoriteWord(
      expression: expression,
      reading: reading,
      glossary: fields['glossary'] ?? '',
      sourceType: dictionarySourceType,
      dateKey: _statTodayKey(),
      bookKey: favIdentity?.bookKey,
      title: favIdentity?.title ?? '',
      sentence: favContext?.sentence ?? '',
      sectionIndex: favContext?.sectionIndex,
      normCharOffset: favContext?.normCharOffset,
      normCharLength: favContext?.normCharLength,
    );
    FushiToast.show(
      msg: t.word_favorite_added,
      severity: ToastSeverity.success,
    );
    return true;
  }

  /// 查询某词条当前是否已收藏（供弹窗按钮初始 ☆/★ 状态）。
  Future<bool> onFavoriteCheck(String expression, String reading) async {
    if (expression.isEmpty) return false;
    return mixinAppModel.database.isFavoriteWord(
      expression: expression,
      reading: reading,
      sourceType: dictionarySourceType,
    );
  }

  // ---------------------------------------------------------------------------
  // Popup stack management
  // ---------------------------------------------------------------------------

  /// BUG-2039 ③：把 [controller] 里停驻的嵌套 realm 逐把渲染成屏外隐藏层，紧跟在
  /// entries 层之后放进宿主 Stack。不渲染 = 键背后的 WebView 被销毁 = 下一次嵌套
  /// 查词退化成冷建。
  List<Widget> buildParkedRealmLayers({
    required Size screen,
    required DictionaryPopupController controller,
  }) {
    return parkedRealmPopupLayers(
      parkedRealms: controller.parkedRealms,
      screen: screen,
      isDark:
          (mixinAppModel.overrideDictionaryTheme ?? mixinTheme).brightness ==
          Brightness.dark,
      overrideFillColor: mixinAppModel.overrideDictionaryColor,
    );
  }

  /// [buildNestedPopupLayer] 的 [wrapContent] 应用点：包装只能落在 [Positioned]
  /// **内部**（见该方法的 doc）。null 时原样返回。
  static Widget _wrapPopupContent(
    Widget Function(Widget child)? wrap,
    Widget child,
  ) => wrap == null ? child : wrap(child);

  /// Builds the [Positioned] popup layer widget for the entry at [index] in
  /// [controller].entries.
  ///
  /// [wrapContent] 在**不改变本层顶层类型**的前提下包住浮层内容：返回值必须是
  /// [Positioned]（`parkedPopupLayer` 的 BUG-135 屏外停靠靠它的 left/top），而
  /// [Positioned] 是 `ParentDataWidget<StackParentData>`，要求它与 [Stack] 之间只
  /// 隔 Stateless/Stateful widget。宿主若在**外面**套一层 RenderObject widget
  /// （`MouseRegion` 等），debug 下抛 `Incorrect use of ParentDataWidget`、浮层退化
  /// 成非定位子项画到左上角（热槽屏外停靠一并失效），release 下 `parentData!
  /// as StackParentData` 直接 TypeError。要在浮层上挂 hover 就走这个钩子。
  Widget buildNestedPopupLayer({
    required int index,
    required Size screen,
    required DictionaryPopupController controller,
    required Future<int> Function(
      String text,
      Rect selectionRect,
      List<FushiRubySpan> rubySpans,
    )
    onPush,
    required void Function(int index) onPop,
    // 词头 / 链接 / 汉字点击原地跳转时是否自动朗读首词条（视频页传 true，与其嵌套
    // 查词的 autoRead 同口径；其余宿主默认 false）。
    bool autoReadOnNavigate = false,
    Widget Function(Widget child)? wrapContent,
  }) {
    final DictionaryPopupEntry entry = controller.entries[index];
    // P1-A：本层直接订阅 controller（[DictionaryPopupEntryBinding]）。结果回填 /
    // 挂起翻出 / 自适应高度都只 notify，这一层当帧重建；不再「宿主整页 setState →
    // 宿主 build 尾部 post-frame markNeedsBuild 根 Overlay → 下一帧才推结果」。宿主
    // （视频页 / 首页 / texthooker / 遥控 / 网页视频 / 悬浮歌词 / 复习卡）零改动。
    // BUG-941 的 entry 身份 key 挂在 binding 上（它才是 Stack 的直接子项）。
    return DictionaryPopupEntryBinding(
      key: ObjectKey(entry),
      controller: controller,
      entry: entry,
      builder: () => _buildNestedPopupLayerFor(
        entry: entry,
        index: index,
        screen: screen,
        controller: controller,
        onPush: onPush,
        onPop: onPop,
        autoReadOnNavigate: autoReadOnNavigate,
        wrapContent: wrapContent,
      ),
    );
  }

  Widget _buildNestedPopupLayerFor({
    required DictionaryPopupEntry entry,
    required int index,
    required Size screen,
    required DictionaryPopupController controller,
    required Future<int> Function(
      String text,
      Rect selectionRect,
      List<FushiRubySpan> rubySpans,
    )
    onPush,
    required void Function(int index) onPop,
    required bool autoReadOnNavigate,
    required Widget Function(Widget child)? wrapContent,
  }) {
    // 真实空结果收成「未找到」空态的高度，否则按内容测量（见 layoutAutoFitHeight）。
    final double emptyHeight =
        kLookupPopupEmptyHeight * mixinAppModel.appUiScale;
    final double? fitHeight = entry.layoutAutoFitHeight(
      emptyHeight: emptyHeight,
    );
    final Rect pos = _calcMixinPopupPosition(
      entry.selectionRect,
      screen,
      autoFitHeight: fitHeight,
    );
    // 自适应高度只收外壳，WebView 仍按外壳取最大高度时的正文高度布局、超出裁掉
    // （[DictionaryPopupLayer.webViewOverflowHeight]）：内容增减不再改原生表面尺寸，
    // 杜绝 Windows 上旧尺寸帧被拉伸的那几帧。外壳本就是最大高度时差值为 0。
    final double fullPopupHeight =
        fitHeight == null || _popupBottomDocked || _popupResizePreview != null
        ? pos.height
        : _calcMixinPopupPosition(entry.selectionRect, screen).height;
    final double webViewOverflowHeight = fullPopupHeight > pos.height
        ? fullPopupHeight - pos.height
        : 0.0;
    // Phase B 拖拽尺寸：缓存顶层卡当前 rect/选区，供 [_onMixinPopupResizeStart] 冻结左上角。
    if (index == controller.entries.length - 1) {
      _topPopupSelectionRect = entry.selectionRect;
      _topPopupAnchoredRect = pos;
    }
    final bool isDark =
        (mixinAppModel.overrideDictionaryTheme ?? mixinTheme).brightness ==
        Brightness.dark;
    // BUG-135 parking + Visibility 几何收口在 [parkedPopupLayer]。
    return parkedPopupLayer(
      // BUG-941：搜索占位层消失时本层会在 Stack children 中前移一位。身份 key
      // 已挂在外层 [DictionaryPopupEntryBinding] 上（Stack 的直接子项），元素按
      // entry 身份搬位而不是拆建原生表面。
      pos: pos,
      // 被更上层查词卡盖住的部分裁掉：上层的模糊才采到正文而不是本层面板
      // （[PopupOccluderClip]，玻璃叠玻璃）。
      // 只算已淡入完成的上层（[DictionaryPopupEntry.entranceSettled]）：上层还在
      // 淡入时就挖洞，洞口会透出视频 / 正文（反馈 iZupbhhdNV）。
      occluders: <Rect>[
        for (int j = index + 1; j < controller.entries.length; j++)
          if (controller.entries[j].visible &&
              controller.entries[j].entranceSettled)
            _calcMixinPopupPosition(
              controller.entries[j].selectionRect,
              screen,
              autoFitHeight: controller.entries[j].layoutAutoFitHeight(
                emptyHeight: emptyHeight,
              ),
            ),
      ],
      // BUG-797 / BUG-1040：任何「必须盖住弹窗」的 Flutter 对话框（选择句子上下文 /
      // 已制卡动作 / 打开卡片选择）期间把弹窗停靠屏外，否则原生平台视图盖住对话框。
      visible: entry.visible && !lookupPopupHiddenByDialog,
      // 接替已画出的搜索占位卡时，接着占位卡的淡入进度淡完（不从 0 重来、也不跳满）。
      entranceStartProgress: popupEntranceProgressAfter(
        entry.searchPlaceholderShownFor,
      ),
      onEntranceSettled: (bool settled) {
        if (!mounted || entry.entranceSettled == settled) return;
        setState(() => entry.entranceSettled = settled);
      },
      screen: screen,
      child: _wrapPopupContent(
        wrapContent,
        DictionaryPopupLayer(
          result: entry.result,
          restoreScrollTop: entry.restoreScrollTop,
          isSearching: entry.isSearching,
          keepWebViewWarm: entry.isWarmSlot,
          webViewKey: entry.webViewKey,
          resourceSource: popupResourceSource,
          // TODO-869：本层有后代弹窗时注入 __hasChildPopup，点卡片本体留白才能关子窗。
          hasChildPopup: index < controller.entries.length - 1,
          isDark: isDark,
          overrideFillColor: mixinAppModel.overrideDictionaryColor,
          // dock 面板铺满屏幕左右缘时把圆角摊平，否则边缘露出背景（BUG-2439）。
          bottomDocked: _popupBottomDocked,
          webViewOverflowHeight: webViewOverflowHeight,
          onDismiss: () => onPop(index),
          // BUG-1269：弹窗是原生 WebView，指针落上去后宿主收不到键盘/鼠标——把宿主
          // 声明的那些输入交回来（表由注册表当前绑定实时导出，改键立即跟随）。
          inputSpec: dictionaryPopupInputSpec,
          // BUG-2627：对话框期间（选择句子上下文 / 已制卡动作 / 打开卡片）弹窗
          // 虽被停靠屏外却仍然挂载，DOM 还可能拿着系统键盘焦点——一个被绑的键就
          // 能把对话框**背后**的整条浮层栈关掉（连带清空制卡草稿），而用户在对话
          // 框里什么都看不见。与 barrier（[shouldShowLookupDismissBarrier]）和浮层
          // 可见性（[parkedPopupLayer] 的 `visible`）共用同一道门：对话框期间这条
          // 通道也不许落地。
          onHostInputToken: dictionaryPopupInputScope == null
              ? null
              : (String token) {
                  if (lookupPopupHiddenByDialog) return;
                  onDictionaryPopupInputToken(token);
                },
          // TODO-407②：平台/偏好级"滑动关闭"开关（Windows/Linux 默认 false）。
          enableSwipeToClose: ReaderFushiSource.instance.enableSwipeToClose,
          // BUG-2770：触摸 / 触控笔滑关未设置时所有平台默认开（鼠标仍按上一行）。
          enableTouchSwipeToClose:
              ReaderFushiSource.instance.enableTouchSwipeToClose,
          // TODO-407①：顶层仍渲染"X 关闭"，走既有关闭汇聚点 onPop(0)
          // （清整栈，不破坏 BUG-072 续播 / 清句 / 清栈）。
          onClose: () => onPop(index),
          // TODO-485：嵌套层即便禁用滑动关闭，也有显式返回父层入口。
          onBack: null,
          // 弹窗内原地跳转历史（词头 / 链接 / 汉字点击）：跳过才画 ← →。换页由
          // controller notify，本层经 [DictionaryPopupEntryBinding] 重建。
          historyNav: entry.hasNavigationHistory
              ? DictionaryPopupHistoryNav(
                  canGoBack: entry.canGoBack,
                  canGoForward: entry.canGoForward,
                  onBack: () => navigatePopupHistory(
                    controller: controller,
                    entry: entry,
                    forward: false,
                  ),
                  onForward: () => navigatePopupHistory(
                    controller: controller,
                    entry: entry,
                    forward: true,
                  ),
                )
              : null,
          // Phase B：app 内弹窗右下角尺寸拖拽把手（video/首页/texthooker 共用此收口）。
          // 拖动 = 可视化改「最大宽高」偏好（与设置滑杆同一真值）；预览态在 mixin 级。
          showResizeGrip: true,
          onResizeStart: _onMixinPopupResizeStart,
          onResizeUpdate: _onMixinPopupResizeUpdate,
          onResizeEnd: _onMixinPopupResizeEnd,
          onResizeCancel: _onMixinPopupResizeCancel,
          // TODO-834：点**本层弹窗本体的空白区**只关该层衍生的后代层（index 更大的全部），
          // 保留本层 + 祖先。线性扁平栈里 index 即 depth，故后代 = `index+1..end`，用
          // [DictionaryPopupController.truncateTo] 精确裁。点本层无后代 = no-op 栈不变。
          // 不走 onPop（onPop(0) 是清整栈的会话级路径，仅 barrier / X 用）。
          onTapOutside: () => _dismissDescendantsOfLayer(index, controller),
          // TODO-058：该层 WebView 渲染完成 → 翻可见挂起的冷层（消除白屏一瞬）。
          // 仅当此层处于挂起态（markPendingReveal）才真翻可见并触发重建。
          onRendered: () {
            if (!mounted) return;
            if (controller.revealRendered(entry)) {
              controller.endSearchUi();
              setState(() {});
            }
            // 选词光标跟随（videoEnterCaret）：层渲染完成后交给页面钩子，视频页据此
            // 把光标 transfer 进刚显示的顶层弹窗（BaseSourcePageState 家族的
            // onDictionaryPopupRendered 同语义；mixin 家族此前没有该钩子）。
            onNestedPopupRendered(index);
          },
          onContentMetrics: (double contentHeight, double viewportHeight) {
            if (!mounted ||
                !controller.entries.contains(entry) ||
                _popupBottomDocked ||
                _popupResizePreview != null) {
              return;
            }
            final double preferredMaxHeight =
                mixinAppModel.popupMaxHeight * mixinAppModel.appUiScale;
            // JS 上报的视口是 WebView 的布局高度，对应的外壳是
            // [fullPopupHeight]（WebView 按它布局），不是裁剪后的 pos.height。
            final double nextHeight = resolveAutoFitPopupHeight(
              currentPopupHeight: fullPopupHeight,
              contentHeight: contentHeight,
              viewportHeight: viewportHeight,
              minHeight: kLookupPopupMinHeight * mixinAppModel.appUiScale,
              maxHeight: preferredMaxHeight,
            );
            if ((nextHeight - (entry.autoFitHeight ?? pos.height)).abs() < 1) {
              return;
            }
            // P1-D：只 notify controller，本层（[DictionaryPopupEntryBinding]）与
            // 下层的遮挡裁剪就地重建；不再整页 setState。
            controller.setAutoFitHeight(entry, nextHeight);
          },
          // TODO-058 fail-safe：WebView 加载失败也走同一翻可见路径（不卡死）。
          onRenderError: () {
            if (!mounted) return;
            if (controller.revealRendered(entry)) {
              controller.endSearchUi();
              setState(() {});
            }
          },
          onScrolledToBottom: entry.allLoaded
              ? null
              : () => loadMoreForEntry(entry: entry, controller: controller),
          onTextSelected: (text, localRect, rubySpans) async {
            final Rect childRect = localRect == Rect.zero
                ? entry.selectionRect
                : popupWordScreenRect(
                    webViewKey: entry.webViewKey,
                    localRect: localRect,
                    fallback: entry.selectionRect,
                  );
            setState(() => controller.truncateTo(index + 1));
            // TODO-1190: after the child search, mark the clicked word in THIS
            // (parent) card's WebView (parity with base_source_page reader family
            // — the mixin family video/首页/texthooker only truncate+onPush before,
            // so the source word was left unmarked). onPush returns the matched
            // char count (0 = no entries -> no highlight, preserving prior look).
            final int count = await onPush(text, childRect, rubySpans);
            if (count > 0) {
              final Rect? wordRect = await entry.webViewKey.currentState
                  ?.highlightSelection(count);
              // BUG-2054：同一次高亮顺带取回整词 bbox，把刚打开的子层从「点击的首
              // 字符」重锚到整词矩形——跨行选区时首字符矩形只覆盖第一行，子弹窗会
              // 正好盖住选区的第二行。expectedTerm 是身份门：eval 往返期间用户再点
              // 一个词时，同一下标上会是另一个词的子层（beginTop 同步压栈）。
              // reanchorEntry 自己 notify，子层经 [DictionaryPopupEntryBinding] 就地
              // 重定位，不必整页重建。
              if (mounted) {
                reanchorNestedPopupToWord(
                  controller: controller,
                  parentWebViewKey: entry.webViewKey,
                  parentIndex: index,
                  expectedTerm: text,
                  wordLocalRect: wordRect,
                  fallback: childRect,
                );
              }
            }
          },
          // 词头 / 交叉引用链接 / 汉字（onLinkClick 通道）：**原地跳转**而不是叠一层
          // 子弹窗——对齐 Hoshi Reader iOS（`lookupRedirect` → `redirect(count)`：
          // 同一个 WebView 换内容，← → 在历史页间来回）。释义正文点词（onTextSelected）
          // 仍叠子层，也与 Hoshi 一致（那边 `textSelected` 走 `popups.append`）。
          onLinkClick: (query, localRect) => navigatePopupInPlace(
            controller: controller,
            index: index,
            entry: entry,
            query: query,
            autoRead: autoReadOnNavigate,
          ),
          // 制卡四个出口都先过 [miningFieldsForLayer]：宿主按层补上它知道的上下文
          // （主窗查词宿主补出自那一行原文的例句，反馈 1Mwaro8UTC）。
          onMineEntry: closePopupAfterAcceptedMine(
            (Map<String, String> fields) =>
                onMineEntry(miningFieldsForLayer(index, controller, fields)),
            enabled: () => ReaderFushiSource.instance.closePopupAfterMining,
            closeAll: () {
              if (mounted) onPop(0);
            },
          ),
          onUpdateEntry: (int noteId, Map<String, String> fields) =>
              onUpdateEntry(
                noteId,
                miningFieldsForLayer(index, controller, fields),
              ),
          // BUG-3652 续：制卡失败回包回来时这一层已关 / 停驻，原因就改由宿主 toast。
          isSessionOnScreen: () => controller.isEntryOnScreen(entry),
          // 用户建议 #fiwDIpFep7：顶栏就地切配置 / 牌组，随制卡模块开关。结果来自
          // 别的设备（[popupResourceSource] 非 null，如手机遥控电脑制卡）时卡片落在
          // 那台设备、用它的 Anki 配置，本机的切换对卡片不起作用，不显示。
          showMiningTargetSwitch:
              mixinAppModel.moduleVisibility.isEnabled(ModuleId.cardCreation) &&
              popupResourceSource == null,
          onDuplicateCheck: checkDuplicate,
          onOverwriteTargetNoteId: findOverwriteTargetNoteId,
          onMinedCardAction: (Map<String, String> fields) => onMinedCardAction(
            miningFieldsForLayer(index, controller, fields),
          ),
          onQueueOverwrite: (Map<String, String> fields) =>
              onQueueOverwrite(miningFieldsForLayer(index, controller, fields)),
          onOpenInAnki: onOpenInAnki,
          onFavoriteEntry: onFavoriteEntry,
          onFavoriteCheck: onFavoriteCheck,
          // TODO-270 E：支持草稿的表面（视频覆写 [onAppendSentenceToDraft] 返回非空）
          // 才传回调 → popup 渲染「+句」累积；其余（纯查词/首页词典）传 null 不渲染。
          onAppendSentence: onAppendSentenceToDraft,
          onSetSentenceContext: onSetSentenceContextToDraft,
          onClearSentenceDraft: onClearSentenceDraftToDraft,
          // 「高级制卡」：点某词条的「高级制卡」→ 弹 app 原生顶层对话框（BUG-763/766：
          // 不画在弹窗 WebView 内）；确认制卡回该层 WebView 精确点中该词条的「+」并带上
          // 覆盖项。只跟制卡模块走——纯查词页也有（对话框只有卡组分区）。
          onOpenAdvancedMining:
              mixinAppModel.moduleVisibility.isEnabled(ModuleId.cardCreation)
              ? (int entryIndex, String matched, String expression) =>
                    _openAdvancedMiningDialog(
                      webViewKey: entry.webViewKey,
                      entryIndex: entryIndex,
                      matched: matched,
                      expression: expression,
                    )
              : null,
          headerWidget: buildPopupHeaderFor(index),
          topBarScale: dictionaryPopupTopBarScale(
            appUiScale: mixinAppModel.appUiScale,
            dictionaryFontSize: mixinAppModel.dictionaryFontSize,
          ),
        ),
      ),
    );
  }

  /// 搜索期加载占位卡（「搜索→就绪才显示」模式）：在选中词 [rect] 处画一张与弹窗
  /// 同色的小卡 + 顶部进度条，全程不露空 WebView（与书内 base_source_page 同观感）。
  /// 宿主在 [DictionaryPopupController.isSearchingUi] 为真时渲染。
  ///
  /// BUG-1364（BUG-797/1040/1327 同族遗留）：本层此前**没接** [_popupHidingDialogDepth]。
  /// 三个走根 Overlay 的宿主（视频页 / 首页词典页 / texthooker）+ 常驻根 builder 的
  /// 悬浮歌词 host，整棵浮层子树都排在 `showAppDialog` 推的路由**之上**，所以对话框
  /// 打开期间浮层的三个组成部分必须一起让位：barrier（[shouldShowLookupDismissBarrier]）、
  /// 弹窗层（[parkedPopupLayer] 的 `visible`）都已接线，只剩这张占位卡漏了 → 对话框
  /// 期间只要再起一次**顶层**查词（[DictionaryPopupController.beginTop] 会把复用的热槽
  /// / 新目标置 `visible=false`，于是 `hasVisiblePopup` 变假、[pushNestedPopup] 进搜索
  /// 占位态），这张不透明小卡就画在对话框上面。异步触发真实存在：悬浮歌词是独立系统
  /// 窗口、texthooker / 全局查词的文本来自 app 外，都不受对话框模态遮罩约束。
  ///
  /// 与弹窗层不同，本层是**纯 Flutter widget**（无原生平台视图），故不需要
  /// [parkedPopupLayer] 的「停靠屏外」补偿——那套几何只为绕开平台视图无视 `Opacity` /
  /// `IgnorePointer` 的 airspace 行为。这里 [Visibility] 即可真正让位（不画、不吃点击），
  /// 且外层 [Positioned] 尺寸不变，宿主 Stack 的子项数与布局都不受影响。
  Widget buildPopupLoadingPlaceholder({
    required Rect rect,
    required Size screen,
  }) {
    final Rect pos = _calcMixinPopupPosition(rect, screen);
    final ColorScheme cs =
        (mixinAppModel.overrideDictionaryTheme ?? mixinTheme).colorScheme;
    final Color fill = mixinAppModel.overrideDictionaryColor ?? cs.surface;
    return Positioned(
      // 占位层的稳定 key（与弹窗层的 `ObjectKey(entry)` 配套，对齐 reader 车道的
      // `base-source-popup-loading-placeholder`）：barrier 插拔时 Stack 里的子项按 key
      // 匹配，占位层与弹窗层不会被按位置错配成对方（BUG-941 同族）。
      key: kLookupSearchPlaceholderKey,
      left: pos.left,
      top: pos.top,
      width: pos.width,
      height: pos.height,
      child: Visibility(
        // BUG-1364：与 [parkedPopupLayer] 的 `visible` 同源，纳入同一个嵌套安全计数。
        visible: !lookupPopupHiddenByDialog,
        child: popupEntranceFade(
          // 查询中：卡壳先铺上，加载指示器 150ms 后才露出（快查询不闪转圈）；
          // 绝不画「未找到」——那只属于查完为空的结果。
          child: FushiPopupSurface(
            color: fill,
            child: FushiDeferredLoading(active: true, color: cs.primary),
          ),
        ),
      ),
    );
  }

  /// Searches [query] and opens a popup via [controller].
  ///
  /// Top-level lookups ([replaceStack] or [reuseWarmSlot]) reuse the warm slot /
  /// replace the stack; otherwise a nested child layer is pushed. The mixin
  /// All surfaces use the reader's model — **search → reveal only when results
  /// are ready** ([revealWhileSearching] `false`): the popup target stays hidden
  /// during the lookup and the host paints a lightweight loading placeholder at
  /// [DictionaryPopupController.pendingRect] (see [buildPopupLoadingPlaceholder]),
  /// so a blank/cold WebView is never shown. (Set [revealWhileSearching] `true`
  /// to keep the old reveal-during-search behaviour.) If [autoRead] is true and
  /// results are found, the first entry's audio is played automatically.
  Future<int> pushNestedPopup({
    required String query,
    required Rect selectionRect,
    required DictionaryPopupController controller,
    bool replaceStack = false,
    bool autoRead = false,
    bool reuseWarmSlot = false,
    bool revealWhileSearching = false,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return 0;
    // [rubySpans] 以 [query] 为坐标系：跟着去掉的句首空白平移。
    final List<FushiRubySpan> trimmedRuby = shiftRubySpans(
      rubySpans,
      leadingStrip: query.length - query.trimLeft().length,
      length: trimmed.length,
    );
    // 诊断（2026-09-22，用户：查词为什么卡）：一次查词从这里开始计时，直到弹窗真翻
    // 可见（或被兜底强制翻可见）为止。各阶段的毫秒数是区分「FFI 慢 / WebView 冷建慢
    // / 注入慢 / JS 渲染慢」的唯一依据——此前整条链路一个时间戳都没有。诊断关闭时
    // [LookupPerfTrace.begin] 返回 null，全链路一路 `?.`，零开销。
    final LookupPerfTrace? trace = LookupPerfTrace.begin(
      term: trimmed,
      host: lookupDiagHost,
      lowMemory: controller.lowMemory,
    );
    final int maxTerms = mixinAppModel.maximumTerms;
    final Rect rect = fallbackSelectionRect(selectionRect);
    final DictionaryPopupEntry entry = controller.beginTop(
      term: trimmed,
      rect: rect,
      reuseWarmSlot: reuseWarmSlot,
      replaceStack: replaceStack,
      visible: revealWhileSearching,
      rubySpans: trimmedRuby,
      // 搜索期占位用与热槽 seed / DictionaryPopupLayer 兜底**同一个**单例：
      // 不传时 entry.result 为 null → 本帧 WebView 的 widget.result 落到
      // `result ?? kPopupSearchingPlaceholderResult` 兜底，但热槽停驻期的 seed
      // 若是另一个空结果实例，空→空的身份变化仍触发 didUpdateWidget 全量
      // renderPopup（先整卡画一遍 no-results，结果到达再画真内容——每次查词双倍
      // WebView 渲染）。单例恒等让搜索期 didUpdateWidget 天然 no-op，只在
      // fillResult 换成真结果时推一次。加载盖板仍由 isSearching 驱动，观感不变。
      initialResult: kPopupSearchingPlaceholderResult,
    );
    // 搜索期占位卡只在「顶层」查词时进入——与 reader base_source_page 的
    // `searching && !hasVisiblePopup` 门控对齐。嵌套查词时父弹窗仍可见，而三个 mixin
    // 宿主（video / 首页 / 悬浮歌词）的 Stack 里加载占位卡排在 entries **之前** =
    // 画在父弹窗**下方图层**，只从父弹窗底边露出一条，等子层 WebView 渲染完才在顶层
    // 翻出 → 用户看到「子弹窗先在底层、渲染后跳到上层」的层级翻转（BUG-715）。有可见
    // 弹窗时不进搜索占位态：父弹窗全程提供上下文，子层就绪即 markPendingReveal→
    // revealRendered 直接在顶层出现，无层级翻转（reveal 时序仍受 BUG-170 保护）。
    if (!controller.hasVisiblePopup) {
      // 传目标 entry：盖板态由「这条 entry 仍在栈内且仍 searching/待翻出」派生，
      // 关栈路径清掉它就自动落幕，不再依赖某条成功路径记得调 endSearchUi。
      controller.beginSearchUi(rect, entry);
    }
    // 栈结构 / 搜索占位态变了：barrier 与占位卡由宿主的根 Overlay builder 画，这一次
    // 宿主重建省不掉。结果回填与翻出则只 notify controller（见 [buildNestedPopupLayer]）。
    setState(() {});
    // 本次查词会话的代次（P1-A 附）：热槽复用时新旧查词是**同一个** entry，只核
    // `entries.contains` 会让慢回来的旧结果（远程查词真异步）覆盖新词。
    final int generation = entry.lookupGeneration;
    bool isCurrent() =>
        mounted && controller.isCurrentLookup(entry, generation);
    late final DictionarySearchResult result;
    try {
      result = await searchPopupDictionary(
        term: trimmed,
        maximumTerms: maxTerms,
        rubySpans: trimmedRuby,
      );
      // 词典查询（三级缓存 → FFI）到此为止。小内存模式把 popupJson 缓存砍到 2MB、
      // ffiLookup 砍到 8MB，重复查词的命中率随之下降、这一段会更常真跑 FFI——所以条目
      // 数与耗时都要记。
      trace?.mark(
        'search',
        detail:
            'entries=${result.entries.length} '
            'kanji=${result.kanjiResults.length} '
            'truncated=${result.truncated}',
      );
      if (isCurrent()) {
        // P1-A：不再包宿主 setState。fillResult / markPendingReveal 都 notify，本层
        // （[DictionaryPopupEntryBinding]）当帧重建、把结果推进 WebView。
        controller.fillResult(
          entry,
          result: result,
          allLoaded: !result.truncated,
        );
        // TODO-058 / BUG-480：真实空结果走 Flutter 占位，可立即显示；有词条/汉字卡
        // 的结果必须等当前 WebView render 信号，哪怕复用 warm slot。macOS 隐藏
        // warm slot 可能漏掉当前结果注入，直显会露出空白 WebView 壳。
        final bool needsWebViewRender =
            result.entries.isNotEmpty || result.kanjiResults.isNotEmpty;
        trace?.mark('fill', detail: 'webview-render=$needsWebViewRender');
        if (!needsWebViewRender) {
          // 空结果走 Flutter 占位直显，链路到此结束（不经 WebView，故没有 rendered
          // / reveal 两段）——这条也要收尾，否则游标会挂着不放。占位卡随 finally 的
          // endSearchUi 撤，宿主重建在那里统一做。
          controller.show(entry);
          trace?.finish('empty');
        } else {
          // TODO-058 fail-safe：超时强制翻可见时本层随 notify 重建；占位卡与 barrier
          // 在宿主的 Overlay builder 里，仍要宿主重建一次（守 mounted，Timer 后触发）。
          controller.markPendingReveal(
            entry,
            onForcedReveal: () {
              controller.endSearchUi();
              if (mounted) setState(() {});
            },
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!isCurrent() || !entry.revealOnRender) return;
            // refreshCurrentResult 已去重（同一结果不再全量重推）：返回 false
            // 表示当前结果已渲染完成、popupRendered 不会再来——立即走与
            // onRendered 相同的翻可见路径，不空等 failsafe。state 为 null 时
            // 维持等待，交给 failsafe。
            final bool renderPending =
                entry.webViewKey.currentState?.refreshCurrentResult() ?? true;
            if (!renderPending && controller.revealRendered(entry)) {
              controller.endSearchUi();
              setState(() {});
            }
          });
          // 回填不再经宿主 setState，帧调度不能指望它：确保上面的 post-frame 回调有
          // 一帧可跑（markPendingReveal 的 notify 通常已排了帧，这里只是不依赖它）。
          WidgetsBinding.instance.ensureVisualUpdate();
        }
      }
    } finally {
      // 只在真有东西要变时才重建宿主：成功且挂起等渲染的常态路径（isSearching 已被
      // fillResult 清掉、revealOnRender=true）什么都不用做——这正是省掉的那次整页重建。
      // 空结果（占位卡要撤）与异常（isSearching 仍为 true）两条路仍要宿主重建。
      if (isCurrent() && (entry.isSearching || !entry.revealOnRender)) {
        setState(() {
          entry.isSearching = false;
          if (!entry.revealOnRender) {
            controller.endSearchUi();
          }
        });
      }
    }
    if (!isCurrent()) {
      // 页面已卸载 / 该层已被裁掉 / 该层已被新一次查词接管（热槽复用）：这次查词
      // 没有结局，如实收尾成 abandoned，不要让游标悬着把后续查词的阶段记到这一条上。
      trace?.finish('abandoned');
      return 0;
    }
    if (result.entries.isNotEmpty) {
      mixinAppModel.addToSearchHistory(
        historyKey: DictionaryMediaType.instance.uniqueKey,
        searchTerm: trimmed,
      );
      mixinAppModel.addToDictionaryHistory(result: result);
      if (autoRead && ReaderFushiSource.instance.autoReadOnLookup) {
        final first = result.entries.first;
        if (first.word.isNotEmpty) {
          autoReadWord(
            first.word,
            first.reading,
            popupState: entry.webViewKey.currentState,
          );
        }
      }
    }
    // TODO-1190: matched char count so the caller (buildNestedPopupLayer's
    // onPush) can highlight the searched word in the PARENT card. 0 when no
    // entries matched — the caller then skips the highlight (unchanged look).
    return lookupHighlightCharCount(
      result: result,
      searchTerm: trimmed,
      language: JapaneseLanguage.instance,
    );
  }

  Future<void> loadMoreForEntry({
    required DictionaryPopupEntry entry,
    required DictionaryPopupController controller,
  }) async {
    if (entry.allLoaded || entry.isSearching || entry.result == null) return;
    // BUG-1478：按词头递增（见 base_source_page 同处注释）。
    final int current = entry.result!.headwordCount;
    final int newMax = current + mixinAppModel.maximumTerms;
    final String term = entry.searchTerm;
    // 续查是同一个查询扩大上限：带着首查那组来源振假名，读音排序才不会在整份替换时丢掉。
    final List<FushiRubySpan> rubySpans = entry.rubySpans;
    final int generation = entry.lookupGeneration;
    setState(() => entry.isSearching = true);
    try {
      final DictionarySearchResult result = await searchPopupDictionary(
        term: term,
        maximumTerms: newMax,
        rubySpans: rubySpans,
      );
      // 原地跳转 / 后退 / 前进 / 热槽换词都会在同一个 entry 上换词：会话代次变了
      // （或词变了）就丢弃这批续查结果。
      if (mounted &&
          controller.isCurrentLookup(entry, generation) &&
          entry.searchTerm == term) {
        setState(
          () => controller.fillResult(
            entry,
            result: result,
            allLoaded: !result.truncated,
          ),
        );
      }
    } finally {
      if (mounted && controller.entries.contains(entry) && entry.isSearching) {
        setState(() => entry.isSearching = false);
      }
    }
  }

  /// Pops the popup at [index] via [controller] (index 0 hides-and-keeps any
  /// warm slot / clears otherwise; deeper indices drop that layer and above).
  void popNestedPopupAt(int index, DictionaryPopupController controller) {
    if (index < 0 || index >= controller.entries.length) return;
    setState(() => controller.dismissAt(index));
  }

  /// TODO-834：关闭第 [index] 层**衍生的所有后代层**（index 更大的全部），保留本层
  /// + 祖先。线性扁平栈里 index 即 depth、无分叉，故后代 = `index+1..end`，用
  /// [DictionaryPopupController.truncateTo] 精确裁。点最顶层（无后代）= no-op 栈不变。
  /// 弹窗内原地跳转（词头 / 交叉引用链接 / 汉字点击）：先裁掉 [index] 之上的子层，
  /// 查 [query]，**有结果才**把 [entry] 当前页压进后退栈、在同一个 WebView 里换成
  /// 新词（Hoshi iOS：`if (count > 0) redirect(count)`，空结果什么都不发生，弹窗
  /// 不动）。弹窗位置 / 尺寸都不变：selectionRect 保留，外壳高度由新内容的
  /// onContentMetrics 再伸缩。与 [BaseSourcePageState.navigatePopupInPlace] 同语义
  /// （换页由 controller notify，本层经 [DictionaryPopupEntryBinding] 重建）。
  ///
  /// 身份门：查询往返期间本层可能被关掉（`entries.contains`）或已被另一次跳转 /
  /// 顶层换词换掉内容（`searchTerm` 变了）——迟到的结果一律丢弃。查询期间置
  /// [DictionaryPopupEntry.isSearching] 挡住同层 load-more 并发写入。
  Future<void> navigatePopupInPlace({
    required DictionaryPopupController controller,
    required int index,
    required DictionaryPopupEntry entry,
    required String query,
    bool autoRead = false,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty || entry.isSearching) return;
    if (controller.entries.length > index + 1) {
      setState(() => controller.truncateTo(index + 1));
    }
    // 离开当前页前记下它的滚动位（回来时恢复）；查询开始后再读会读到新内容。
    final double scrollTop =
        await entry.webViewKey.currentState?.currentScrollTop() ?? 0;
    if (!mounted || !controller.entries.contains(entry)) return;
    final String termAtStart = entry.searchTerm;
    entry.isSearching = true;
    try {
      final DictionarySearchResult result = await searchPopupDictionary(
        term: trimmed,
        maximumTerms: mixinAppModel.maximumTerms,
      );
      if (!mounted ||
          !controller.entries.contains(entry) ||
          entry.searchTerm != termAtStart) {
        return;
      }
      if (result.entries.isEmpty && result.kanjiResults.isEmpty) return;
      mixinAppModel.addToSearchHistory(
        historyKey: DictionaryMediaType.instance.uniqueKey,
        searchTerm: trimmed,
      );
      mixinAppModel.addToDictionaryHistory(result: result);
      // navigateInPlace 自己 notify，本层经 [DictionaryPopupEntryBinding] 重建。
      controller.navigateInPlace(
        entry,
        term: trimmed,
        result: result,
        allLoaded: !result.truncated,
        scrollTop: scrollTop,
      );
      if (autoRead &&
          ReaderFushiSource.instance.autoReadOnLookup &&
          result.entries.isNotEmpty) {
        final DictionaryEntry first = result.entries.first;
        if (first.word.isNotEmpty) {
          autoReadWord(
            first.word,
            first.reading,
            popupState: entry.webViewKey.currentState,
          );
        }
      }
    } finally {
      // navigateInPlace 成功路径已清 isSearching；失败 / 提前 return 在此兜底复位。
      if (mounted && controller.entries.contains(entry) && entry.isSearching) {
        setState(() => entry.isSearching = false);
      }
    }
  }

  /// 顶栏 ← / →：在 [entry] 的原地跳转历史里后退 / 前进一页。先记当前页滚动位
  /// （再往回走时恢复），换页由 controller notify 驱动本层重建：WebView 按 result
  /// 身份重推、渲染完恢复该页滚动位。
  Future<void> navigatePopupHistory({
    required DictionaryPopupController controller,
    required DictionaryPopupEntry entry,
    required bool forward,
  }) async {
    if (entry.isSearching) return;
    final double scrollTop =
        await entry.webViewKey.currentState?.currentScrollTop() ?? 0;
    if (!mounted || !controller.entries.contains(entry)) return;
    // goForward / goBack 自己 notify，本层经 [DictionaryPopupEntryBinding] 重建。
    if (forward) {
      controller.goForward(entry, scrollTop: scrollTop);
    } else {
      controller.goBack(entry, scrollTop: scrollTop);
    }
  }

  /// 与基类 [BaseSourcePageState] 的同名 helper 同语义（mixin 路径不监听 controller，
  /// 故显式 setState 重建）。
  void _dismissDescendantsOfLayer(
    int index,
    DictionaryPopupController controller,
  ) {
    if (index < 0 || index >= controller.entries.length - 1) return; // 无后代
    setState(() => controller.truncateTo(index + 1));
  }

  /// 某弹窗层 WebView 渲染完成（reveal 之后）的可覆写钩子——mixin 家族版的
  /// [BaseSourcePageState.onDictionaryPopupRendered]。视频页覆写它把选词光标
  /// transfer 进刚显示的顶层弹窗（videoEnterCaret）；不覆写 = 历史行为不变。
  void onNestedPopupRendered(int index) {}
}
