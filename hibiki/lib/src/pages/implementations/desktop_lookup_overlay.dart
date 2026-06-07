import 'package:flutter/material.dart';

import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';

/// 桌面剪贴板/热键查词导航触发器。
///
/// 订阅 [DesktopLookupService.pendingText]：来文本时 **push 一个完整查词页面**
/// （复用首页查词体验的 [PopupDictionaryPage]：搜索框 + DictionaryPopupWebView +
/// 嵌套下钻 + 制卡），左上角带返回按钮可关闭，与首页查词 tab 一致。
///
/// 平时（pendingText==null）这个 widget 零布局、零影响——仅是一个监听器，
/// 不再 inline 渲染任何浮层（旧 overlay 方案已废弃）。push 后立即 [clearPending]
/// 避免同一段文本重复 push。
class DesktopLookupOverlay extends StatefulWidget {
  const DesktopLookupOverlay({super.key});

  @override
  State<DesktopLookupOverlay> createState() => _DesktopLookupOverlayState();
}

class _DesktopLookupOverlayState extends State<DesktopLookupOverlay> {
  /// 当前是否已有查词页面在栈上：避免连续剪贴板事件叠 push 多页。
  bool _pageOpen = false;

  @override
  void initState() {
    super.initState();
    DesktopLookupService.instance.addListener(_onPending);
  }

  @override
  void dispose() {
    DesktopLookupService.instance.removeListener(_onPending);
    super.dispose();
  }

  void _onPending() {
    final String? text = DesktopLookupService.instance.pendingText;
    if (text == null) return;
    // 立即清 pending，避免 notify 重入 / 重复 push 同一段文本。
    DesktopLookupService.instance.clearPending();
    if (!mounted) return;
    _pushLookup(text);
  }

  void _pushLookup(String text) {
    if (_pageOpen) {
      // 已有查词页：先关旧页再开新页，保证「最新剪贴板文本」在最前。
      Navigator.of(context).pop();
    }
    _pageOpen = true;
    Navigator.of(context)
        .push<void>(
      MaterialPageRoute<void>(
        builder: (context) => _DesktopLookupScaffold(searchTerm: text),
      ),
    )
        .whenComplete(() {
      _pageOpen = false;
    });
  }

  // 监听器本体不渲染任何东西：idle 与触发期都零布局。
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 把自包含的 [PopupDictionaryPage] 包一层带左上角返回按钮的 [Scaffold]，
/// 使桌面剪贴板查词是一个可返回的完整页面（而非 inline 浮层）。
///
/// [PopupDictionaryPage] 自身的 in-card 关闭也走 [closeInApp]→pop，
/// 返回按钮与卡内关闭按钮行为一致。
class _DesktopLookupScaffold extends StatelessWidget {
  const _DesktopLookupScaffold({required this.searchTerm});

  final String searchTerm;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 直接 pop 本路由关闭整页（不走 maybePop / PopScope，避免与
        // PopupDictionaryPage 自身的 PopScope 互相拦截成死锁）。
        leading: BackButton(
          key: const ValueKey<String>('desktop_lookup_back_button'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: PopupDictionaryPage(
        searchTerm: searchTerm,
        autoSearchOnOpen: true,
        closeInApp: () => Navigator.of(context).pop(),
      ),
    );
  }
}
