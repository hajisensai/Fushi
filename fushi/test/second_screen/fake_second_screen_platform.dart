import 'package:fushi/src/second_screen/second_screen_host.dart';

/// In-memory stand-in for `SecondScreenDisplay.java`: records calls and lets
/// tests push platform events. A shown panel comes up at once unless
/// [attachOnShow] is false.
class FakeSecondScreenPlatform implements SecondScreenPlatform {
  FakeSecondScreenPlatform({List<SecondScreenDisplayInfo>? displays})
    : displays = displays ?? <SecondScreenDisplayInfo>[];

  List<SecondScreenDisplayInfo> displays;
  void Function(SecondScreenPlatformEvent event)? _onEvent;

  /// Calls as `show:<display>:<mode>` / `dismiss`.
  final List<String> calls = <String>[];
  final List<String> sent = <String>[];
  bool attachOnShow = true;
  bool launchWorks = true;

  /// The panel that is up, as the platform side reported it.
  SecondScreenPanelPlacement? up;

  @override
  void setEventHandler(
    void Function(SecondScreenPlatformEvent event)? onEvent,
  ) => _onEvent = onEvent;

  @override
  Future<List<SecondScreenDisplayInfo>> listDisplays() async =>
      List<SecondScreenDisplayInfo>.of(displays);

  @override
  Future<bool> show(int displayId, SecondScreenPanelMode mode) async {
    calls.add('show:$displayId:${mode.wire}');
    final SecondScreenPanelPlacement next = SecondScreenPanelPlacement(
      mode: mode,
      displayId: displayId,
    );
    if (up == next) return true;
    // Another panel is closed first, as the native lifecycle retires it.
    if (up != null) detach();
    if (!launchWorks) return false;
    if (attachOnShow) attach(mode, displayId);
    return true;
  }

  @override
  Future<void> dismiss() async {
    calls.add('dismiss');
    if (up != null) detach();
  }

  @override
  Future<bool> send(String raw) async {
    sent.add(raw);
    return true;
  }

  void emit(SecondScreenPlatformEvent event) => _onEvent?.call(event);

  void attach(SecondScreenPanelMode mode, int displayId) {
    up = SecondScreenPanelPlacement(mode: mode, displayId: displayId);
    emit(SecondScreenPanelAttached(up));
  }

  /// The panel went away (closed, crashed, host stopped).
  void detach() {
    up = null;
    emit(const SecondScreenPanelAttached(null));
  }

  void setDisplays(List<SecondScreenDisplayInfo> next) {
    displays = next;
    emit(SecondScreenDisplaysChanged(List<SecondScreenDisplayInfo>.of(next)));
  }
}

const SecondScreenDisplayInfo thorBottomScreen = SecondScreenDisplayInfo(
  id: 4,
  name: 'Screen-2',
  widthPx: 1080,
  heightPx: 1240,
  widthDp: 468.3,
  heightDp: 537.7,
  densityDpi: 369,
);

const SecondScreenDisplayInfo hdmiScreen = SecondScreenDisplayInfo(
  id: 7,
  name: 'HDMI',
  widthPx: 1920,
  heightPx: 1080,
  widthDp: 1920,
  heightDp: 1080,
  densityDpi: 160,
);
