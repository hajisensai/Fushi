import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 查词弹窗栈 controller（`DictionaryPopupController`）眼里的「一层弹窗 WebView」：
/// 只有手柄动作要用的四个窄能力。
///
/// 依赖方向：controller 是纯逻辑对象，只持 `GlobalKey<DictionaryPopupRealmState>`，
/// 不 import 具体 WebView（`dictionary_popup_webview.dart` 读 AppModel、在大 import
/// 环里）；具体的 `DictionaryPopupWebViewState` 继承本类实现这四个方法。宿主要用
/// WebView 的其余能力时经 `dictionary_popup_webview.dart` 里的 `webViewState`
/// 扩展把键窄化回具体类型。本文件是叶子：只依赖 riverpod，不得 import `package:fushi`
/// （守卫 `test/build/import_cycle_guard_test.dart`）。
abstract class DictionaryPopupRealmState<W extends ConsumerStatefulWidget>
    extends ConsumerState<W> {
  /// 词条焦点前后移；返回 JS 侧状态串（`'blocked'` 表示未移动）。
  Future<String> focusEntryMove(bool forward);

  /// 对首个可见词条制卡。
  Future<void> mineFirstVisibleEntry();

  /// 播放首个可见词条的音频。
  Future<void> playFirstVisibleAudio();

  /// 弹窗正文按逻辑像素滚动 [dy]。
  Future<void> scrollContentBy(double dy);
}
