import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/lookup/lookup_overlay_navigator.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 能把查词弹窗栈画进 [SharedLookupPopupHost] 根 Overlay 浮层的宿主页。
///
/// 浮层的祖先结构（inert 门 / 弹窗内导航层 / 缩放中和 / 主题 / 整窗约束 / Stack）
/// 由宿主对象统一持有、恒定不变；宿主页只出 Stack 的子项（barrier、搜索占位、各层、
/// 停驻 realm），里面挂的制卡来源、句子上下文、自动朗读、历史等回调都是它自己的。
abstract interface class SharedLookupPopupOwner {
  /// 根 Overlay 浮层 Stack 的全部子项。[screen] 是中和后的整窗尺寸（与顶层 / 嵌套
  /// 选区 `localToGlobal` 出来的屏幕矩形同一坐标系）。只在本页是渲染方时被调用。
  List<Widget> buildSharedLookupPopupLayers(BuildContext context, Size screen);

  /// 浮层主题覆写（查词主题跟随设置）；null = 跟随根 Overlay 的 Theme。
  ThemeData? get sharedLookupPopupTheme;

  /// 本页 State 此刻能否被读（未销毁、未在摘下途中）。false 时浮层空渲染
  /// （BUG-121：State 失效当帧根 Overlay 仍可能重建 entry，读失效 State 会红屏）。
  bool get sharedLookupPopupOwnerAlive;

  /// 本页成为弹窗栈的渲染方：把 controller 级的单一回调（查词计数等）接到自己身上。
  void onSharedLookupPopupClaimed(DictionaryPopupController controller);
}

/// 一组**不会同时可见**的查词表面共用的弹窗栈 + 根 Overlay 浮层宿主。
///
/// 首页外壳里游戏 tab（texthooker 工作台）与查词 tab 都保活、都把查词浮层挂在根
/// Overlay，原先各自开页 seed 一个常驻隐藏的预热 WebView（BUG-1028 / TODO-931），两个
/// tab 都进过一次后后台同时挂着两个。两者不走阅读器那套光标路由、也不会同时可见，
/// 所以由 HomePage 持有一个本对象、经 [SharedLookupPopupScope] 下发，两页共用同一个
/// [DictionaryPopupController] 与同一个热槽 WebView（拍板台 design-shared-lookup-webview）。
/// 不在首页外壳里的实例（独立查词路由、新手引导、串流副屏的 texthooker）各自私有一个，
/// 行为与原来一页一个 controller 相同。
///
/// 所有权模型：
/// - **渲染方**（[isRenderOwner]）：栈里现有会话的主人，由它出浮层子项。别的宿主页
///   切到前台**不**夺走会话——浮层只是随渲染方不可见而 inert（Offstage，热槽不拆，
///   BUG-953 / BUG-4896），切回原 tab 查词会话原样还在。
/// - 另一页**真正开始查词**前调 [claimForLookup]：把上一个会话收回热槽（热 WebView
///   复用），渲染方换成自己。所以同一时刻栈里只有一个会话，不会出现「A 页的弹窗挂着
///   B 页的回调」。
/// - 渲染方销毁时交给另一个仍挂着的宿主页并收栈；一个都不剩就清栈、摘浮层。
class SharedLookupPopupHost {
  SharedLookupPopupHost({DictionaryPopupController? controller})
    : controller =
          controller ??
          DictionaryPopupController(
            lowMemory: false,
            onLookupStackDepthChanged: recordLookupStackDepth,
          );

  /// 共用的弹窗栈（含唯一的常驻热槽）。
  final DictionaryPopupController controller;

  final List<SharedLookupPopupOwner> _owners = <SharedLookupPopupOwner>[];
  final Set<SharedLookupPopupOwner> _visibleOwners = <SharedLookupPopupOwner>{};
  SharedLookupPopupOwner? _renderOwner;
  OverlayEntry? _entry;
  bool _disposed = false;

  /// 渲染方换人时待收的旧会话（帧后执行，见 [_scheduleApply]）。
  bool _prunePending = false;
  bool _applyScheduled = false;

  /// 仅测试置位，见 [debugPinForTesting]。
  bool _debugPinned = false;

  /// 当前渲染方（测试与诊断用）。
  SharedLookupPopupOwner? get renderOwner => _renderOwner;

