import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_channel.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_live_activities.dart';

/// iOS / macOS 的 Live Activity（灵动岛 + 锁屏）/ macOS 菜单栏播放条，以及小组件 /
/// 控制中心按钮回调的宿主，挂在 app 根上；其余平台原样透传 [child]。
///
/// 主屏小组件的**快照**不在这里：Android 与 Apple 共用一份 `WidgetSnapshotSource` →
/// `WidgetSnapshotPublisher`（`lib/src/platform/widget_snapshot*.dart`），原生侧各自落盘。
class AppleWidgetsHost extends ConsumerStatefulWidget {
  const AppleWidgetsHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppleWidgetsHost> createState() => _AppleWidgetsHostState();
}

class _AppleWidgetsHostState extends ConsumerState<AppleWidgetsHost>
    with WidgetsBindingObserver {
  final HomeWidgetChannel _channel = HomeWidgetChannel();
  HomeWidgetLiveActivities? _live;
  bool _started = false;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _live?.dispose();
    _channel.setActionHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (HomeWidgetChannel.supported) {
      final bool ready = ref.watch(
        appProvider.select((AppModel m) => m.isInitialised),
      );
      if (ready && !_started) {
        _started = true;
        _start();
      }
    }
    return widget.child;
  }

  void _start() {
    final AppModel app = ref.read(appProvider);
    WidgetsBinding.instance.addObserver(this);
    _channel.setActionHandler(_onAction);
    final HomeWidgetLiveActivities live = HomeWidgetLiveActivities(
      appModel: app,
      channel: _channel,
    );
    _live = live;
    unawaited(live.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _live?.setBackgrounded(
      state == AppLifecycleState.paused || state == AppLifecycleState.hidden,
    );
  }

  /// 原生 → Dart 的按钮动作。返回 true = 接住了（原生侧据此决定要不要把 app 带到前台）。
  Future<bool> _onAction(String action, String? argument) async {
    final HomeWidgetLiveActivities? live = _live;
    if (live == null) return false;
    switch (action) {
      case 'playback':
        return live.handlePlaybackAction(argument);
      case 'resume':
        return live.resumePlayback(argument);
    }
    return false;
  }
}
