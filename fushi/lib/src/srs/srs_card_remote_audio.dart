/// 卡面页面里的**远程音频**（`<audio>` 的 http(s) 源）由宿主取回、以 `blob:` 交给页面播放
/// （反馈 ffWC0TPq1I，BUG-4378）。
///
/// 为什么：导入的模板会在卡面上自己造在线 TTS 键——eggrolls 的 `setEdgeTTS()` 在例句没带
/// 音频时插一个 `<audio preload="none">`，`<source>` 指向在线 TTS 服务（Vercel 上的 API
/// 路由），点键 `audio.play()`。这类服务不支持 Range：带 `Range: bytes=0-1` 也回整份
/// `200`。Chromium（Anki 桌面、WebView2、Android WebView）照播，Apple 的 WebKit（macOS /
/// iOS 卡面的 WKWebView）走 AVFoundation 拉流，要求 HTTP 媒体服务器支持字节范围请求，拿不到
/// `206` 就播不出——于是 Fushi 上点了没反应、Anki 里能出声。卡面 WebView 的网络也不走 Fushi
/// 的代理设置。
///
/// 做法：页面里给 `<audio>` 开播时（自动播放闸门的 `play()` 包装，srs_card_autoplay.dart），
/// 源是公网 http(s) 地址的，先经 JS 桥把候选地址（`src`，或按文档顺序的各个 `<source>`）交给
/// 宿主；宿主走应用代理出口按顺序取（与浏览器选源一样，前一个失败才试下一个），取到的字节回给
/// 页面做成 `blob:` 地址换上再播。`blob:` 由浏览器内存供数，范围请求天然支持，五端同一条路。
/// 只接音频：视频可能是几百 MB 的流，不整份搬运。
library;

import 'dart:convert' show base64Encode;
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/srs/srs_card_media.dart' show kSrsMediaHost;
import 'package:fushi_engine/utils/net/bounded_read.dart';

/// 卡面 JS 桥：取远程音频的 handler 名。
const String kSrsFetchRemoteAudioHandler = 'onSrsFetchRemoteAudio';

/// 单段远程音频的字节上限（在线 TTS 一句几十 KB；超过就是拿错了东西）。
const int kSrsRemoteAudioMaxBytes = 32 * 1024 * 1024;

/// [url] 是不是要由宿主代取的公网音频地址：http(s)，且不是卡面自己的媒体虚拟域。
bool srsIsRemoteAudioUrl(Uri url) =>
    (url.scheme == 'http' || url.scheme == 'https') &&
    url.host.isNotEmpty &&
    url.host != kSrsMediaHost;

/// 取回的音频。
class SrsRemoteAudio {
  const SrsRemoteAudio({required this.mime, required this.bytes});

  /// 交给页面 `Blob` 的类型。
  final String mime;

  final Uint8List bytes;
}

/// 所有候选地址都没取到；[failures] 逐条写明原因（只带主机名，不带查询串）。
class SrsRemoteAudioException implements Exception {
  const SrsRemoteAudioException(this.failures);

  final List<String> failures;

  @override
  String toString() => 'remote audio unavailable: ${failures.join('; ')}';
}

bool _startsWith(Uint8List b, String magic, [int offset = 0]) {
  final List<int> m = magic.codeUnits;
  if (b.length < offset + m.length) return false;
  for (int i = 0; i < m.length; i++) {
    if (b[offset + i] != m[i]) return false;
  }
  return true;
}

/// 按文件头认音频格式；认不出返回 null。
String? srsSniffAudioMime(Uint8List b) {
  if (_startsWith(b, 'ID3')) return 'audio/mpeg';
  // MPEG 音频帧同步字：11 个 1。
  if (b.length >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) {
    return 'audio/mpeg';
  }
  if (_startsWith(b, 'OggS')) return 'audio/ogg';
  if (_startsWith(b, 'RIFF') && _startsWith(b, 'WAVE', 8)) return 'audio/wav';
  if (_startsWith(b, 'fLaC')) return 'audio/flac';
  if (_startsWith(b, 'ftyp', 4)) return 'audio/mp4';
  return null;
}

/// 响应是不是音频：`Content-Type` 是 `audio/*`（或 `application/ogg`）就按它；否则（缺省、
/// `application/octet-stream` 之类）看文件头。都不是返回 null——宿主只替页面搬音频，
/// 不把别的内容（网页、局域网接口的应答）读回给卡面脚本。
String? srsRemoteAudioMime(String? contentType, Uint8List bytes) {
  final String? declared = contentType?.toLowerCase();
  if (declared != null &&
      (declared.startsWith('audio/') || declared == 'application/ogg')) {
    return declared;
  }
  return srsSniffAudioMime(bytes);
}