  /// 当前挂着的宿主页数（测试用）。
  @visibleForTesting
  int get debugOwnerCount => _owners.length;

  /// 根 Overlay 浮层 entry 是否已插入（测试用）。
  @visibleForTesting
  bool get debugHasOverlayEntry => _entry != null;

  /// [owner] 是不是栈里现有会话的主人（只有它能动栈、它的「有可见弹窗」才算数）。
  bool isRenderOwner(SharedLookupPopupOwner owner) =>
      identical(_renderOwner, owner);

  /// 浮层是否 inert：没有渲染方，或渲染方此刻不可见（所在 tab 被藏起 / 被不透明
  /// 路由盖住 / State 失活）。
  bool get overlayInert {
    final SharedLookupPopupOwner? owner = _renderOwner;
    return owner == null || !_visibleOwners.contains(owner);
  }

  /// 宿主页挂载（initState）时登记。第一个登记的成为渲染方。
  void attach(SharedLookupPopupOwner owner) {
    assert(!_disposed);
    if (_owners.contains(owner)) return;
    _owners.add(owner);
    if (_renderOwner == null) {
      _renderOwner = owner;
      owner.onSharedLookupPopupClaimed(controller);
    }
  }

  /// 宿主页销毁（dispose）时注销。渲染方走了就交给另一个仍挂着的宿主页并收栈。
  void detach(SharedLookupPopupOwner owner) {
    if (!_owners.remove(owner)) return;
    _visibleOwners.remove(owner);
    if (!identical(_renderOwner, owner)) return;
    _renderOwner = _owners.isEmpty ? null : _owners.last;
    _renderOwner?.onSharedLookupPopupClaimed(controller);
    // dispose 处于树终结阶段，不能当场改栈 / 标脏（controller 的监听者里有正在拆的
    // 层），帧后再收旧会话、按新渲染方重建浮层。
    _prunePending = true;
    _scheduleApply();
  }

  /// 宿主页可见性变化（TickerMode / 失活）。只影响浮层 inert，不换渲染方。
  ///
  /// 常在宿主 build 期间（didChangeDependencies）调用；根 Overlay 是祖先，不能当帧
  /// 反向标脏，统一帧后刷新。
  void setOwnerVisible(SharedLookupPopupOwner owner, bool visible) {
    if (!_owners.contains(owner)) return;
    final bool changed = visible
        ? _visibleOwners.add(owner)
        : _visibleOwners.remove(owner);
    if (changed) _scheduleApply();
  }

  /// [owner] 要开始一次顶层查词：栈里若是别页的会话，先收回热槽（热 WebView 复用）、
  /// 渲染方换成 [owner]，并当场重建浮层（调用点在点击 / 输入回调里，不在 build 期间）。
  void claimForLookup(SharedLookupPopupOwner owner) {
    assert(_owners.contains(owner));
    if (identical(_renderOwner, owner)) return;
    _renderOwner = owner;
    owner.onSharedLookupPopupClaimed(controller);
    _prunePending = false;
    controller.pruneToWarmSlot();
    _markNeedsBuild();
  }

  /// [owner] 收自己的会话（保留热槽）。栈里是别页的会话时不动——那不归它管。
  void pruneToWarmSlotFor(SharedLookupPopupOwner owner) {
    if (!identical(_renderOwner, owner)) return;
    controller.pruneToWarmSlot();
  }

  /// 把弹窗栈同步到根 Overlay：栈非空则插入 / 刷新，栈空则摘除。宿主页在自己
  /// build 的帧后调用（[context] 只用来找根 Overlay）。
  void sync(BuildContext context) {
    if (_disposed) return;
    if (controller.entries.isEmpty &&
        !controller.isSearchingUi &&
        !_debugPinned) {
      _removeEntry();
      return;
    }
    final OverlayEntry? existing = _entry;
    if (existing != null) {
      existing.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildOverlay);
    _entry = entry;
    overlay.insert(entry);
  }

  /// 仅测试：不发起查词就把根 Overlay 浮层挂上并钉住（真实运行时常驻热槽让栈永不空，
  /// 宿主一挂就不再摘；测试里没有热槽，钉住免得 [sync] 按「栈空」把它摘掉）。宿主页的
  /// `@visibleForTesting` 入口转调这里，所以本方法自身不加该注解。
  void debugPinForTesting(BuildContext context) {
    _debugPinned = true;
    sync(context);
  }

