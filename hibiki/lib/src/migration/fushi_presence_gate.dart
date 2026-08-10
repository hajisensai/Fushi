import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hibiki/src/migration/migration_target_channel.dart';

/// 「Fushi 现在装着吗」的 UI 闸门。
///
/// 这是**设备上的可变事实**，与「我已经导出过 / 已进入只读态」
/// （[kMigrationReadonlyPrefKey]，持久偏好）是两个不同的事实。把后者当成前者用，
/// 就会出现用户报的症状：把 Fushi 卸掉之后，老版仍然常驻一个「打开 Fushi」按钮，
/// 按下去还静默无反应（`launchFushi` 返回 false 被丢弃）。
///
/// 两条纪律都由本组件统一持有，避免每个调用点各抄一份生命周期代码：
/// 1. **每次 resume 重新探包**。卸载发生在别的界面（系统设置 / 桌面长按），本进程
///    收不到任何回调，只有回到前台这一刻能重新确认；只在 `initState` 探一次
///    等于把开页那一刻的快照当成永久事实。
/// 2. **初值 fail-closed（false）**。首帧还没探完时按「没装」渲染：宁可让装了
///    Fushi 的用户多看半帧「下载 Fushi」，也不能给没装的用户一个点了没反应的
///    死按钮——后者正是本 bug 的用户可见症状。
typedef FushiPresenceBuilder = Widget Function(
    BuildContext context, bool installed);

class FushiPresenceGate extends StatefulWidget {
  const FushiPresenceGate({
    super.key,
    required this.builder,
    this.channel = const MigrationTargetChannel(),
  });

  /// 按「Fushi 是否已安装」渲染。
  final FushiPresenceBuilder builder;

  /// 平台探包通道；测试可注入替身。
  final MigrationTargetChannel channel;

  @override
  State<FushiPresenceGate> createState() => _FushiPresenceGateState();
}

class _FushiPresenceGateState extends State<FushiPresenceGate>
    with WidgetsBindingObserver {
  bool _installed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_probe());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_probe());
    }
  }

  Future<void> _probe() async {
    final bool installed = await widget.channel.isFushiInstalled();
    if (!mounted || installed == _installed) return;
    setState(() => _installed = installed);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _installed);
}
