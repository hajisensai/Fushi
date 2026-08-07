import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 悬浮字幕「点词查词」的一次请求（文本 + 命中字符 index）。
class FloatingLyricLookupRequest {
  const FloatingLyricLookupRequest({required this.text, required this.index});

  final String text;
  final int index;
}

/// 进程级悬浮字幕查词请求总线（单例 [ChangeNotifier]）。
///
/// 根因（TODO-354 ①）：桌面悬浮字幕条是独立 native 窗口，点词必须路由回主窗口的
/// in-app 词典弹窗（无第二个 Flutter engine）。reader 在场时由 reader 自己的弹窗
/// 宿主处理；但书架/首页开的悬浮字幕**没有 reader**，[AudiobookSession] 的 app 级
/// 默认 `onFloatingLyricLookup` 历史上是 no-op（点词被忽略）。
///
/// 这个总线让 app 级默认 handler 把点词请求推过来，由常驻在主窗口（[main.dart] 根
/// builder）的 [FloatingLyricLookupHost] 消费并弹查词——不依赖进任何书。reader attach
/// 时仍覆盖成 reader 的弹窗查词，本总线在 reader 路径下不被触发。
class FloatingLyricLookupNotifier extends ChangeNotifier {
  FloatingLyricLookupNotifier._();

  static final FloatingLyricLookupNotifier instance =
      FloatingLyricLookupNotifier._();

  FloatingLyricLookupRequest? _pending;

  /// 最近一次未消费的查词请求（host 读后调 [consume] 清空）。
  FloatingLyricLookupRequest? get pending => _pending;

  /// 推一次点词请求（app 级默认 handler 调）。空白文本忽略。
  void requestLookup(String text, int index) {
    if (text.trim().isEmpty) return;
    _pending = FloatingLyricLookupRequest(text: text, index: index);
    notifyListeners();
  }

  /// host 消费一次请求（取出后清空，避免重建时重复弹）。
  FloatingLyricLookupRequest? consume() {
    final FloatingLyricLookupRequest? req = _pending;
    _pending = null;
    return req;
  }

  @visibleForTesting
  void debugReset() {
    _pending = null;
  }
}

/// 常驻主窗口的悬浮字幕查词弹窗宿主（TODO-354 ①）。
///
/// 挂在 [main.dart] 根 builder 的 Stack 顶层，覆盖任意页面。监听
/// [FloatingLyricLookupNotifier]：收到点词请求时按命中字 index 分词，经
/// [DictionaryPageMixin.pushNestedPopup] 弹查词浮层（与独立查词页 / texthooker 同款
/// 弹窗引擎，复用同一套 mining / 收藏 / 自动发音逻辑）。首次查词后保留常驻隐藏
/// 热槽（停屏外预热，BUG-094）；无可见弹窗时 [IgnorePointer] 全透传（判据
/// [FloatingLyricLookupHost.shouldBlockHitTest]），不抢任何页面的命中测试。
class FloatingLyricLookupHost extends ConsumerStatefulWidget {
  const FloatingLyricLookupHost({super.key});

  /// 本 host 是否应参与命中测试（拦截页面/悬浮歌词的点击）。
  ///
  /// 热槽常驻（[DictionaryPopupController.seedWarmSlot]）后 `entries` 永不空，
  /// 不能再用 `entries.isNotEmpty` 当判据——那会让隐藏热槽把整层 [IgnorePointer]
  /// 永久翻成可命中，吃掉底下所有点击。判据 = 搜索期占位在显示，或存在**可见**
  /// 弹窗层；隐身热槽（visible=false，停屏外预热）不算。
  ///
  /// **有意不接** [DictionaryPageMixin.lookupPopupHiddenByDialog]（BUG-797/1040/1327/1364
  /// 同族收口时逐条复核过）：本判据与那四处**极性相反**。那四处（弹窗层 `visible`、
  /// 整屏 dismiss barrier、搜索期占位卡）都是「往树里放一个会画、会吃点击的东西」，漏接
  /// 计数 = 对话框被盖住/点不着；而这里 `true` 只是把外层 [IgnorePointer] 的 `ignoring`
  /// 翻成 **false**，即「不强制忽略」——它本身不拦截任何东西，拦截与否完全由子项决定。
  /// 对话框期间本层的两个子项都已让位：弹窗层经 [parkedPopupLayer] 停到屏外
  /// （`screen.width + 8`，连安卓原生平台视图也够不着），占位卡经 [Visibility] 收成零尺寸，
  /// Stack 自身 `hitTestSelf` 恒假 ⇒ 点击照常穿到底下页面。给这里再与一次计数是纯粹的
  /// 对称性改动，不产生任何可观测差异，故不改（行为证据见
  /// `test/media/audiobook/floating_lyric_lookup_host_test.dart` 的「对话框期间点击穿透」）。
  static bool shouldBlockHitTest(DictionaryPopupController popup) =>
      popup.isSearchingUi || popup.hasVisiblePopup;

  @override
  ConsumerState<FloatingLyricLookupHost> createState() =>
      _FloatingLyricLookupHostState();
}