  /// 宿主对象的持有者销毁时调用（HomePage / 私有实例的宿主页）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _removeEntry();
    _owners.clear();
    _visibleOwners.clear();
    _renderOwner = null;
    controller.dispose();
  }

  void _removeEntry() {
    final OverlayEntry? entry = _entry;
    if (entry == null) return;
    _entry = null;
    if (entry.mounted) entry.remove();
    entry.dispose();
  }

  void _markNeedsBuild() {
    final OverlayEntry? entry = _entry;
    if (entry != null && entry.mounted) entry.markNeedsBuild();
  }

  void _scheduleApply() {
    if (_applyScheduled || _disposed) return;
    _applyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyScheduled = false;
      if (_disposed) return;
      if (_prunePending) {
        _prunePending = false;
        if (_renderOwner == null) {
          // 一个宿主页都不剩：没人能画这些层了，清栈（热槽随之释放）、摘浮层。下一个
          // 挂上来的宿主页开页照常 seed 新热槽。
          _removeEntry();
          controller.clear();
          return;
        }
        controller.pruneToWarmSlot();
      }
      _markNeedsBuild();
    });
  }

  /// 根 Overlay 浮层。inert 时浮层**留在树上、整棵 Offstage**：不画、不接点击、不持
  /// 焦点、停动画，但常驻热槽的查词 WebView 不拆（BUG-4896 / BUG-4849：曾经 inert 即
  /// `SizedBox.shrink()`，每次切 tab 销毁并冷建 WebView2）。祖先结构恒定、只翻参数
  /// （平台视图上方的祖先在层的生命周期内不能增删，见 `parkedPopupLayer`）；换渲染方
  /// 也只换 Stack 子项的回调，层按 entry 身份就地更新，热槽 WebView 不重建。
  Widget _buildOverlay(BuildContext overlayContext) {
    final SharedLookupPopupOwner? owner = _renderOwner;
    final bool inert = overlayInert;
    return Offstage(
      offstage: inert,
      child: TickerMode(
        enabled: !inert,
        child: ExcludeFocus(
          excluding: inert,
          // BUG-2953：浮层自带导航层，弹窗里唤出的菜单画在浮层之上。
          child: LookupOverlayNavigator(
            // 根 Overlay 在 [FushiAppUiScale] 的 FittedBox 之内（缩放后的小画布），
            // WebView 在此栅格化再拉大会字糊（BUG-051）；中和器把整棵子树中和回真实
            // 视口、净缩放 = 1，坐标系即真实屏幕空间。
            child: FushiAppUiScaleNeutralizer(
              child: Theme(
                data: _ownerTheme(owner) ?? Theme.of(overlayContext),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final Size screen = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    final SharedLookupPopupOwner? current = _renderOwner;
                    return Stack(
                      // BUG-135：隐藏热槽停到屏幕右外侧，Clip.none 让它在屏外照常
                      // 预热又不被裁；飘出窗的弹窗同理不裁。
                      clipBehavior: Clip.none,
                      children:
                          current == null ||
                              !current.sharedLookupPopupOwnerAlive
                          ? const <Widget>[]
                          : current.buildSharedLookupPopupLayers(
                              context,
                              screen,
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static ThemeData? _ownerTheme(SharedLookupPopupOwner? owner) {
    if (owner == null || !owner.sharedLookupPopupOwnerAlive) return null;
    return owner.sharedLookupPopupTheme;
  }
}

/// 把 [SharedLookupPopupHost] 下发给首页外壳里的查词表面。
class SharedLookupPopupScope extends InheritedWidget {
  const SharedLookupPopupScope({
    super.key,
    required this.host,
    required super.child,
  });

  final SharedLookupPopupHost host;

  /// 取最近的共用宿主；不在首页外壳里返回 null（宿主页自己私有一个）。不建立依赖：
  /// 宿主对象与持有者同寿命，挂载时取一次即可（可在 initState 里调用）。
  static SharedLookupPopupHost? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SharedLookupPopupScope>()?.host;

  @override
  bool updateShouldNotify(SharedLookupPopupScope oldWidget) =>
      !identical(host, oldWidget.host);
}
