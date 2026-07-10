// spec 2026-07-10 §4 — app 级消费者：把 destination=panel/transient 的桌面查词
// 请求从 DesktopLookupService 分发进覆盖窗管线。mainTab 分区不碰（仍由
// HomeDictionaryPage 消费）；分区判据与页面侧共用 resolveDesktopLookupConsumer，
// 互斥分区保证同一 pendingRequest 永不双消费。

import 'dart:async';

import 'package:hibiki/src/lookup/desktop_lookup_router.dart';
import 'package:hibiki/src/lookup/global_lookup_controller.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

class DesktopLookupDispatcher {
  DesktopLookupDispatcher._();
  static final DesktopLookupDispatcher instance = DesktopLookupDispatcher._();

  AppModel? _appModel;
  bool _started = false;

  /// main.dart 桌面块启动一次（在 applyDesktopClipboardLifecycle 之前，先挂监听
  /// 再启服务，防首个剪贴板事件竞态）。幂等。
  void start({required AppModel appModel}) {
    if (_started) return;
    _started = true;
    _appModel = appModel;
    DesktopLookupService.instance.addListener(_onPending);
  }

  void _onPending() {
    final AppModel? model = _appModel;
    final DesktopLookupRequest? request =
        DesktopLookupService.instance.pendingRequest;
    if (model == null || request == null) return;
    final DesktopLookupConsumer consumer = resolveDesktopLookupConsumer(
      origin: request.origin,
      destination: model.desktopClipboardDestination,
      overlayAvailable: GlobalLookupController.instance.isAvailable,
    );
    switch (consumer) {
      case DesktopLookupConsumer.mainTab:
        return; // HomeDictionaryPage 消费。
      case DesktopLookupConsumer.panel:
      // M2（ClipboardPanelController）接管 panel → 面板窗原地更新；在那之前
      // 设置 UI 不暴露 panel 选项，此分支不可达，防御性回落瞬态弹卡。
      case DesktopLookupConsumer.transient:
        DesktopLookupService.instance.clearPending();
        // 整句作 root 卡句子横幅 + 制卡 sentence 字段；查词词条由引擎按
        // 前缀/去屈折从句首匹配（与主窗 tab 的整句自动查同语义）。
        unawaited(GlobalLookupController.instance
            .lookupText(request.text, sentence: request.text));
    }
  }
}
