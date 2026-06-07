import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/utils.dart';

/// 桌面剪贴板查词 overlay：订阅 [DesktopLookupService.pendingText]，
/// 显示分词可点卡片 + 查词浮层（复用 texthooker 范式）。挂主 app 顶层。
class DesktopLookupOverlay extends ConsumerStatefulWidget {
  const DesktopLookupOverlay({super.key});
  @override
  ConsumerState<DesktopLookupOverlay> createState() =>
      _DesktopLookupOverlayState();
}

class _DesktopLookupOverlayState extends ConsumerState<DesktopLookupOverlay>
    with DictionaryPageMixin {
  final List<NestedPopupEntry> _popupStack = <NestedPopupEntry>[];

  @override
  AppModel get mixinAppModel => ref.read(appProvider);
  @override
  ThemeData get mixinTheme => Theme.of(context);

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
    if (mounted) setState(() {});
  }

  void _close() {
    setState(() => _popupStack.clear());
    DesktopLookupService.instance.clearPending();
  }

  void _onWordTap(String word, Rect rect) {
    pushNestedPopup(
      query: word,
      selectionRect: rect,
      popupStack: _popupStack,
      replaceStack: true,
      autoRead: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? text = DesktopLookupService.instance.pendingText;
    if (text == null) return const SizedBox.shrink();
    final List<String> words = JapaneseLanguage.instance.textToWords(text);
    // 自身根用 Stack（含查词浮层的 Positioned 子层），故可独立挂在任意父级；
    // 挂到 home_page 顶层时外面再包一层填满父级的 Positioned.fill。
    return Stack(
      children: <Widget>[
        Positioned(
          right: 16,
          top: 16,
          width: 360,
          child: HibikiCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _close,
                ),
                Wrap(
                  children: <Widget>[
                    for (final String w in words)
                      _ClipWordSpan(word: w, onTap: _onWordTap),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (int i = 0; i < _popupStack.length; i++)
          buildNestedPopupLayer(
            index: i,
            screen: MediaQuery.sizeOf(context),
            popupStack: _popupStack,
            onPush: (String t, Rect r) => pushNestedPopup(
              query: t,
              selectionRect: r,
              popupStack: _popupStack,
            ),
            onPop: (int idx) => popNestedPopupAt(idx, _popupStack),
          ),
      ],
    );
  }
}

/// 单个可点词 span：点击时上报全局选区矩形供浮层定位（复用 texthooker 范式）。
class _ClipWordSpan extends StatelessWidget {
  const _ClipWordSpan({required this.word, required this.onTap});
  final String word;
  final void Function(String word, Rect rect) onTap;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapUp: (TapUpDetails d) {
        final RenderBox box = context.findRenderObject()! as RenderBox;
        onTap(word, box.localToGlobal(Offset.zero) & box.size);
      },
      child: Text(
        word,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.6),
      ),
    );
  }
}
