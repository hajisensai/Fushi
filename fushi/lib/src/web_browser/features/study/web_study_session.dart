/// 浏览器阅读 → 学习统计的纯逻辑层（无 WebView / 无 DB，可直接单测）。
///
/// 一个标签页一个 [WebStudySession]，一个页面（[webStudyMediaKey]）一个时钟——新写入面
/// = 新的 `StudyClock` 实例，不另造表（docs/agent/statistics.md）。时钟只在
/// [webStudyClockMayRun] 全部成立时走：前台标签页、app 在前台、页面可见、这一页是日文
/// 页面、用户在这一页上有过交互（滚动 / 按键 / 点按 / 选字）。之后的「还在读吗」交给
/// 时钟自己的空闲门（每次交互 `touch()`，阅读设置的空闲超时）。
library;

import 'dart:async';

/// 学习统计里网页的媒体身份前缀（与浏览器扩展 `web:` 视频身份同一命名空间）。
const String kWebStudyMediaKeyPrefix = 'web:';

/// 单次上报最多认多少字（页内 4 秒一报；挡住脚本异常 / 恶意页面一次灌入巨量字数）。
const int kWebStudyMaxCharsPerReport = 1500;

/// 时钟端口：生产包 `StudyClock`，测试用假的。
abstract interface class WebStudyClockPort {
  void start();

  Future<void> stop();

  /// 零 IO 的最终结算（浏览页销毁时用；写交给退出汇合点）。
  void detach();

  void touch();

  void addChars(int chars);
}

/// 为一个页面建时钟。
typedef WebStudyClockFactory =
    WebStudyClockPort Function({
      required String mediaKey,
      required String title,
    });

/// 网页在学习统计里的稳定身份：`web:` + 主机 + 路径（+ 查询串），不含片段 / 协议 /
/// 末尾斜杠；非 http(s) 页面返回 null（不计）。
String? webStudyMediaKey(Uri? url) {
  if (url == null || (url.scheme != 'http' && url.scheme != 'https')) {
    return null;
  }
  final String host = url.host.toLowerCase();
  if (host.isEmpty) return null;
  String path = url.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final String query = url.hasQuery && url.query.isNotEmpty
      ? '?${url.query}'
      : '';
  return '$kWebStudyMediaKeyPrefix$host$path$query';
}

/// 时钟能不能走（唯一判据）。
bool webStudyClockMayRun({
  required bool tabActive,
  required bool appForeground,
  required bool pageVisible,
  required bool japanesePage,
  required bool interacted,
  bool videoPlaying = false,
}) =>
    tabActive &&
    appForeground &&
    pageVisible &&
    japanesePage &&
    interacted &&
    // 页内网页视频在播：这段时间由扩展沉浸计时记进视频统计，阅读面让位，不双计。
    !videoPlaying;

/// 页内脚本的一次上报。
typedef WebStudyReport = ({
  bool visible,
  bool interacted,
  bool japanese,
  int chars,
});

/// 解析页内上报（`{visible, interacted, ja, chars}`）；形状不对返回 null。
WebStudyReport? parseWebStudyReport(List<dynamic> args) {
  if (args.isEmpty || args.first is! Map) return null;
  final Map<dynamic, dynamic> b = args.first as Map<dynamic, dynamic>;
  final Object? chars = b['chars'];
  final int n = chars is num ? chars.toInt() : 0;
  return (
    visible: b['visible'] != false,
    interacted: b['interacted'] == true,
    japanese: b['ja'] == true,
    chars: n.clamp(0, kWebStudyMaxCharsPerReport),
  );
}

/// 一个标签页的学习计时。
class WebStudySession {
  WebStudySession({required this.incognito, required this.clockFactory});

  /// 无痕标签页不记统计（不留痕迹）。
  final bool incognito;
  final WebStudyClockFactory clockFactory;

  String? _key;
  WebStudyClockPort? _clock;
  bool _running = false;
  bool _tabActive = false;
  bool _appForeground = true;
  bool _pageVisible = true;
  bool _japanese = false;
  bool _interacted = false;
  bool _videoPlaying = false;

  /// 当前页面身份（测试 / 诊断）。
  String? get mediaKey => _key;
  bool get running => _running;

  bool get _mayRun =>
      !incognito &&
      _key != null &&
      webStudyClockMayRun(
        tabActive: _tabActive,
        appForeground: _appForeground,
        pageVisible: _pageVisible,
        japanesePage: _japanese,
        interacted: _interacted,
        videoPlaying: _videoPlaying,
      );

  /// 主框架换了页面（加载完成 / SPA 改地址）。身份没变不动；变了封上一页的时钟，
  /// 新页面等首次交互再开钟。返回上一页时钟的停表 Future（无则已完成）。
  Future<void> navigate(Uri? url) {
    final String? key = webStudyMediaKey(url);
    if (key == _key) return Future<void>.value();
    final Future<void> sealed = _dropClock();
    _key = key;
    _interacted = false;
    _japanese = false;
    _pageVisible = true;
    return sealed;
  }

  void setTabActive(bool active) {
    _tabActive = active;
    _sync();
  }

  /// 本页网页视频在播 / 停了（见 `WebBrowserVideoActivity`）。
  void setVideoPlaying(bool playing) {
    if (playing == _videoPlaying) return;
    _videoPlaying = playing;
    _sync();
  }

  void setAppForeground(bool foreground) {
    _appForeground = foreground;
    _sync();
  }

  /// 页内上报：可见性、日文判定、交互、翻过去的字数。[title] 只在首次开钟时用。
  void report(WebStudyReport r, {required String title}) {
    _pageVisible = r.visible;
    if (r.japanese) _japanese = true;
    if (r.interacted) _interacted = true;
    if (_mayRun && _clock == null) {
      final String key = _key!;
      _clock = clockFactory(mediaKey: key, title: title.isEmpty ? key : title);
    }
    _sync();
    final WebStudyClockPort? clock = _clock;
    if (!_running || clock == null) return;
    if (r.interacted) clock.touch();
    if (r.chars > 0) clock.addChars(r.chars);
  }

  void _sync() {
    final WebStudyClockPort? clock = _clock;
    if (clock == null) return;
    final bool want = _mayRun;
    if (want == _running) return;
    _running = want;
    if (want) {
      clock.start();
    } else {
      // 停表是停顿不是换页：同一个时钟之后续表，开新段由时钟自己决定。
      unawaited(clock.stop());
    }
  }

  Future<void> _dropClock() {
    final WebStudyClockPort? clock = _clock;
    _clock = null;
    _running = false;
    return clock?.stop() ?? Future<void>.value();
  }

  /// 标签页关闭：停表落库。
  Future<void> close() {
    _key = null;
    return _dropClock();
  }

  /// 浏览页销毁：零 IO 结算（写交给退出汇合点）。
  void detach() {
    final WebStudyClockPort? clock = _clock;
    _clock = null;
    _running = false;
    _key = null;
    clock?.detach();
  }
}