class _FloatingLyricLookupHostState
    extends ConsumerState<FloatingLyricLookupHost> with DictionaryPageMixin {
  final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );

  /// 缓存的 [AppModel] 引用（单例，实例不变）。在 [initState] 一次性读取：浮层在
  /// `LayoutBuilder` 回调里访问 `mixinAppModel`，widget 失活后再 `ref.read` 会抛
  /// 「deactivated widget's ancestor」（与 texthooker / 视频页同源），缓存实例规避。
  late final AppModel _appModel = ref.read(appProvider);

  final FloatingLyricLookupNotifier _notifier =
      FloatingLyricLookupNotifier.instance;

  @override
  AppModel get mixinAppModel => _appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  void initState() {
    super.initState();
    _notifier.addListener(_onLookupRequested);
    // TODO-1204：接线查词计数（每次查词 +1 → lookup_mining_counters）。
    attachLookupCounter(_popup);
  }

  @override
  void dispose() {
    _notifier.removeListener(_onLookupRequested);
    _popup.dispose();
    super.dispose();
  }

  void _onLookupRequested() {
    if (!mounted) return;
    final FloatingLyricLookupRequest? req = _notifier.consume();
    if (req == null) return;
    _lookup(req);
  }

  /// 确保常驻热槽已 seed（对齐视频页 `_seedWarmPopup` 成例，BUG-094）：此前本表面
  /// 从不 seed 且每次查词 `replaceStack` 清栈重建，[DictionaryPopupWebView] 每次都
  /// 冷载 popup.html + JS + CSS。seed 后热槽 WebView 只冷载一次、全程复用。
  ///
  /// 不能在 [initState] 做：本 host 常驻 main.dart 根 builder，挂载时
  /// [AppModel.initialise] 可能尚未完成（过早读 [AppModel.lowMemoryMode] 会因
  /// prefsRepo 未就绪抛错）；而查词请求必然来自有声书会话（app 已初始化），首次
  /// 查词请求即最早的安全 seed 时机。[DictionaryPopupController.seedWarmSlot]
  /// 幂等（已有条目 / 低内存直接 no-op），每次查词前调无副作用。
  void _ensureWarmPopup() {
    _popup.lowMemory = _appModel.lowMemoryMode;
    _popup.seedWarmSlot();
  }

  void _lookup(FloatingLyricLookupRequest req) {
    final String trimmed = req.text.trim();
    if (trimmed.isEmpty) return;
    _ensureWarmPopup();
    final String word = JapaneseLanguage.instance
        .wordFromIndex(text: req.text, index: req.index)
        .trim();
    final String searchTerm = word.isNotEmpty ? word : trimmed;
    // 无 WebView 选区可定位，用屏幕中心 1×1 选区兜底（与 reader 的
    // _lookupFromFloatingLyric / 歌词模式同款）；底部固定模式时 mixin 自走 dock。
    final Size screen = MediaQuery.sizeOf(context);
    final Rect selectionRect = Rect.fromCenter(
      center: Offset(screen.width / 2, screen.height / 2),
      width: 1,
      height: 1,
    );
    pushNestedPopup(
      query: searchTerm,
      selectionRect: selectionRect,
      controller: _popup,
      replaceStack: true,
      // BUG-094：顶层查词原地复用常驻热槽（预热 WebView 直接查新词，不再每次
      // 冷载）；低内存无热槽时经 replaceStack 走清栈重建的旧路径。
      reuseWarmSlot: true,
      autoRead: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    // 判据见 [FloatingLyricLookupHost.shouldBlockHitTest]：热槽常驻后 entries 永不
    // 空，必须按「可见弹窗/搜索占位」判定，否则本层永久吃掉底下页面与悬浮歌词点击。
    final bool hasPopups = FloatingLyricLookupHost.shouldBlockHitTest(_popup);
    // 无可见弹窗时整层 IgnorePointer + 空，绝不抢任何页面的命中测试。
    return IgnorePointer(
      ignoring: !hasPopups,
      child: Stack(
        // BUG-135：隐藏热槽经 [parkedPopupLayer] 停在屏幕右外侧 (screen.width+8)
        // 保活预热，默认 hardEdge 会把它裁掉（原生 WebView 失温、每次查词重新冷载），
        // 必须 Clip.none（与 base_source_page.buildDictionary 的 Stack 同款）。
        clipBehavior: Clip.none,
        children: <Widget>[
          if (_popup.isSearchingUi && _popup.pendingRect != null)
            buildPopupLoadingPlaceholder(
              rect: _popup.pendingRect!,
              screen: screen,
            ),
          for (int i = 0; i < _popup.entries.length; i++)
            buildNestedPopupLayer(
              index: i,
              screen: screen,
              controller: _popup,
              onPush: (String text, Rect rect) => pushNestedPopup(
                query: text,
                selectionRect: rect,
                controller: _popup,
              ),
              onPop: (int index) => popNestedPopupAt(index, _popup),
            ),
        ],
      ),
    );
  }
}