/// 按顺序取 [urls]，返回第一个取到的音频；全部失败抛 [SrsRemoteAudioException]。
Future<SrsRemoteAudio> srsFetchRemoteAudio(
  List<String> urls, {
  required HttpClient Function() clientFactory,
  int maxBytes = kSrsRemoteAudioMaxBytes,
}) async {
  final List<String> failures = <String>[];
  final HttpClient client = clientFactory();
  try {
    for (final String raw in urls) {
      final Uri? url = Uri.tryParse(raw);
      if (url == null || !srsIsRemoteAudioUrl(url)) {
        failures.add('not a remote http(s) url');
        continue;
      }
      try {
        final HttpClientRequest request = await client.getUrl(url);
        final HttpClientResponse response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          failures.add('${url.host}: HTTP ${response.statusCode}');
          continue;
        }
        final Uint8List bytes = await readBoundedBytes(response, maxBytes);
        final String? mime = srsRemoteAudioMime(
          response.headers.contentType?.mimeType,
          bytes,
        );
        if (mime == null) {
          failures.add(
            '${url.host}: not audio (${response.headers.contentType})',
          );
          continue;
        }
        return SrsRemoteAudio(mime: mime, bytes: bytes);
      } on BodyTooLargeException catch (e) {
        failures.add('${url.host}: $e');
      } on IOException catch (e) {
        failures.add('${url.host}: $e');
      }
    }
  } finally {
    client.close(force: true);
  }
  throw SrsRemoteAudioException(failures);
}

/// JS 桥的应答：成功 `{mime, data}`（`data` 是 base64），失败 `{error}`。
/// [arguments] 是页面传来的 `[urls]`。
Future<Map<String, Object?>> srsRemoteAudioBridgeReply(
  List<dynamic> arguments, {
  required HttpClient Function() clientFactory,
  int maxBytes = kSrsRemoteAudioMaxBytes,
}) async {
  final Object? first = arguments.isEmpty ? null : arguments.first;
  final List<String> urls = first is List
      ? <String>[
          for (final Object? u in first)
            if (u is String) u,
        ]
      : const <String>[];
  if (urls.isEmpty) {
    return <String, Object?>{'error': 'no remote audio url'};
  }
  try {
    final SrsRemoteAudio audio = await srsFetchRemoteAudio(
      urls,
      clientFactory: clientFactory,
      maxBytes: maxBytes,
    );
    return <String, Object?>{
      'mime': audio.mime,
      'data': base64Encode(audio.bytes),
    };
  } on SrsRemoteAudioException catch (e) {
    return <String, Object?>{'error': e.toString()};
  }
}

/// 页面侧：`window.__fushiSrsRemoteAudio`，供自动播放闸门的 `play()` 包装调用
/// （srs_card_autoplay.dart 的 [kSrsCardAutoplayGateScript]）。
///
/// - `sources(el)`：`<audio>` 的源全是公网 http(s) 时返回按顺序的候选地址（`src` 属性优先，
///   否则各个 `<source src>`），否则 null（本地 / `blob:` / 媒体库地址照常由页面自己播）。
///   宿主桥不在（卡面之外）也返回 null。
/// - `load(urls)`：经桥取回 → `blob:` 地址；同一组地址在本面内只取一次。失败以
///   `NotSupportedError` 拒绝（与浏览器「没有可用源」同一形态，模板的 `catch` 照常接住）。
/// - `release()`：换卡 / 翻面时撤销本面造出的 `blob:` 地址。
const String kSrsCardRemoteAudioScript =
    '''
(function(){
  if (window.__fushiSrsRemoteAudio) return;
  var cache = {};
  var made = [];
  function bridge(){
    var b = window.flutter_inappwebview;
    return b && typeof b.callHandler === 'function' ? b : null;
  }
  function isRemote(u){
    try {
      var x = new URL(u);
      return (x.protocol === 'http:' || x.protocol === 'https:') &&
        x.hostname !== '$kSrsMediaHost';
    } catch (e) { return false; }
  }
  function sources(el){
    if (!el || el.tagName !== 'AUDIO' || !bridge()) return null;
    if (el.hasAttribute('src')) return isRemote(el.src) ? [el.src] : null;
    var out = [];
    var kids = el.children;
    for (var i = 0; i < kids.length; i++) {
      var k = kids[i];
      if (k.tagName !== 'SOURCE' || !k.hasAttribute('src')) continue;
      if (!isRemote(k.src)) return null;
      out.push(k.src);
    }
    return out.length ? out : null;
  }
  function unsupported(msg){
    try { return new DOMException(msg, 'NotSupportedError'); }
    catch (e) { var err = new Error(msg); err.name = 'NotSupportedError'; return err; }
  }
  function decode(b64){
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }
  function load(urls){
    var key = urls.join(' ');
    if (cache[key]) return cache[key];
    var p = Promise.resolve(bridge().callHandler('$kSrsFetchRemoteAudioHandler', urls))
      .then(function(r){
        if (!r || typeof r.data !== 'string') {
          throw unsupported((r && r.error) || 'remote audio unavailable');
        }
        var url = URL.createObjectURL(new Blob([decode(r.data)], {type: r.mime || ''}));
        made.push(url);
        return url;
      });
    cache[key] = p;
    p['catch'](function(){ if (cache[key] === p) delete cache[key]; });
    return p;
  }
  function release(){
    cache = {};
    for (var i = 0; i < made.length; i++) {
      try { URL.revokeObjectURL(made[i]); } catch (e) {}
    }
    made = [];
  }
  window.__fushiSrsRemoteAudio = { sources: sources, load: load, release: release };
})();
''';
