import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

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
/// 弹窗引擎，复用同一套 mining / 收藏 / 自动发音逻辑）。无挂起请求时不渲染任何层
/// （[IgnorePointer] 全透传，不抢任何页面的命中测试）。
class FloatingLyricLookupHost extends ConsumerStatefulWidget {
  const FloatingLyricLookupHost({super.key});

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

  void _lookup(FloatingLyricLookupRequest req) {
    final String trimmed = req.text.trim();
    if (trimmed.isEmpty) return;
    final String word = _appModel.targetLanguage
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
      autoRead: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final bool hasPopups = _popup.isSearchingUi || _popup.entries.isNotEmpty;
    // 无弹窗时整层 IgnorePointer + 空，绝不抢任何页面的命中测试。
    return IgnorePointer(
      ignoring: !hasPopups,
      child: Stack(
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
