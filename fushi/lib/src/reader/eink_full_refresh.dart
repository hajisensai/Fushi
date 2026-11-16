/// 墨水屏「每 N 页全刷」（拍板台 oF0jVdOTIE：方案 A + B 都做）。
///
/// 墨水屏阅读器系统自带的「应用优化 / 定时全刷」常常对第三方 app 翻页不生效，残影
/// 只能手动点全刷。这里由 Fushi 自己在翻页时计数，每 N 次翻页做一次全刷：
///
/// - **B（设备自带全刷）**：Android 上经 [EinkDeviceRefresher]（厂商 EPD 控制器，
///   反射探测 Onyx / 瑞芯微 / NTX）请求一次 GC16 全刷，效果最好。
/// - **A（黑屏闪刷）**：通用做法——在最上层盖一帧全黑、停留 [kEinkFlashHold] 再撤掉，
///   让面板把整屏从黑重刷回正文，任何品牌 / 平台都能用；代价是闪一下。
///
/// 方式 [EinkFullRefreshMethod.auto] 先试 B，本机没有厂商通道（或调用失败）就走 A；
/// [EinkFullRefreshMethod.flash] 永远走 A（厂商方法「调用成功但这台机器上没效果」时
/// 用户手动切过来）。
///
/// 计数入口只有一个 [EinkFullRefreshController.notePageTurn]：小说阅读器在分页 / 视觉
/// 小说的每一次实际翻页、跨章、以及连续滚动每滚过一屏时调用；漫画阅读器在当前页变化
/// 时调用。间隔 0 = 关（默认）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:fushi/src/platform/mobile/android_eink_refresh.dart';
import 'package:material_ui/material_ui.dart';

export 'package:fushi/src/platform/mobile/android_eink_refresh.dart'
    show AndroidEinkRefresh, EinkDeviceRefresher;

/// 全刷方式。`storageKey` 是偏好值（冻结的持久化名，改名要迁移）。
enum EinkFullRefreshMethod {
  /// 设备支持厂商全刷就用它，否则黑屏闪刷。
  auto('auto'),

  /// 永远黑屏闪刷。
  flash('flash');

  const EinkFullRefreshMethod(this.storageKey);

  final String storageKey;

  static EinkFullRefreshMethod fromStorageKey(String? key) {
    for (final EinkFullRefreshMethod method in values) {
      if (method.storageKey == key) return method;
    }
    return auto;
  }
}

/// 设置页可选的间隔（翻页次数）；0 = 关。
const List<int> kEinkFullRefreshIntervalChoices = <int>[0, 1, 2, 3, 5, 10, 20];

/// 间隔的出厂默认：关。
const int kEinkFullRefreshIntervalDefault = 0;

/// 间隔上限：存储值越界（手改偏好 / 旧版本写坏）时钳到这里。
const int kEinkFullRefreshIntervalMax = 100;

/// 存储值 → 生效间隔：负数视为关，过大钳到 [kEinkFullRefreshIntervalMax]。
int normalizeEinkFullRefreshInterval(int raw) => raw <= 0
    ? 0
    : (raw > kEinkFullRefreshIntervalMax ? kEinkFullRefreshIntervalMax : raw);

/// 黑屏闪刷的停留时长。墨水屏面板一次 GC16 全波形约 200～450ms；黑帧只要停到面板
/// 开始把它刷上去即可（撤掉时面板再从黑刷回正文，残影就在这一黑一白之间被清掉）。
/// 这是硬件刷新的等待，不是动效时长，所以不取 FushiMotion token。
const Duration kEinkFlashHold = Duration(milliseconds: 200);

/// 全刷的生效配置（每次翻页现读，设置改了立即生效）。
typedef EinkFullRefreshSettings = ({
  int interval,
  EinkFullRefreshMethod method,
});

/// 翻页计数 + 触发全刷。全 app 一个实例（`AppModel.einkFullRefresh`），由
/// [EinkFullRefreshHost] 在最顶层画黑帧。
class EinkFullRefreshController {
  EinkFullRefreshController({
    required EinkFullRefreshSettings Function() settings,
    required EinkDeviceRefresher device,
    Duration flashHold = kEinkFlashHold,
    Future<void> Function()? awaitPainted,
  }) : _settings = settings,
       _device = device,
       _flashHold = flashHold,
       _awaitPainted = awaitPainted ?? _endOfFrame;

  final EinkFullRefreshSettings Function() _settings;
  final EinkDeviceRefresher _device;
  final Duration _flashHold;
  final Future<void> Function() _awaitPainted;

  final ValueNotifier<bool> _flashing = ValueNotifier<bool>(false);

  /// true 期间 [EinkFullRefreshHost] 在整个 app 之上盖一层纯黑。
  ValueListenable<bool> get flashing => _flashing;

  int _turnsSinceRefresh = 0;
  bool _refreshing = false;
  bool _disposed = false;

  static Future<void> _endOfFrame() => SchedulerBinding.instance.endOfFrame;

  /// 记一次翻页；到了间隔就触发一次全刷并返回 true。
  ///
  /// 间隔为 0（关）时清零计数：重新打开后从头数，不会一打开就因为旧计数立刻闪。
  /// 上一次全刷还没做完时到点的这一次直接跳过（计数照样清零）——连按翻页时不排队
  /// 补刷，补刷的那一下刷的已经不是触发它的那一页了。
  bool notePageTurn() {
    if (_disposed) return false;
    final EinkFullRefreshSettings settings = _settings();
    final int interval = normalizeEinkFullRefreshInterval(settings.interval);
    if (interval == 0) {
      _turnsSinceRefresh = 0;
      return false;
    }
    _turnsSinceRefresh++;
    if (_turnsSinceRefresh < interval) return false;
    _turnsSinceRefresh = 0;
    if (_refreshing) return false;
    unawaited(_fullRefresh(settings.method));
    return true;
  }

  Future<void> _fullRefresh(EinkFullRefreshMethod method) async {
    _refreshing = true;
    try {
      // 先让翻到的新页画上屏：全刷刷的必须是新页。
      await _awaitPainted();
      if (_disposed) return;
      if (method == EinkFullRefreshMethod.auto && await _device.fullRefresh()) {
        return;
      }
      if (_disposed) return;
      _flashing.value = true;
      await _awaitPainted();
      await Future<void>.delayed(_flashHold);
      if (_disposed) return;
      _flashing.value = false;
    } finally {
      _refreshing = false;
    }
  }

  void dispose() {
    _disposed = true;
    _flashing.dispose();
  }
}

/// 黑屏闪刷的画布：放在根 Stack 的最上层，平时是空的、不吃任何指针事件。
///
/// 刻意没有淡入淡出：墨水屏上任何中间灰帧都是一次额外的局部刷新，反而留残影。
class EinkFullRefreshHost extends StatelessWidget {
  const EinkFullRefreshHost({super.key, required this.controller});

  final EinkFullRefreshController controller;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<bool>(
          valueListenable: controller.flashing,
          builder: (BuildContext context, bool flashing, Widget? _) => flashing
              ? const ColoredBox(color: Color(0xFF000000))
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
