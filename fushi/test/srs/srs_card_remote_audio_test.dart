// 反馈 ffWC0TPq1I：导入的 eggrolls 卡组，例句的播放键点了没声音（Anki 里能出声）。
//
// 这些键是模板 `setEdgeTTS()` 在例句没带音频时自造的在线 TTS 键：`<audio preload="none">`
// 的 `<source>` 指向 Vercel 上的 TTS API，点键 `audio.play()`。该服务不支持 Range（带
// `Range: bytes=0-1` 仍回整份 200），Chromium 照播，Apple WebKit（macOS / iOS 卡面）要求
// HTTP 媒体支持字节范围请求、播不出。修法：页面里源是公网 http(s) 的 `<audio>` 开播时，
// 由宿主走应用代理取回、页面换成 `blob:` 再播（srs_card_remote_audio.dart）。
//
// - 宿主取回：真 HttpServer（不支持 Range 的音频服务、502、网页、octet-stream 的 mp3、超限）；
// - 页面：真实 headless Chrome 跑生产外壳 + eggrolls 模板的 TTS 脚本原样。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_card_remote_audio.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/node_runtime.dart';

/// eggrolls-JLPT10k-v3.5「日-中」模板里在线 TTS 的部分：`setEdgeTTS` / `triggerAudioPlayback`
/// 原样，`CONFIG()` 只留 tts 一项（`enable: 'fallback'` 是 v26.06.13 的默认值），两个域名换成
/// 测试域，`{{text:kanji:SentKanji1}}` 换成渲染后的例句。例句音频字段为空（`SentAudio` 空）。
const String _eggrollsTtsBody = r'''
<main id="BackSide" class="CardSide">
  <ul class="SentenceList">
    <li class="Sentence">
      <div class="SentGroup"><h3 class="SentFurigana">時あたかも春たけなわのころ</h3></div>
      <div class="SentAudio"></div>
    </li>
  </ul>
</main>
<script>
  function CONFIG() {
    const settings = {
      tts: {
        enable: 'fallback',
        hotkey: 'G',
        domain: [
          'https://tts-a.example/',
          'https://tts-b.example/',
        ],
        params: {
          voiceName: 'ja-JP-KeitaNeural,ja-JP-NanamiNeural',
          speed: -4,
        }
      }
    }
    return { settings }
  }
  function setEdgeTTS() {
    const { enable, hotkey, domain, params } = CONFIG().settings.tts
    if (enable === 'never') return

    const getVoice = () => {
      const voices = params.voiceName.split(',').map(v => v.trim())
      return voices.length === 1 ? voices[0] : voices[Math.floor(Math.random() * voices.length)]
    }
    const getSentKanji = (index) => {
      const SentKanji = [
        '時あたかも春たけなわのころ',
        '',
        '',
        ''
      ][index] || ''
      return SentKanji.replace(/・/g, '、')
    }
    document.querySelectorAll('.SentAudio').forEach((el, i) => {
      if (enable === 'fallback' && el.childNodes.length) return
      const text = getSentKanji(i)
      if (!text) return
      const queryString = new URLSearchParams({ ...params, text, voiceName: getVoice() })
      const audio = document.createElement('audio')
      audio.preload = 'none'
      domain.forEach(url => {
        const source = document.createElement('source')
        source.src = `${url}api/aiyue?${queryString}`
        source.type = 'audio/mpeg'
        audio.appendChild(source)
      })
      el.appendChild(audio)
      el.insertAdjacentHTML(
        'beforeend',
        '<a class="tts replay-button soundLink"><svg viewBox="0 0 64 64"><circle cx="32" cy="32" r="29"/><path d="M56.502,32.301l-37.502,20.101l0.329,-40.804l37.173,20.703Z"/></svg></a>',
      )
      el.querySelector('.tts.replay-button').addEventListener('click', e => {
        e.preventDefault()
        document.querySelectorAll('audio').forEach(a => a !== audio && !a.paused && a.pause())
        audio.currentTime = 0
        audio.play()
      })
    })
    triggerAudioPlayback(hotkey)
  }
  function triggerAudioPlayback(hotkey) {
    if (!hotkey) return

    let currentAudioIndex = 0
    let isError = false
    document.addEventListener('keydown', e => {
      if (e.key.toLowerCase() === hotkey.toLowerCase()) {
        const audios = document.querySelectorAll('.CardSide audio')
        audios.forEach((audio) => {
          audio.pause()
          audio.currentTime = 0
        })
        if (!isError) currentAudioIndex = 0
        playNext(audios)
      }
    })
    function playNext(audios) {
      if (currentAudioIndex >= audios.length) return
      const audio = audios[currentAudioIndex]
      audio.play().then(() => {
        audio.onended = () => {
          currentAudioIndex++
          playNext(audios)
        }
        isError = false
      }).catch(() => (isError = true))
    }
  }
  setEdgeTTS()
</script>
''';

