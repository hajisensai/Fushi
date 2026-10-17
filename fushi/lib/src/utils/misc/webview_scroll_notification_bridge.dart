/// 把 WebView 文档内的纵向滚动转成 Flutter [ScrollNotification] 冒泡给宿主树
/// （BUG-3064）。
///
/// WebView 里的滚动是平台视图自己的原生滚动，Flutter 树收不到任何
/// [ScrollNotification]：首页外壳靠 `NotificationListener` 喂
/// `FushiAppleScrollChrome`（底栏随下滑收起）/ 大标题收起，查词结果卡整块是
/// WebView，往下滑底栏纹丝不动。这里不另造判据：JS 端把每帧滚动位置报上来，
/// 本桥按 Flutter 自己 Scrollable 的形状派发 [UserScrollNotification]（方向
/// 变化时）+ [ScrollUpdateNotification]，外壳那台状态机照原样处理——与库页
/// ListView 同一条路、同一组阈值。
///
/// 「是不是用户滚动」：JS 端在用户输入（touchstart / wheel / pointerdown /
/// keydown）后置位，宿主每次整页重渲染（换词归零、恢复滚动位）前清位；未置位的
/// 样本按 [ScrollDirection.idle] 派发——对应 Flutter 里 jumpTo / 位置恢复不带
/// 用户方向，状态机据此不累计（与库页程序滚动同一语义）。
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// JS → Dart 的滚动样本（CSS px ≈ 逻辑 px；结果区 WebView 在界面缩放中和器下）。
@immutable
class WebViewScrollSample {
  const WebViewScrollSample({
    required this.pixels,
    required this.maxScrollExtent,
    required this.viewportDimension,
    required this.userDriven,
  });

  /// 解析 `popupHostScroll` 回调参数；形状不对返回 null。
  static WebViewScrollSample? fromJs(Object? raw) {
    if (raw is! Map) return null;
    final Object? pixels = raw['pixels'];
    final Object? max = raw['max'];
    final Object? viewport = raw['viewport'];
    if (pixels is! num || max is! num || viewport is! num) return null;
    if (!pixels.isFinite || !max.isFinite || !viewport.isFinite) return null;
    if (viewport <= 0) return null;
    return WebViewScrollSample(
      pixels: pixels.toDouble(),
      maxScrollExtent: max < 0 ? 0 : max.toDouble(),
      viewportDimension: viewport.toDouble(),
      userDriven: raw['user'] == true,
    );
  }

  final double pixels;
  final double maxScrollExtent;
  final double viewportDimension;
  final bool userDriven;
}

/// 一个 WebView 一份：记住上一个样本的位置与方向，把样本翻译成通知。
class WebViewScrollNotificationBridge {
  double? _lastPixels;
  ScrollDirection _direction = ScrollDirection.idle;

  /// 当前方向（测试 / 诊断用）。
  ScrollDirection get direction => _direction;

  /// 从 [context]（WebView 所在位置）向上派发 [sample] 对应的通知。
  void dispatch(BuildContext context, WebViewScrollSample sample) {
    if (!context.mounted) return;
    final double? last = _lastPixels;
    _lastPixels = sample.pixels;
    final double delta = last == null ? 0 : sample.pixels - last;
    final ScrollDirection direction = !sample.userDriven
        ? ScrollDirection.idle
        : delta > 0
        // 内容往上走（看后面的内容）= Flutter 的 reverse。
        ? ScrollDirection.reverse
        : delta < 0
        ? ScrollDirection.forward
        : _direction;
    final FixedScrollMetrics metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: sample.maxScrollExtent,
      pixels: sample.pixels,
      viewportDimension: sample.viewportDimension,
      axisDirection: AxisDirection.down,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    if (direction != _direction) {
      _direction = direction;
      UserScrollNotification(
        metrics: metrics,
        context: context,
        direction: direction,
      ).dispatch(context);
    }
    ScrollUpdateNotification(
      metrics: metrics,
      context: context,
      scrollDelta: delta,
    ).dispatch(context);
  }

  /// 文档换了（WebView 重建 / 重载）：上一份位置不再可比。
  void reset() {
    _lastPixels = null;
    _direction = ScrollDirection.idle;
  }
}

/// 注入 WebView 的滚动上报脚本：每帧最多报一次文档（window）纵向滚动位置。
/// 只认文档本身的滚动，内层横滚表格 / 子容器不算。幂等。
const String kWebViewHostScrollReportJs = '''
(function(){
  if(window.__fushiHostScrollInstalled) return;
  window.__fushiHostScrollInstalled=true;
  window.__fushiHostScrollUser=false;
  function arm(){ window.__fushiHostScrollUser=true; }
  ['touchstart','wheel','pointerdown','keydown'].forEach(function(t){
    window.addEventListener(t,arm,{capture:true,passive:true});
  });
  var pending=false;
  function report(){
    pending=false;
    var s=document.scrollingElement||document.documentElement;
    if(!s) return;
    var vh=window.innerHeight||s.clientHeight||0;
    var px=Math.max(window.scrollY||0,s.scrollTop||0);
    var max=Math.max(0,s.scrollHeight-vh);
    try{
      window.flutter_inappwebview.callHandler('popupHostScroll',
        {pixels:px,max:max,viewport:vh,user:window.__fushiHostScrollUser===true});
    }catch(_){}
  }
  window.addEventListener('scroll',function(e){
    var t=e.target;
    if(t&&t.nodeType===1&&t!==document.documentElement&&t!==document.body) return;
    if(pending) return;
    pending=true;
    requestAnimationFrame(report);
  },{capture:true,passive:true});
})();
''';

/// 宿主整页重渲染（换词 / 恢复滚动位）前清掉「用户滚动」标记：接下来的归零 /
/// 恢复是程序滚动。
const String kWebViewHostScrollDisarmJs = 'window.__fushiHostScrollUser=false;';
