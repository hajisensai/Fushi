// spec 2026-07-10 §4 — app 级消费者：把 destination=panel/transient 的桌面查词
// 请求从 DesktopLookupService 分发进覆盖窗管线。mainTab 分区不碰（仍由
// HomeDictionaryPage 消费）；分区判据与页面侧共用 resolveDesktopLookupConsumer，
// 互斥分区保证同一 pendingRequest 永不双消费。

import 'dart:async';

import 'package:hibiki/src/lookup/clipboard_panel_controller.dart';
import 'package:hibiki/src/lookup/clipboard_text_overlay_controller.dart';
import 'package:hibiki/src/lookup/desktop_lookup_router.dart';
import 'package:hibiki/src/lookup/global_lookup_controller.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
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
    // 与 HomeDictionaryPage 侧同构：AppModel 未初始化（prefsRepo 未就绪）时按
    // 默认 main 分区（即不消费，留给页面）。生产不可达（dispatcher 在
    // initialise 完成后启动），守卫只为两个消费者对同一输入保持对称。
    final DesktopClipboardDestination destination = model.isInitialised
        ? model.desktopClipboardDestination
        : DesktopClipboardDestination.main;
    final DesktopLookupConsumer consumer = resolveDesktopLookupConsumer(
      origin: request.origin,
      destination: destination,
      overlayAvailable: GlobalLookupController.instance.isAvailable,
    );
    switch (consumer) {
      case DesktopLookupConsumer.mainTab:
        return; // HomeDictionaryPage 消费。
      case DesktopLookupConsumer.panel:
        DesktopLookupService.instance.clearPending();
        // 常驻面板原地更新（paused 时仅 hotkey 显式意图解除并继续）。
        unawaited(ClipboardPanelController.instance.update(request));
      case DesktopLookupConsumer.transient:
        DesktopLookupService.instance.clearPending();
        // 整句作 root 卡句子横幅 + 制卡 sentence 字段；查词词条由引擎按
        // 前缀/去屈折从句首匹配（与主窗 tab 的整句自动查同语义）。
        // BUG-1099：被动剪贴板流（galgame 台词 / 外部 texthooker）标记透传，
        // 用户点词开出的卡还在屏上时不被整帧重建（不清尺寸、不缩窗）。
        unawaited(GlobalLookupController.instance.lookupText(
          request.text,
          sentence: request.text,
          passiveStream: request.passiveStream,
          autoRead: request.allowsAutomaticAudio,
        ));
      case DesktopLookupConsumer.textWindow:
        DesktopLookupService.instance.clearPending();
        // 逐像素透明文字窗原地显示整句：不自动查词，用户点某个字才经 native
        // lookupText 回调弹瞬态查词卡（VN/游戏透明浮字场景）。
        unawaited(ClipboardTextOverlayController.instance.update(request));
    }
  }
}
