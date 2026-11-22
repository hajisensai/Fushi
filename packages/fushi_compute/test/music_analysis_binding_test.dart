import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// 音频分析引擎的 Dart 绑定（`ffc_mana_*`）对真原生库端到端：版本号、同步入口与队列入口都真跑一遍
/// DSP 分析（合成的 120 BPM 敲击），结果按 `.fma` v2 布局读回。模型那两步在 Rust 的 env 门控测试里
/// （native/fushi_compute/src/music_analysis.rs `real_file_sanity`）。
void main() {
  final FushiComputeMusicAnalysis engine = FushiComputeMusicAnalysis.instance;
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('mana_binding_test');
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  /// 44.1 kHz 立体声 s16le：从 0.5 s 起每 0.5 s 一下 60 Hz 衰减敲击（每 4 拍一下更响）。
  String synthPcm(String name, double seconds) {
    const int rate = 44100;
    final int n = (seconds * rate).round();
    final ByteData out = ByteData(n * 4);
    for (int i = 0; i < n; i++) {
      final double t = i / rate;
      double v = 0;
      if (t >= 0.5) {
        final int k = ((t - 0.5) / 0.5).floor();
        final double tt = t - 0.5 - k * 0.5;
        if (tt < 0.15) {
          final double amp = k % 4 == 0 ? 0.9 : 0.5;
          v = amp * math.exp(-tt * 30) * math.sin(2 * math.pi * 60 * tt);
        }
      }
      v += 0.1 * math.sin(2 * math.pi * 440 * t);
      final int s = (v.clamp(-1.0, 1.0) * 32767).round();
      out.setInt16(4 * i, s, Endian.little);
      out.setInt16(4 * i + 2, s, Endian.little);
    }
    final File f = File('${dir.path}/$name.s16le')
      ..writeAsBytesSync(out.buffer.asUint8List());
    return f.path;
  }

  /// 读 `.fma` 头与拍点表，核对 v3 布局（每拍重音段 + 两段中频包络正好对上文件尾）。
  ({int flags, int frames, int beats, double bpm, double trackScale})
  readResult(String path) {
    final Uint8List bytes = File(path).readAsBytesSync();
    final ByteData h = ByteData.sublistView(bytes);
    int u32(int o) => h.getUint32(o, Endian.little);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'FMA1');
    expect(u32(4), engine.formatVersion);
    expect(u32(48), engine.pipelineVersion);
    final int f = u32(16);
    final int b = u32(28);
    final int d = u32(32);
    final int hits = u32(36);
    final int v = u32(40);
    int align4(int n) => (n + 3) & ~3;
    final int end =
        64 +
        align4(6 * f) +
        4 * (b + d + hits) +
        align4(2 * hits) +
        4 * v +
        align4(5 * b) +
        align4(2 * f);
    expect(bytes.length, end);
    return (
      flags: u32(8),
      frames: f,
      beats: b,
      bpm: h.getFloat32(20, Endian.little),
      trackScale: h.getFloat32(52, Endian.little),
    );
  }

  test('versions match the v3 layout', () {
    expect(engine.formatVersion, 3);
    expect(engine.pipelineVersion, 3);
  });

  test('event kinds map from native codes', () {
    expect(FfcManaEventKind.fromCode(3), FfcManaEventKind.updated);
    expect(FfcManaEventKind.fromCode(8), FfcManaEventKind.backendFallback);
    expect(FfcManaEventKind.fromCode(99), isNull);
  });

  test('synchronous analysis writes a readable DSP result', () {
    expect(
      engine.configure(
        ortPath: null,
        beatThisModel: null,
        htdemucsModel: null,
        threads: 1,
      ),
      FfcStatus.ok,
    );
    final String pcm = synthPcm('sync', 12);
    final String out = '${dir.path}/sync.fma';
    final int status = engine.analyzeFileSync(pcmPath: pcm, outPath: out);
    expect(status, FfcStatus.ok, reason: engine.takeLastError());
    final r = readResult(out);
    expect(r.flags, 0);
    expect(r.frames, closeTo(12 * 22050 / 256, 2));
    expect(r.bpm, closeTo(120, 2));
    expect(r.beats, greaterThanOrEqualTo(18));
    expect(r.trackScale, inInclusiveRange(0.45, 1.0));
  });

  test('queued analysis reports started, updated and done', () async {
    expect(engine.start(), FfcStatus.ok);
    final String pcm = synthPcm('queued', 8);
    final String out = '${dir.path}/queued.fma';
    final List<FfcManaEventKind> kinds = <FfcManaEventKind>[];
    final Completer<FfcManaEvent> done = Completer<FfcManaEvent>();
    final StreamSubscription<FfcManaEvent> sub = engine.events.listen((
      FfcManaEvent e,
    ) {
      if (e.token != 4242) return;
      kinds.add(e.kind);
      if (e.kind == FfcManaEventKind.done ||
          e.kind == FfcManaEventKind.failed) {
        done.complete(e);
      }
    });
    addTearDown(sub.cancel);
    expect(
      engine.submit(
        token: 4242,
        pcmPath: pcm,
        outPath: out,
        flags: FfcManaSubmitFlags.deleteInput | FfcManaSubmitFlags.urgent,
      ),
      FfcStatus.ok,
    );
    final FfcManaEvent last = await done.future.timeout(
      const Duration(seconds: 60),
    );
    expect(last.kind, FfcManaEventKind.done, reason: engine.takeLastError());
    expect(kinds.first, FfcManaEventKind.started);
    expect(kinds, contains(FfcManaEventKind.updated));
    expect(File(pcm).existsSync(), isFalse, reason: 'deleteInput');
    expect(readResult(out).beats, greaterThanOrEqualTo(10));
    expect(engine.cancel(987654), FfcManaStatus.unknownToken);
  });
}
