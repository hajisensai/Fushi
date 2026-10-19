import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';

/// 网页播放器主世界脚本（netflix-bridge → subtitle-adapters → subtitle-providers → glue，与
/// app 注入同序）在 node 里对一个假 Netflix 页面跑：播放控制走正片播放器 API、快照读 API 时间、
/// 打断态、轨清单、整轨 key 带 trackId、原生字幕在装载即藏。没有 node 就跳过。
void main() {
  final bool hasNode = () {
    try {
      return Process.runSync('node', <String>['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();

  String asset(String path) => File(path).readAsStringSync();

  /// [scenario] 是一段 JS：可用 `h`（harness 句柄）与 `fw`（window.__fushiWebVideo），最后
  /// `out(x)` 输出结果。[prelude] 在 glue 之前执行（宿主开关）。
  Future<Object?> run(
    String scenario, {
    String setup = '',
    String prelude = '',
  }) async {
    final String harness =
        '''
const h = { posted: [], timers: [], styles: {}, query: {}, listeners: {}, video: null };
globalThis.window = globalThis;
globalThis.location = { hostname: 'www.netflix.com', href: 'https://www.netflix.com/watch/81001',
  pathname: '/watch/81001', origin: 'https://www.netflix.com' };
window.origin = location.origin;
function makeEl(tag) {
  return { tagName: tag, id: '', textContent: '', attrs: {}, isConnected: false, parentElement: null,
    remove() { delete h.styles[this.id]; this.isConnected = false; },
    setAttribute(k, v) { this.attrs[k] = v; }, removeAttribute(k) { delete this.attrs[k]; },
    hasAttribute(k) { return k in this.attrs; },
    appendChild(c) { if (c.id) h.styles[c.id] = c; c.isConnected = true; },
    addEventListener(t, fn) { (this.l = this.l || {})[t] = fn; }, removeEventListener(t) { if (this.l) delete this.l[t]; } };
}
const head = makeEl('head');
globalThis.document = { head, documentElement: head, body: makeEl('body'), title: 'Netflix', fullscreenElement: null,
  getElementById(id) { return h.styles[id] || null; },
  createElement: makeEl,
  querySelector(sel) {
    if (sel === 'video') return h.video;
    const parts = sel.split(',').map((s) => s.trim());
    for (const k in h.query) if (parts.includes(k)) return h.query[k];
    return null;
  },
  querySelectorAll(sel) { return sel === 'video' && h.video ? [h.video] : []; },
  addEventListener() {} };
globalThis.MutationObserver = class { observe() {} disconnect() {} };
globalThis.setInterval = () => 0; globalThis.clearInterval = () => {};
globalThis.setTimeout = (fn) => { h.timers.push(fn); return h.timers.length; };
globalThis.Event = class { constructor(t) { this.type = t; } };
window.dispatchEvent = () => true;
window.addEventListener = (t, fn) => { (h.listeners[t] = h.listeners[t] || []).push(fn); };
window.postMessage = (data) => { for (const fn of h.listeners.message || []) fn({ source: window, origin: window.origin, data }); };
window.flutter_inappwebview = { callHandler(name, msg) { h.posted.push(msg); } };
h.flush = () => { while (h.timers.length) h.timers.shift()(); };
h.player = { time: 61000, paused: true, duration: 1440000, calls: [],
  text: [
    { trackId: 'T:ja', bcp47: 'ja', displayName: '日本語', trackType: 'PRIMARY' },
    { trackId: 'T:ja-img', bcp47: 'ja', displayName: '日本語（画像）', trackType: 'PRIMARY', isImageBased: true },
    { trackId: 'T:none', isNoneTrack: true },
  ],
  audio: [
    { trackId: 'A:en', bcp47: 'en', displayName: 'English', trackType: 'PRIMARY' },
    { trackId: 'A:ja', bcp47: 'ja', displayName: '日本語', trackType: 'PRIMARY' },
  ],
  curText: null, curAudio: null };
h.player.curText = h.player.text[0]; h.player.curAudio = h.player.audio[0];
h.sessions = ['watch-81001'];
const api = {
  getCurrentTime: () => h.player.time, isPaused: () => h.player.paused, getDuration: () => h.player.duration,
  play: () => { h.player.calls.push('play'); h.player.paused = false; },
  pause: () => { h.player.calls.push('pause'); h.player.paused = true; },
  seek: (ms) => { h.player.calls.push('seek:' + ms); h.player.time = ms; },
  setVolume: (v) => h.player.calls.push('vol:' + v), setMuted: (m) => h.player.calls.push('muted:' + m),
  getTimedTextTrackList: () => h.player.text, getTimedTextTrack: () => h.player.curText,
  setTimedTextTrack: (t) => { h.player.curText = t; },
  getAudioTrackList: () => h.player.audio, getAudioTrack: () => h.player.curAudio,
  setAudioTrack: (t) => { h.player.curAudio = t; },
};
window.netflix = { appContext: { state: { playerApp: { getAPI: () => ({ videoPlayer: {
  getAllPlayerSessionIds: () => h.sessions, getVideoPlayerBySessionId: () => api } }) } } } };
h.video = Object.assign(makeEl('video'), { currentTime: 5, paused: false, duration: 1440, videoWidth: 1920,
  videoHeight: 1080, playbackRate: 1, volume: 1, muted: false, readyState: 4, seeking: false, error: null });
function out(x) { console.log(JSON.stringify(x)); }
$setup
${asset(kWebVideoNetflixBridgeAsset)}
${asset(kWebVideoAdaptersAsset)}
${asset(kWebVideoProvidersAsset)}
$prelude
${asset(kWebVideoGlueAsset)}
const fw = window.__fushiWebVideo;
$scenario
''';
    final Directory dir = await Directory.systemTemp.createTemp('web_glue');
    try {
      final File f = File('${dir.path}/h.js')..writeAsStringSync(harness);
      final ProcessResult r = await Process.run(
        'node',
        <String>[f.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final String stdout = (r.stdout as String).trim();
      return jsonDecode(stdout.split('\n').last);
    } finally {
      await dir.delete(recursive: true);
    }
  }

  test('原生字幕在 glue 装载即藏（宿主开关），含图片字幕层；没开关不藏', () async {
    final Object? on = await run(
      'out(document.getElementById("fushi-hide-native-subtitles").textContent);',
      prelude: kWebVideoHideNativeSubtitlesPrelude,
    );
    expect(on, contains('.image-based-timed-text'));
    expect(on, contains('.player-timedtext'));
    final Object? off = await run(
      'out(document.getElementById("fushi-hide-native-subtitles") === null);',
    );
    expect(off, isTrue);
  }, skip: !hasNode);

  test('快照的位置 / 暂停态读正片播放器 API，不读滞后的 <video>', () async {
    final Object? s = await run('out(JSON.parse(fw.state()));');
    final Map<String, dynamic> state = s! as Map<String, dynamic>;
    expect(state['t'], 61000);
    expect(state['paused'], isTrue);
    expect(state['dur'], 1440000);
    expect(state['blk'], '');
  }, skip: !hasNode);

  test('播放控制走播放器 API；seek 回执经 bridge 带 id 回到 Dart', () async {
    final Object? r = await run('''
const res = [fw.play(), fw.pause(), fw.seek(90000, 4), fw.setVolume(0.5, false)];
out({ res, calls: h.player.calls, done: h.posted.filter((m) => m.type === 'seekDone') });
''');
    final Map<String, dynamic> m = r! as Map<String, dynamic>;
    expect(m['res'], <Object>['ok', 'ok', 'bridge', 'ok']);
    expect(m['calls'], <String>[
      'play',
      'pause',
      'seek:90000',
      'vol:0.5',
      'muted:false',
    ]);
    final List<dynamic> done = m['done'] as List<dynamic>;
    expect(done, hasLength(1));
    expect(done.single['ok'], isTrue);
    expect(done.single['id'], 4);
  }, skip: !hasNode);

  test('没有 watch 会话：seek 不发、返回 no-player（Dart 立即结束跳转在途）', () async {
    final Object? r = await run(
      'out(fw.seek(1000, 1));',
      setup: "h.sessions = ['motion-billboard-1'];",
    );
    expect(r, 'no-player');
  }, skip: !hasNode);

  test('打断态：「还在看吗」与带错误码的播放错误页进快照 blk', () async {
    final Object? r = await run('''
h.query['[data-uia="interrupt-autoplay-continue"]'] = makeEl('button');
const a = JSON.parse(fw.state()).blk;
delete h.query['[data-uia="interrupt-autoplay-continue"]'];
h.query['[data-uia="player-error"]'] = Object.assign(makeEl('div'), { textContent: 'Whoops. Error Code: M7375-1003' });
const b = JSON.parse(fw.state()).blk;
delete h.query['[data-uia="player-error"]'];
const c = JSON.parse(fw.state()).blk;
out([a, b, c]);
''');
    expect(r, <String>['interrupt', 'error:M7375-1003', '']);
    final WebVideoPlaybackState? s = parseWebVideoStatePayload(
      <String, Object?>{'blk': 'error:M7375-1003', 'hasVideo': true},
    );
    expect(s!.isBlocked, isTrue);
    expect(s.blockerErrorCode, 'M7375-1003');
  }, skip: !hasNode);

  test('字幕 / 音轨清单：图片轨照样列出并标记，Dart 解析得出类型与当前轨', () async {
    final Object? r = await run('out(JSON.parse(fw.state()));');
    final WebVideoPlaybackState s = parseWebVideoStatePayload(r)!;
    expect(s.siteTracks.map((WebVideoSiteTrack t) => t.id), <String>[
      'T:ja',
      'T:ja-img',
    ]);
    expect(s.siteTracks[1].imageBased, isTrue);
    expect(s.siteTracks[0].type, 'PRIMARY');
    expect(s.siteTrackCurrent, 'T:ja');
    expect(s.siteAudioTracks.map((WebVideoSiteTrack t) => t.lang), <String>[
      'en',
      'ja',
    ]);
    expect(s.siteAudioTrackCurrent, 'A:en');
  }, skip: !hasNode);

  test('选音轨走播放器 API', () async {
    final Object? r = await run(
      "out([fw.selectNetflixAudioTrack('A:ja'), h.player.curAudio.trackId, fw.selectNetflixAudioTrack('nope')]);",
    );
    expect(r, <Object>[true, 'A:ja', false]);
  }, skip: !hasNode);

  test('整轨 key 带 trackId（同语言多轨不撞），失败回执变成 trackFailed', () async {
    final Object? r = await run(r'''
const vtt = 'WEBVTT\n\n00:01.000 --> 00:02.000\nhello\n';
window.postMessage({ __fushiNf: 'cues', videoId: '81001', lang: 'en', trackId: 'T:en', format: 'webvtt', text: vtt });
window.postMessage({ __fushiNf: 'cues', videoId: '81001', lang: 'en', trackId: 'T:en-cc', format: 'webvtt', text: vtt });
window.postMessage({ __fushiNf: 'cuesFailed', videoId: '81001', lang: 'ja', trackId: 'T:ja', err: 'HTTP 403' });
h.flush();
out(h.posted.filter((m) => m.type === 'track' || m.type === 'trackFailed'));
''');
    final List<dynamic> msgs = r! as List<dynamic>;
    final List<WebVideoTrack> tracks = <WebVideoTrack>[
      for (final dynamic m in msgs)
        if (m['type'] == 'track') parseWebVideoTrackPayload(m, bookUid: 'b')!,
    ];
    expect(tracks.map((WebVideoTrack t) => t.key).toSet(), <String>{
      '81001|en~T:en',
      '81001|en~T:en-cc',
    });
    expect(tracks.every((WebVideoTrack t) => t.lang == 'en'), isTrue);
    expect(tracks.map((WebVideoTrack t) => t.siteTrackId).toSet(), <String>{
      'T:en',
      'T:en-cc',
    });
    final dynamic failed = msgs.firstWhere(
      (dynamic m) => m['type'] == 'trackFailed',
    );
    expect(parseWebVideoTrackFailedKey(failed), '81001|ja~T:ja');
    expect(
      const WebVideoSiteTrack(
        id: 'T:ja',
        lang: 'ja',
        name: '',
      ).storeKey('81001'),
      '81001|ja~T:ja',
    );
  }, skip: !hasNode);

  test('YouTube 画质跟随「YouTube 画质」目标：起播带下、播放中改、自愈重入不丢', () async {
    final Object? r = await run('''
location.hostname = 'www.youtube.com';
let tick = null;
// 只截画质轮询（2 s）；自动连播守卫（1 s）不管。
globalThis.setInterval = (fn, ms) => { if (ms === 2000) tick = fn; return 1; };
const yt = { cur: 'auto', set: [],
  getAvailableQualityLevels: () => ['hd2160', 'hd1440', 'hd1080', 'hd720', 'large', 'medium', 'auto'],
  getPlaybackQuality() { return this.cur; },
  setPlaybackQualityRange(a) { this.set.push(a); this.cur = a; } };
h.styles.movie_player = yt;
const picks = [];
const step = () => { tick(); picks.push(yt.cur); };
fw.setVideoOnly(true, 720); step();
fw.setQualityTarget(1080); step();
fw.setVideoOnly(true); step();
fw.setQualityTarget(0); step();
fw.setQualityTarget(240); step();
out(picks);
''');
    expect(r, <String>['hd720', 'hd1080', 'hd1080', 'hd2160', 'medium']);
  }, skip: !hasNode);

  test('站点 bridge 按当前文档 host 自判：别的站上包住的 bridge 不执行', () async {
    Future<Object?> probe(String host) async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'bridge_guard',
      );
      try {
        final String js =
            '''
globalThis.location = { hostname: ${jsonEncode(host)} };
globalThis.ran = [];
${webVideoHostGuardedBridgeSource("ran.push('netflix');", kWebVideoNetflixHosts)}
${webVideoHostGuardedBridgeSource("ran.push('youtube');", kWebVideoYoutubeHosts)}
${webVideoHostGuardedBridgeSource("ran.push('stream'); var streamGlobal = 1;", kWebVideoStreamBridgeHosts)}
console.log(JSON.stringify({ ran, global: typeof streamGlobal }));
''';
        final File f = File('${dir.path}/g.js')..writeAsStringSync(js);
        final ProcessResult r = await Process.run('node', <String>[f.path]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return jsonDecode((r.stdout as String).trim());
      } finally {
        await dir.delete(recursive: true);
      }
    }

    expect(await probe('www.netflix.com'), <String, Object>{
      'ran': <String>['netflix'],
      'global': 'undefined',
    });
    expect(
      ((await probe('m.youtube.com'))! as Map<String, dynamic>)['ran'],
      <String>['youtube'],
    );
    expect(await probe('www.hulu.jp'), <String, Object>{
      'ran': <String>['stream'],
      'global': 'number',
    }, reason: '块包裹而非函数包裹：bridge 的顶层声明保持全局');
    expect(
      ((await probe('evilnetflix.com'))! as Map<String, dynamic>)['ran'],
      <String>[],
    );
    expect(
      ((await probe('hulu.jp'))! as Map<String, dynamic>)['ran'],
      <String>[],
    );
  }, skip: !hasNode);
}
