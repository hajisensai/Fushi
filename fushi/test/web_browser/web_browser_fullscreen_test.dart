import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_scripts.dart';
import 'package:fushi/src/web_browser/web_browser_fullscreen.dart';

/// 「Fushi 接管网页全屏」：方向 / 分屏判据 + 页内全屏脚本（node 真执行，喂一个
/// 最小 DOM 替身）。无 node 时脚本那组 skip。
void main() {
  group('方向锁', () {
    test('不在全屏：还原成竖屏 + 两个横屏', () {
      for (final WebBrowserFullscreenFit fit
          in WebBrowserFullscreenFit.values) {
        expect(
          webBrowserFullscreenOrientations(
            fullscreen: false,
            fit: fit,
            autoRotate: true,
          ),
          kWebBrowserIdleOrientations,
        );
      }
    });

    test('横视频 + 自动转横屏：只给两个横屏；关掉自动转横屏不改', () {
      expect(
        webBrowserFullscreenOrientations(
          fullscreen: true,
          fit: WebBrowserFullscreenFit.landscape,
          autoRotate: true,
        ),
        const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      );
      expect(
        webBrowserFullscreenOrientations(
          fullscreen: true,
          fit: WebBrowserFullscreenFit.landscape,
          autoRotate: false,
        ),
        kWebBrowserIdleOrientations,
      );
    });

    test('竖视频：只给竖屏（与自动转横屏开关无关）；方向未知不改', () {
      for (final bool autoRotate in <bool>[true, false]) {
        expect(
          webBrowserFullscreenOrientations(
            fullscreen: true,
            fit: WebBrowserFullscreenFit.portrait,
            autoRotate: autoRotate,
          ),
          const <DeviceOrientation>[DeviceOrientation.portraitUp],
        );
      }
      expect(
        webBrowserFullscreenOrientations(
          fullscreen: true,
          fit: WebBrowserFullscreenFit.unknown,
          autoRotate: true,
        ),
        kWebBrowserIdleOrientations,
      );
    });

    test('上报值解析：未知值退到 unknown', () {
      expect(
        WebBrowserFullscreenFit.fromWire('landscape'),
        WebBrowserFullscreenFit.landscape,
      );
      expect(
        WebBrowserFullscreenFit.fromWire('portrait'),
        WebBrowserFullscreenFit.portrait,
      );
      expect(
        WebBrowserFullscreenFit.fromWire(''),
        WebBrowserFullscreenFit.unknown,
      );
      expect(
        WebBrowserFullscreenFit.fromWire(null),
        WebBrowserFullscreenFit.unknown,
      );
    });
  });

  group('竖拿横视频分屏', () {
    test('只在全屏 + 横视频 + 竖视口时分屏', () {
      expect(
        webBrowserFullscreenSplit(
          fullscreen: true,
          fit: WebBrowserFullscreenFit.landscape,
          width: 390,
          height: 844,
        ),
        isTrue,
      );
      expect(
        webBrowserFullscreenSplit(
          fullscreen: true,
          fit: WebBrowserFullscreenFit.landscape,
          width: 844,
          height: 390,
        ),
        isFalse,
        reason: '转成横屏就铺满',
      );
      expect(
        webBrowserFullscreenSplit(
          fullscreen: true,
          fit: WebBrowserFullscreenFit.portrait,
          width: 390,
          height: 844,
        ),
        isFalse,
        reason: '竖视频竖屏铺满',
      );
      expect(
        webBrowserFullscreenSplit(
          fullscreen: false,
          fit: WebBrowserFullscreenFit.landscape,
          width: 390,
          height: 844,
        ),
        isFalse,
      );
    });

    test('视频区高度 = 16:9 按宽铺满，夹在 20%～60% 视口', () {
      expect(
        webBrowserFullscreenSplitVideoHeight(width: 390, height: 844),
        closeTo(390 * 9 / 16, 0.001),
      );
      expect(
        webBrowserFullscreenSplitVideoHeight(width: 800, height: 900),
        900 * 0.6,
      );
      expect(
        webBrowserFullscreenSplitVideoHeight(width: 200, height: 1200),
        1200 * 0.2,
      );
    });
  });

  group('页内全屏脚本（node 执行）', () {
    String? node;
    setUpAll(() => node = _resolveNode());

    test('接管：video.webkitEnterFullscreen 进伪全屏（取播放器容器），状态与网站一致', () async {
      if (node == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Map<String, dynamic> r = await _run(node!, takeover: true);
      expect(r['enterCall'], <Object?>[
        kWebBrowserFullscreenHandler,
        true,
        'landscape',
      ]);
      expect(r['fsIsPlayer'], isTrue, reason: '视频请求全屏时铺满的是包住它的播放器');
      expect(r['playerMarked'], isTrue);
      expect(r['playsinline'], isTrue, reason: 'iPhone 不再进系统播放器');
      expect(r['siteSawChange'], 1, reason: '网站的 fullscreenchange 监听收到一次');
      expect(r['videoDisplaying'], isTrue);
      expect(r['exitCall'], <Object?>[kWebBrowserFullscreenHandler, false, '']);
      expect(r['fsAfterExit'], isNull);
      expect(r['playerUnmarked'], isTrue);
      expect(r['siteSawChangeAfterExit'], 2);
      expect(r['portraitCall'], <Object?>[
        kWebBrowserFullscreenHandler,
        true,
        'portrait',
      ]);
      expect(r['toggleOn'], isTrue, reason: '扩展的全屏按钮能进');
      expect(r['toggleOff'], isTrue, reason: '再按一次退');
      expect(r['escExits'], isTrue, reason: '桌面 Esc 退伪全屏');
    });

    test('不接管：不改全屏 API，只上报原生全屏变化', () async {
      if (node == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final Map<String, dynamic> r = await _run(node!, takeover: false);
      expect(r['patched'], isFalse);
      expect(r['api'], isFalse);
      expect(r['nativeCall'], <Object?>[
        kWebBrowserFullscreenHandler,
        true,
        'landscape',
      ]);
    });
  });
}

Future<Map<String, dynamic>> _run(String node, {required bool takeover}) async {
  final Directory dir = await Directory.systemTemp.createTemp('fushi_fs_');
  try {
    final File js = File('${dir.path}${Platform.pathSeparator}harness.js');
    await js.writeAsString('''
var calls = [];
function Node_(){ this._l = {}; }
Node_.prototype.addEventListener = function(t, fn){ (this._l[t] = this._l[t] || []).push(fn); };
Node_.prototype.dispatchEvent = function(ev){
  if (!ev.target) ev.target = this;
  var n = this;
  while (n) {
    var ls = (n._l[ev.type] || []).slice();
    for (var i = 0; i < ls.length; i++) ls[i].call(n, ev);
    if (!ev.bubbles) break;
    n = n === document ? null : (n.parentElement || document);
  }
  return true;
};
function Element(tag, rect){
  Node_.call(this);
  this.tagName = tag; this.attrs = {}; this.children = []; this.parentElement = null;
  this.rect = rect || {width: 0, height: 0};
}
Element.prototype = Object.create(Node_.prototype);
Element.prototype.getBoundingClientRect = function(){ return this.rect; };
Element.prototype.setAttribute = function(k, v){ this.attrs[k] = String(v); };
Element.prototype.removeAttribute = function(k){ delete this.attrs[k]; };
Element.prototype.hasAttribute = function(k){ return Object.prototype.hasOwnProperty.call(this.attrs, k); };
Element.prototype.appendChild = function(c){ c.parentElement = this; this.children.push(c); return c; };
Element.prototype.contains = function(o){ for (var n = o; n; n = n.parentElement) if (n === this) return true; return false; };
Object.defineProperty(Element.prototype, 'isConnected', {get: function(){
  for (var n = this; n; n = n.parentElement) if (n === html) return true; return false; }});
Element.prototype.querySelectorAll = function(sel){
  var out = [];
  var attr = /^\\[([^\\]]+)\\]\$/.exec(sel);
  (function walk(n){
    for (var i = 0; i < n.children.length; i++) {
      var c = n.children[i];
      if (attr ? c.hasAttribute(attr[1]) : c.tagName.toLowerCase() === sel) out.push(c);
      walk(c);
    }
  })(this);
  return out;
};
function HTMLVideoElement(w, h, rect){ Element.call(this, 'VIDEO', rect); this.videoWidth = w; this.videoHeight = h; }
HTMLVideoElement.prototype = Object.create(Element.prototype);
function Document(){ Node_.call(this); }
Document.prototype = Object.create(Node_.prototype);
var nativeFs = null;
Object.defineProperty(Document.prototype, 'fullscreenElement', {configurable: true, get: function(){ return nativeFs; }});
Document.prototype.exitFullscreen = function(){ nativeFs = null; return Promise.resolve(); };
function Event(type, init){ this.type = type; this.bubbles = !!(init && init.bubbles); this.defaultPrevented = false; }
function MutationObserver(){ this.observe = function(){}; }
var document = new Document();
var html = new Element('HTML', {width: 400, height: 800});
var body = html.appendChild(new Element('BODY', {width: 400, height: 2000}));
var head = html.appendChild(new Element('HEAD'));
var player = body.appendChild(new Element('DIV', {width: 400, height: 225}));
var video = player.appendChild(new HTMLVideoElement(1920, 1080, {width: 400, height: 225}));
player.appendChild(new Element('DIV', {width: 400, height: 30}));
document.documentElement = html; document.body = body; document.head = head;
document.createElement = function(tag){ return new Element(tag.toUpperCase()); };
document.querySelectorAll = function(sel){ return html.querySelectorAll(sel); };
var winListeners = {};
var window = {
  HTMLVideoElement: HTMLVideoElement,
  addEventListener: function(t, fn){ (winListeners[t] = winListeners[t] || []).push(fn); },
  flutter_inappwebview: { callHandler: function(n, on, fit){ calls.push([n, on, fit]); } }
};
var siteChanges = 0;
document.addEventListener('fullscreenchange', function(){ siteChanges++; });
var takeover = ${takeover ? 'true' : 'false'};
var origRequest = Element.prototype.requestFullscreen;

${webBrowserFullscreenScript(takeover: takeover)}

var r = {};
r.patched = Element.prototype.requestFullscreen !== origRequest;
r.api = !!window.fushiPageFullscreen;
if (takeover) {
  video.webkitEnterFullscreen();
  r.enterCall = calls[calls.length - 1];
  r.fsIsPlayer = document.fullscreenElement === player;
  r.playerMarked = player.hasAttribute('data-fushi-page-fullscreen');
  r.playsinline = video.hasAttribute('playsinline');
  r.siteSawChange = siteChanges;
  r.videoDisplaying = video.webkitDisplayingFullscreen === true;
  document.exitFullscreen();
  r.exitCall = calls[calls.length - 1];
  r.fsAfterExit = document.fullscreenElement;
  r.playerUnmarked = !player.hasAttribute('data-fushi-page-fullscreen');
  r.siteSawChangeAfterExit = siteChanges;
  video.videoWidth = 1080; video.videoHeight = 1920;
  player.requestFullscreen();
  r.portraitCall = calls[calls.length - 1];
  document.exitFullscreen();
  window.fushiPageFullscreen.toggle(video);
  r.toggleOn = document.fullscreenElement === player;
  window.fushiPageFullscreen.toggle(video);
  r.toggleOff = document.fullscreenElement === null;
  player.requestFullscreen();
  (winListeners.keydown || []).forEach(function(fn){ fn({key: 'Escape', defaultPrevented: false}); });
  r.escExits = document.fullscreenElement === null;
} else {
  nativeFs = player;
  document.dispatchEvent(new Event('fullscreenchange'));
  r.nativeCall = calls[calls.length - 1];
}
process.stdout.write(JSON.stringify(r));
''');
    final ProcessResult res = await Process.run(node, <String>[js.path]);
    expect(res.exitCode, 0, reason: '${res.stderr}');
    return jsonDecode(res.stdout as String) as Map<String, dynamic>;
  } finally {
    await dir.delete(recursive: true);
  }
}

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
