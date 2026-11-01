/// 播放器层（`VideoFushiPage` 的网页站点后端）关掉时要交回浏览器标签页的地址：单槽。
///
/// 播放器层只当播放器（见 `docs/specs/2026-11-01-one-browser.md`）：站点地址离开观看页、或
/// 用户点「在浏览器中打开」时它关掉自己，把那个地址放进这里；交接它的浏览器标签页
/// （`PlayInFushiFeature`）等浏览页重新在最上面时取走，在**同一个标签页**里加载——地址、
/// 历史、登录都是那一个浏览器的。浏览页同一时刻只交接一个播放器层，所以单槽够用；交接
/// 开始时先清槽，旧值不会串到下一次。
abstract final class WebVideoBrowserReturn {
  static Uri? _pending;

  /// 播放器层关掉前登记要回到的地址。
  static void offer(Uri url) => _pending = url;

  /// 取走（并清空）登记的地址；没有返回 null。
  static Uri? take() {
    final Uri? url = _pending;
    _pending = null;
    return url;
  }
}