SrsCardFaceDocument _doc() => SrsCardFaceDocument.of(
  SrsCardFace(
    cardId: 'egg-tts',
    showingAnswer: true,
    bodyHtml: _eggrollsTtsBody,
    css: '',
    languageCode: 'ja',
    onBridgeKey: (_) {},
    autoplayMedia: true,
  ),
  dark: false,
  background: const Color(0xFFFFFFFF),
  foreground: const Color(0xFF000000),
  accent: const Color(0xFF6750A4),
  onAccent: const Color(0xFFFFFFFF),
  mediaUrlPrefix: 'https://srs.local/media/',
  themedScrollbar: false,
);

/// ID3 头 + 几个字节：最小的「mp3」。
final Uint8List _mp3 = Uint8List.fromList(<int>[
  ...'ID3'.codeUnits,
  4,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  2,
  3,
]);

/// 本机测试服务：
/// - `/tts`：不支持 Range 的在线 TTS（带 Range 也回整份 200、audio/mpeg）；
/// - `/bad`：502；`/page`：text/html；`/octet`：application/octet-stream 的 mp3；
/// - `/big`：audio/mpeg，但比上限大。
Future<HttpServer> _serve() async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  server.listen((HttpRequest req) async {
    final HttpResponse res = req.response;
    switch (req.uri.path) {
      case '/tts':
        res.headers.contentType = ContentType('audio', 'mpeg');
        res.add(_mp3);
      case '/bad':
        res.statusCode = HttpStatus.badGateway;
        res.write('Bad Gateway');
      case '/page':
        res.headers.contentType = ContentType.html;
        res.write('<html>router admin</html>');
      case '/octet':
        res.headers.contentType = ContentType.binary;
        res.add(_mp3);
      case '/big':
        res.headers.contentType = ContentType('audio', 'mpeg');
        res.add(Uint8List(4096));
      default:
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  });
  return server;
}

void main() {
  final NodeTestRuntime browserRuntime = NodeTestRuntime.probe(
    needsChrome: true,
  );

  group('宿主取回远程音频', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      server = await _serve();
      base = 'http://${server.address.address}:${server.port}';
    });
    tearDown(() => server.close(force: true));

    test('不支持 Range 的在线 TTS：整份取回，类型按 Content-Type', () async {
      final SrsRemoteAudio audio = await srsFetchRemoteAudio(<String>[
        '$base/tts?text=x',
      ], clientFactory: HttpClient.new);
      expect(audio.mime, 'audio/mpeg');
      expect(audio.bytes, _mp3);
    });

    test('按候选顺序取：前一个 502 才试下一个（与浏览器选源一致）', () async {
      final SrsRemoteAudio audio = await srsFetchRemoteAudio(<String>[
        '$base/bad',
        '$base/tts',
      ], clientFactory: HttpClient.new);
      expect(audio.bytes, _mp3);
    });

    test('octet-stream 的 mp3 按文件头认出', () async {
      final SrsRemoteAudio audio = await srsFetchRemoteAudio(<String>[
        '$base/octet',
      ], clientFactory: HttpClient.new);
      expect(audio.mime, 'audio/mpeg');
    });

    test('不是音频（网页）、超过上限、非 http(s)、全部失败：抛错并逐条写明原因', () async {
      await expectLater(
        srsFetchRemoteAudio(
          <String>[
            '$base/page',
            '$base/big',
            'file:///etc/passwd',
            '$base/bad',
          ],
          clientFactory: HttpClient.new,
          maxBytes: 1024,
        ),
        throwsA(
          isA<SrsRemoteAudioException>().having(
            (SrsRemoteAudioException e) => e.failures,
            'failures',
            <Matcher>[
              contains('not audio'),
              contains('BodyTooLargeException'),
              contains('not a remote http(s) url'),
              contains('HTTP 502'),
            ],
          ),
        ),
      );
    });

    test('JS 桥应答：成功 {mime, data(base64)}，失败 {error}', () async {
      final Map<String, Object?> ok = await srsRemoteAudioBridgeReply(<dynamic>[
        <dynamic>['$base/bad', '$base/tts'],
      ], clientFactory: HttpClient.new);
      expect(ok['mime'], 'audio/mpeg');
      expect(base64Decode(ok['data']! as String), _mp3);

      final Map<String, Object?> bad = await srsRemoteAudioBridgeReply(
        <dynamic>[
          <dynamic>['$base/bad'],
        ],
        clientFactory: HttpClient.new,
      );
      expect(bad.containsKey('data'), isFalse);
      expect(bad['error'], contains('HTTP 502'));

      final Map<String, Object?> none = await srsRemoteAudioBridgeReply(
        const <dynamic>[],
        clientFactory: HttpClient.new,
      );
      expect(none['error'], isNotNull);
    });
  });

  test('srsIsRemoteAudioUrl：只认公网 http(s)，卡面媒体虚拟域不算', () {
    expect(srsIsRemoteAudioUrl(Uri.parse('https://tts.example/a')), isTrue);
    expect(srsIsRemoteAudioUrl(Uri.parse('http://tts.example/a')), isTrue);
    expect(
      srsIsRemoteAudioUrl(Uri.parse('https://srs.local/media/a.mp3')),
      isFalse,
    );
    expect(
      srsIsRemoteAudioUrl(Uri.parse('fushi-srs://srs.local/media/a.mp3')),
      isFalse,
    );
    expect(srsIsRemoteAudioUrl(Uri.parse('blob:https://x/1')), isFalse);
  });

  test('srsSniffAudioMime：常见音频文件头', () {
    Uint8List b(List<int> v) => Uint8List.fromList(v);
    expect(srsSniffAudioMime(b(<int>[0xFF, 0xFB, 0x90, 0x00])), 'audio/mpeg');
    expect(srsSniffAudioMime(b('OggS\u0000'.codeUnits)), 'audio/ogg');
    expect(
      srsSniffAudioMime(b('RIFF\u0000\u0000\u0000\u0000WAVE'.codeUnits)),
      'audio/wav',
    );
    expect(srsSniffAudioMime(b('fLaC'.codeUnits)), 'audio/flac');
    expect(
      srsSniffAudioMime(b('\u0000\u0000\u0000 ftypM4A '.codeUnits)),
      'audio/mp4',
    );
    expect(srsSniffAudioMime(b('<html>'.codeUnits)), isNull);
  });

  test('外壳装了远程音频助手，且在自动播放闸门之前', () {
    final String shell = _doc().shellHtml;
    final int helper = shell.indexOf('window.__fushiSrsRemoteAudio = {');
    final int gate = shell.indexOf('window.__fushiSrsSetAutoplay = function');
    expect(helper, greaterThan(0));
    expect(gate, greaterThan(helper));
    expect(shell, contains("'$kSrsFetchRemoteAudioHandler'"));
  });

  test(
    '真实 Chrome：eggrolls 在线 TTS 键经宿主取回、blob: 播放；失败 / 暂停 / 换卡 / 本地媒体',
    () async {
      final String node = browserRuntime.requireNode();
      final SrsCardFaceDocument d = _doc();
      final Directory temp = Directory.systemTemp.createTempSync('srs-tts-');
      try {
        final File payload = File('${temp.path}/payload.json')
          ..writeAsStringSync(
            jsonEncode(<String, String>{
              'shell': d.shellHtml,
              'calls': d.fullCardScript,
              'handler': kSrsFetchRemoteAudioHandler,
            }),
          );
        final ProcessResult result = await Process.run(node, <String>[
          'test/srs/srs_card_remote_audio_harness.mjs',
          payload.path,
        ]).timeout(const Duration(seconds: 80));
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('PASS 5 browser cases'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: browserRuntime.skipReason,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
