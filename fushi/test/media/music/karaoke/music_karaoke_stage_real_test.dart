import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_progress.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_stage_plan.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';

/// 卡拉 OK 字幕页（音乐 P3）对**真 libmpv** 的验收（设计 §13 P3 退出标准）：
///
/// 1. **`\k` `\kf` `\ko` 擦色语义**：同一份 ASS 经本页管线（曲目音频 + 画布封面轨 +
///    `sub-add` + [musicKaraokeSubtitleProperties]）截帧，按像素颜色分出「已高亮 / 未高亮 /
///    描边」，与结构化一路（Rust 解析 → [karaokeSyllableProgress]）在同一时刻的进度逐个对上。
/// 2. **字幕组特效 ASS 与 mpv 单独播放逐帧一致**：本页管线 vs「mpv 放一段视频 + `sub-files`
///    外挂这份 ASS、其余全默认」，在特效区间按 25 fps 逐帧截图、逐像素比较。
/// 3. **MV 偏移**：MV + `sub-delay`（[musicKaraokeSubDelaySeconds]）在 MV 时刻 v 的画面 =
///    参考播放在脚本时刻 `v − delay` 的画面。
/// 4. **CD+G**：曲目音频 + `video-add` 同名 `.cdg`，统一 FFmpeg 的 `cdgraphics` 解出画面、
///    与音频同一时间轴。
///
/// 截图走 `screenshot-to-file … subtitles`：在视频分辨率上由同一 libass 合成，量的是「同一
/// 时刻 libass 画出来的东西」。纹理显示路径（media_kit 渲染到 Flutter 纹理时 libass 按纹理
/// 尺寸排字）不在这里量。
///
/// 样本全部由本测试生成（ASS 手写、音频 / 视频 / CD+G 程序合成），不依赖外部素材。
/// 需要真实 libmpv：`FUSHI_TEST_LIBMPV` 指向 libmpv-2.dll（其依赖 DLL 所在目录要在 PATH 上），
/// 或先构建 Windows Debug；生成视频需要 ffmpeg（`FUSHI_FFMPEG` 或捆绑 / PATH）。
String? _libmpvPath() {
  final String? override = Platform.environment['FUSHI_TEST_LIBMPV'];
  final String path = override ?? 'build/windows/x64/runner/Debug/libmpv-2.dll';
  return File(path).existsSync() ? File(path).absolute.path : null;
}

Future<void> _ff(List<String> args) async {
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-v',
    'error',
    ...args,
  ], const Duration(seconds: 120));
  if (!r.isSuccess) throw StateError('ffmpeg failed: ${r.failureSummary}');
}

const String _styles =
    '[V4+ Styles]\n'
    'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
    'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, '
    'ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, '
    'MarginR, MarginV, Encoding\n';
const String _eventsHeader =
    '[Events]\n'
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
    'Effect, Text\n';

/// 擦色语义样本：主色红、次色蓝、描边绿；每行两个等宽音节「WWW」。
const String _semanticsAss =
    '[Script Info]\nScriptType: v4.00+\nPlayResX: 640\nPlayResY: 360\n'
    'WrapStyle: 2\n\n'
    '$_styles'
    'Style: K,Arial,110,&H000000FF,&H00FF0000,&H0000FF00,&H00000000,1,0,0,0,'
    '100,100,0,0,1,8,0,5,0,0,0,1\n\n'
    '$_eventsHeader'
    'Dialogue: 0,0:00:01.00,0:00:03.00,K,,0,0,0,,{\\k100}WWW{\\k100}WWW\n'
    'Dialogue: 0,0:00:03.00,0:00:05.00,K,,0,0,0,,{\\kf100}WWW{\\kf100}WWW\n'
    'Dialogue: 0,0:00:05.00,0:00:07.00,K,,0,0,0,,{\\ko100}WWW{\\ko100}WWW\n';

/// 字幕组 / templater 风格的特效样本：注释掉的原始卡拉 OK 行 + `fx` 逐字行（`\move`
/// `\t` `\fad` `\blur` `\frz` + `\org`）、`\clip` 擦除、`\p1` 矢量粒子。
String _effectsAss() {
  final StringBuffer b = StringBuffer()
    ..write(
      '[Script Info]\nScriptType: v4.00+\nPlayResX: 1280\nPlayResY: 720\n'
      'WrapStyle: 2\nScaledBorderAndShadow: yes\n\n',
    )
    ..write(_styles)
    ..write(
      'Style: Kara,Arial,64,&H00FFFFFF,&H00FF8000,&H00402000,&H80000000,1,0,0,0,'
      '100,100,2,0,1,4,2,8,40,40,40,1\n'
      'Style: Drop,Arial,30,&H0000FFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,'
      '100,100,0,0,1,0,0,7,0,0,0,1\n\n',
    )
    ..write(_eventsHeader)
    ..write(
      'Comment: 0,0:00:01.00,0:00:04.00,Kara,,0,0,0,karaoke,'
      '{\\k50}よ{\\k50}ぞ{\\k50}ら{\\k50}に{\\k50}ひ{\\k50}か{\\k50}る\n',
    );
  const List<String> syllables = <String>['よ', 'ぞ', 'ら', 'に', 'ひ', 'か', 'る'];
  for (int i = 0; i < syllables.length; i++) {
    final int x = 400 + i * 80;
    final int start = 100 + i * 50; // 厘秒
    String cs(int v) =>
        '0:00:${(v ~/ 100).toString().padLeft(2, '0')}.'
        '${(v % 100).toString().padLeft(2, '0')}';
    // 入场：从下方滑入、淡入；唱到时放大变色；唱完旋转淡出。
    b.write(
      'Dialogue: 1,${cs(start - 50)},${cs(start)},Kara,,0,0,0,fx,'
      '{\\an5\\move($x,700,$x,200)\\fad(200,0)\\blur2}${syllables[i]}\n',
    );
    b.write(
      'Dialogue: 1,${cs(start)},${cs(start + 50)},Kara,,0,0,0,fx,'
      '{\\an5\\pos($x,200)\\t(0,250,\\fscx150\\fscy150\\1c&H0080FF&\\3c&HFFFFFF&)'
      '\\t(250,500,\\fscx100\\fscy100)}${syllables[i]}\n',
    );
    b.write(
      'Dialogue: 1,${cs(start + 50)},${cs(400)},Kara,,0,0,0,fx,'
      '{\\an5\\pos($x,200)\\org(640,360)\\t(\\frz-30)\\fad(0,300)}'
      '${syllables[i]}\n',
    );
    // 粒子：每个音节一颗星形矢量，沿弧线飞出。
    b.write(
      'Dialogue: 0,${cs(start)},${cs(start + 80)},Drop,,0,0,0,fx,'
      '{\\an7\\move($x,200,${x + 60},120)\\t(\\frz180\\alpha&HFF&)\\p1}'
      'm 0 -10 l 3 -3 10 -3 4 2 6 10 0 5 -6 10 -4 2 -10 -3 -3 -3{\\p0}\n',
    );
  }
  // `\clip` 擦除的副字幕行。
  b.write(
    'Dialogue: 0,0:00:01.00,0:00:04.00,Drop,,0,0,0,fx,'
    '{\\an7\\pos(380,420)\\clip(380,400,380,480)\\t(0,3000,\\clip(380,400,940,480))}'
    'yozora ni hikaru\n',
  );
  return b.toString();
}

/// 不带头的 PCM WAV（静音，48 kHz 单声道 s16）。
Uint8List _silentWav(Duration d) {
  const int rate = 48000;
  final int samples = rate * d.inMilliseconds ~/ 1000;
  final int dataLen = samples * 2;
  final ByteData h = ByteData(44)
    ..setUint32(0, 0x52494646) // RIFF
    ..setUint32(4, 36 + dataLen, Endian.little)
    ..setUint32(8, 0x57415645) // WAVE
    ..setUint32(12, 0x666d7420) // fmt
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(36, 0x64617461) // data
    ..setUint32(40, dataLen, Endian.little);
  return Uint8List.fromList(<int>[
    ...h.buffer.asUint8List(),
    ...Uint8List(dataLen),
  ]);
}

/// 合成 CD+G：300 包 / 秒、每包 24 字节（command 0x09 = TV graphics）。0 s 起整屏红，
/// [switchAt] 起整屏绿。每次清屏（Memory Preset，cdg 解复用器把它标成关键帧）后立刻
/// 重载调色板，seek 到任意关键帧都能解出正确颜色。
///
/// 形状照真实 `.cdg`：大部分是空包，图形指令稀疏（[noopEvery] 个包一个不改画面的 XOR
/// 空图块，默认 0.1 s，相当于歌词擦色的节奏）。解码器只在图形指令上出帧，所以跳转后的
/// 画面在下一个指令包时出现。[noopEvery] 为 null = 只有换屏的四个包（极端稀疏：
/// libavformat 的探测分只有个位数，见 [musicKaraokeCdgProperties]）。
Uint8List _cdg(Duration length, Duration switchAt, {int? noopEvery = 30}) {
  final int packets = length.inMilliseconds * 300 ~/ 1000;
  final Uint8List out = Uint8List(packets * 24);
  void packet(int index, int instruction, List<int> data) {
    final int o = index * 24;
    out[o] = 0x09;
    out[o + 1] = instruction;
    for (int i = 0; i < data.length && i < 16; i++) {
      out[o + 4 + i] = data[i] & 0x3F;
    }
  }

  // 颜色 0 黑、1 红、2 绿（12 位 RGB 拆成两个 6 位字节）。
  List<int> palette() {
    const List<int> colors = <int>[0x000, 0xF00, 0x0F0, 0, 0, 0, 0, 0];
    return <int>[
      for (final int c in colors) ...<int>[(c >> 6) & 0x3F, c & 0x3F],
    ];
  }

  const int memoryPreset = 1;
  const int loadColorsLow = 30;
  const int tileXor = 38;
  if (noopEvery != null) {
    for (int i = 2; i < packets; i += noopEvery) {
      packet(i, tileXor, const <int>[]);
    }
  }
  final int sw = switchAt.inMilliseconds * 300 ~/ 1000;
  packet(0, memoryPreset, <int>[1, 0]);
  packet(1, loadColorsLow, palette());
  packet(sw, memoryPreset, <int>[2, 0]);
  packet(sw + 1, loadColorsLow, palette());
  return out;
}

class _Shot {
  _Shot(this.image);
  final img.Image image;
}

void main() {
  final String? libmpv = _libmpvPath();
  final String? skip = libmpv == null
      ? 'Set FUSHI_TEST_LIBMPV to libmpv-2.dll (or build Windows Debug)'
      : null;
  late Directory dir;
  String at(String name) => '${dir.path}${Platform.pathSeparator}$name';

  setUpAll(() async {
    if (libmpv == null) return;
    MediaKit.ensureInitialized(libmpv: libmpv);
    dir = Directory.systemTemp.createTempSync('karaoke_stage_');
    File(
      at('song.wav'),
    ).writeAsBytesSync(_silentWav(const Duration(seconds: 10)));
    File(at('semantics.ass')).writeAsStringSync(_semanticsAss);
    File(at('effects.ass')).writeAsStringSync(_effectsAss());
    File(at('song.cdg')).writeAsBytesSync(
      _cdg(const Duration(seconds: 10), const Duration(seconds: 2)),
    );
    File(at('sparse.cdg')).writeAsBytesSync(
      _cdg(
        const Duration(seconds: 10),
        const Duration(seconds: 2),
        noopEvery: null,
      ),
    );
  });
  tearDownAll(() {
    if (libmpv != null) dir.deleteSync(recursive: true);
  });

  /// 画布 PNG（与页面同一个函数、同一个尺寸规则）。
  String canvasFor(String assName) {
    final AssRawScript raw = prepareAssRawScript(
      File(at(assName)).readAsBytesSync(),
    );
    final ({int width, int height}) size = musicKaraokeCanvasSize(
      playResX: raw.playResX,
      playResY: raw.playResY,
    );
    final String path = at('canvas_$assName.png');
    File(path).writeAsBytesSync(
      renderMusicKaraokeCanvasPng(width: size.width, height: size.height),
    );
    return path;
  }

  /// 起一个无窗口实例（`vo=null`：解码出的帧照样能截图）。
  Future<(Player, NativePlayer)> instance() async {
    final Player player = Player(
      configuration: const PlayerConfiguration(vo: 'null', libass: true),
    );
    final NativePlayer n = player.platform! as NativePlayer;
    // media_kit 默认 vid=no（VideoController 挂上时才开），这里没有纹理，手动开。
    await n.setProperty('vid', 'auto');
    await n.setProperty('ao', 'null');
    await n.setProperty('hr-seek', 'yes');
    return (player, n);
  }

  /// 本页管线：曲目音频为主文件，画布封面轨 + `sub-add`，属性与页面同一组。
  Future<(Player, NativePlayer)> stagePipeline({
    required String main,
    String? canvas,
    String? cdg,
    String? ass,
    double subDelay = 0,
    bool cdgProperties = true,
  }) async {
    final (Player player, NativePlayer n) = await instance();
    for (final MapEntry<String, String> e in musicKaraokeSubtitleProperties(
      visible: true,
    ).entries) {
      await n.setProperty(e.key, e.value);
    }
    if (cdg != null && cdgProperties) {
      for (final MapEntry<String, String> e
          in musicKaraokeCdgProperties().entries) {
        await n.setProperty(e.key, e.value);
      }
    }
    await player.open(Media(main), play: false);
    await player.stream.duration.firstWhere((Duration d) => d > Duration.zero);
    if (canvas != null) await n.command(musicKaraokeCanvasCommand(canvas));
    if (cdg != null) await n.command(musicKaraokeCdgCommand(cdg));
    if (ass != null) {
      await n.command(musicKaraokeAssCommand(ass));
      await n.setProperty('sub-delay', subDelay.toStringAsFixed(3));
    }
    return (player, n);
  }

  /// 参考：「mpv 单独播放」——放一段视频、`sub-files` 外挂 ASS，其余全默认（只打开
  /// media_kit 默认关掉的 libass 渲染）。
  Future<(Player, NativePlayer)> reference({
    required String video,
    required String ass,
  }) async {
    final (Player player, NativePlayer n) = await instance();
    await n.setProperty('sub-ass', 'yes');
    await n.setProperty('sub-visibility', 'yes');
    await n.setProperty('sub-files', ass);
    await player.open(Media(video), play: false);
    await player.stream.duration.firstWhere((Duration d) => d > Duration.zero);
    return (player, n);
  }

  /// 精确跳到 [seconds] 并截一帧（含字幕）。等 `time-pos` 落到目标再截。
  Future<_Shot> shot(NativePlayer n, double seconds, String name) async {
    await n.command(<String>[
      'seek',
      seconds.toStringAsFixed(6),
      'absolute+exact',
    ]);
    // 跳转落定：不在 seeking、位置连续两次读到同一值且在目标附近。有视频轨时 time-pos
    // 落在显示帧的 pts 上（CD+G 是下一个图形指令包，最多晚 0.1 s），不一定恰好等于目标。
    String? last;
    for (int i = 0; i < 300; i++) {
      final String pos = await n.getProperty('time-pos');
      final double? p = double.tryParse(pos);
      if (await n.getProperty('seeking') == 'no' &&
          pos == last &&
          p != null &&
          p >= seconds - 0.002 &&
          p < seconds + 0.2) {
        break;
      }
      last = pos;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final String path = at('$name.png');
    final File f = File(path);
    if (f.existsSync()) f.deleteSync();
    await n.command(<String>['screenshot-to-file', path, 'subtitles']);
    for (int i = 0; i < 200 && !f.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // 写完再读（文件出现到写完之间有空档）。
    img.Image? decoded;
    for (int i = 0; i < 100 && decoded == null; i++) {
      try {
        decoded = img.decodePng(f.readAsBytesSync());
      } on Object {
        decoded = null;
      }
      if (decoded == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    if (decoded == null) throw StateError('screenshot failed: $path');
    return _Shot(decoded.convert(numChannels: 3));
  }

  test(
    '\\k / \\kf / \\ko：libass 截帧与结构化进度逐音节一致',
    () async {
      final (Player player, NativePlayer n) = await stagePipeline(
        main: at('song.wav'),
        canvas: canvasFor('semantics.ass'),
        ass: at('semantics.ass'),
      );
      final LyricTimeline t = FushiLyrics.parse(
        utf8.encode(_semanticsAss),
        hint: 'ass',
      );
      expect(
        t.lines.map((LyricLine l) => l.syllables.first.fill).toList(),
        <LyricFill>[LyricFill.instant, LyricFill.sweep, LyricFill.outline],
      );
      try {
        // 每行两个音节、各 1 s；在第一个音节中段采样，后一个音节未到。
        for (final (int line, double sec) in <(int, double)>[
          (0, 1.5),
          (1, 3.5),
          (2, 5.5),
          (2, 6.5),
        ]) {
          final img.Image im = (await shot(n, sec, 'sem_$sec')).image;
          // 文字外框：非背景像素的列范围，两个等宽音节按中线分开。
          int minX = im.width;
          int maxX = -1;
          for (int y = 0; y < im.height; y++) {
            for (int x = 0; x < im.width; x++) {
              final img.Pixel p = im.getPixel(x, y);
              if (p.r > 80 || p.g > 80 || p.b > 80) {
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
              }
            }
          }
          expect(maxX, greaterThan(minX), reason: 'no text at $sec');
          final int mid = (minX + maxX) ~/ 2;
          ({int red, int blue, int green}) count(int x0, int x1) {
            int red = 0;
            int blue = 0;
            int green = 0;
            for (int y = 0; y < im.height; y++) {
              for (int x = x0; x < x1; x++) {
                final img.Pixel p = im.getPixel(x, y);
                if (p.r > 200 && p.g < 60 && p.b < 60) red++;
                if (p.b > 200 && p.r < 60 && p.g < 60) blue++;
                if (p.g > 200 && p.r < 60 && p.b < 60) green++;
              }
            }
            return (red: red, blue: blue, green: green);
          }

          final ({int red, int blue, int green}) a = count(minX, mid);
          final ({int red, int blue, int green}) b = count(mid, maxX + 1);
          final double progressA = a.red / (a.red + a.blue);
          final double progressB = b.red / (b.red + b.blue);
          final int ms = (sec * 1000).round();
          final List<LyricSyllable> s = t.lines[line].syllables;
          final double expectA = karaokeSyllableProgress(s[0], ms);
          final double expectB = karaokeSyllableProgress(s[1], ms);
          // ignore: avoid_print
          print(
            'line $line @${sec}s libass A=${progressA.toStringAsFixed(3)} '
            'B=${progressB.toStringAsFixed(3)} outline A=${a.green} B=${b.green} '
            '| structured A=$expectA B=$expectB',
          );
          if (expectA == 0 || expectA == 1) {
            expect(progressA, closeTo(expectA, 0.02));
          } else {
            // 擦色：已高亮比例落在中间，与结构化进度同向（字形宽度不均，不比绝对值）。
            expect(progressA, inExclusiveRange(0.1, 0.9));
          }
          expect(progressB, closeTo(expectB, 0.02));
          if (s[0].fill == LyricFill.outline) {
            // \ko：到点的音节有描边，没到的没有。
            expect(a.green, greaterThan(500));
            // 没到的音节没有描边（中线附近只有前一音节描边溢过来的几百像素）。
            expect(
              b.green,
              expectB == 1 ? greaterThan(500) : lessThan(a.green ~/ 40),
            );
          } else {
            // \k / \kf：描边一直在。
            expect(a.green, greaterThan(500));
            expect(b.green, greaterThan(500));
          }
        }
      } finally {
        await player.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '字幕组特效 ASS：本页管线与 mpv 单独播放逐帧一致（25 fps）',
    () async {
      final String canvas = canvasFor('effects.ass');
      // 参考视频：画布逐帧无损编码（PNG in MKV），像素与画布一致。25 fps：MKV 时间戳是
      // 毫秒，40 ms 一帧才能精确落在帧 pts 上（30 fps 的 33.33 ms 会被取整，参考跳转落到
      // 前一帧，量出来的是取整误差而不是渲染差异）。
      final String video = at('effects_ref.mkv');
      await _ff(<String>[
        '-loop',
        '1',
        '-framerate',
        '25',
        '-i',
        canvas,
        '-t',
        '6',
        '-c:v',
        'png',
        video,
      ]);
      final (Player ours, NativePlayer on) = await stagePipeline(
        main: at('song.wav'),
        canvas: canvas,
        ass: at('effects.ass'),
      );
      final (Player ref, NativePlayer rn) = await reference(
        video: video,
        ass: at('effects.ass'),
      );
      int frames = 0;
      int identical = 0;
      int worstPixels = 0;
      int worstDelta = 0;
      int inkFrames = 0;
      try {
        // 特效区间 0.5–4.5 s（入场滑入 → 放大变色 → 旋转淡出 → 粒子 → \clip 擦除）。
        for (int i = 0; i <= 100; i++) {
          final double sec = _frameTime(12 + i);
          final img.Image a = (await shot(on, sec, 'fx_ours')).image;
          final img.Image b = (await shot(rn, sec, 'fx_ref')).image;
          expect((a.width, a.height), (b.width, b.height));
          int diffPixels = 0;
          int maxDelta = 0;
          int ink = 0;
          for (int y = 0; y < a.height; y++) {
            for (int x = 0; x < a.width; x++) {
              final img.Pixel p = a.getPixel(x, y);
              final img.Pixel q = b.getPixel(x, y);
              final int d = <int>[
                (p.r - q.r).abs().toInt(),
                (p.g - q.g).abs().toInt(),
                (p.b - q.b).abs().toInt(),
              ].reduce((int m, int v) => m > v ? m : v);
              if (d > 0) diffPixels++;
              if (d > maxDelta) maxDelta = d;
              if (p.r > 0x30 || p.g > 0x30 || p.b > 0x30) ink++;
            }
          }
          frames++;
          if (diffPixels > 0) {
            // ignore: avoid_print
            print('frame ${12 + i}: $diffPixels px differ (max $maxDelta)');
            final String? dbg = Platform.environment['FUSHI_KARAOKE_DEBUG_DIR'];
            if (dbg != null) {
              File(at('fx_ours.png')).copySync('$dbg/ours_${12 + i}.png');
              File(at('fx_ref.png')).copySync('$dbg/ref_${12 + i}.png');
            }
          }
          if (diffPixels == 0) identical++;
          if (ink > 200) inkFrames++;
          if (diffPixels > worstPixels) worstPixels = diffPixels;
          if (maxDelta > worstDelta) worstDelta = maxDelta;
        }
      } finally {
        await ours.dispose();
        await ref.dispose();
      }
      // ignore: avoid_print
      print(
        'effects: $frames frames, $identical pixel-identical, '
        '$inkFrames with subtitles drawn, worst frame $worstPixels px differ '
        '(max channel delta $worstDelta)',
      );
      // 特效确实画出来了（不是两边都没字幕的空比较）。
      expect(inkFrames, greaterThan(80));
      expect(identical, frames);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'MV 偏移：sub-delay 后 MV 时刻 v 的画面 = 参考在脚本时刻 v − delay 的画面',
    () async {
      final String canvas = canvasFor('effects.ass');
      final String mv = at('mv.mkv');
      await _ff(<String>[
        '-loop',
        '1',
        '-framerate',
        '25',
        '-i',
        canvas,
        '-t',
        '8',
        '-c:v',
        'png',
        mv,
      ]);
      // MV 有 1.5 s 前奏、歌词整首提前 300 ms → 字幕整体晚 1.2 s（30 帧）出现。
      final double delay = musicKaraokeSubDelaySeconds(
        mvOffsetMs: 1500,
        lyricsOffsetMs: 300,
      );
      expect(delay, closeTo(1.2, 1e-9));
      final (Player ours, NativePlayer on) = await stagePipeline(
        main: mv,
        ass: at('effects.ass'),
        subDelay: delay,
      );
      final (Player ref, NativePlayer rn) = await reference(
        video: mv,
        ass: at('effects.ass'),
      );
      int identical = 0;
      int frames = 0;
      try {
        for (int i = 0; i <= 30; i++) {
          final double v = _frameTime(62 + i);
          final img.Image a = (await shot(on, v, 'mv_ours')).image;
          // 1.2 s = 30 帧：参考取第 62 + i − 30 帧。
          final img.Image b = (await shot(
            rn,
            _frameTime(32 + i),
            'mv_ref',
          )).image;
          frames++;
          if (_samePixels(a, b)) identical++;
        }
        // 反证：不加 delay 的同一时刻画面不同（防恒真）。
        final img.Image wrong = (await shot(
          rn,
          _frameTime(62),
          'mv_wrong',
        )).image;
        final img.Image right = (await shot(
          on,
          _frameTime(62),
          'mv_right',
        )).image;
        expect(_samePixels(wrong, right), isFalse);
      } finally {
        await ours.dispose();
        await ref.dispose();
      }
      // ignore: avoid_print
      print('mv offset: $frames frames, $identical pixel-identical');
      expect(identical, frames);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'CD+G：曲目音频 + video-add .cdg，cdgraphics 解码且与音频同一时间轴',
    () async {
      // 极端稀疏的 .cdg：mpv 默认探测门槛下加不上轨，下发
      // musicKaraokeCdgProperties 后加得上。
      for (final bool props in <bool>[false, true]) {
        final (Player p, NativePlayer pn) = await stagePipeline(
          main: at('song.wav'),
          cdg: at('sparse.cdg'),
          cdgProperties: props,
        );
        try {
          expect(
            await pn.getProperty('current-tracks/video/codec'),
            props ? 'cdgraphics' : isEmpty,
          );
        } finally {
          await p.dispose();
        }
      }
      final (Player player, NativePlayer n) = await stagePipeline(
        main: at('song.wav'),
        cdg: at('song.cdg'),
      );
      try {
        expect(await n.getProperty('current-tracks/video/codec'), 'cdgraphics');
        expect(await n.getProperty('current-tracks/video/external'), 'yes');
        Future<(num, num, num)> center(double sec) async {
          final img.Image im = (await shot(n, sec, 'cdg_$sec')).image;
          final img.Pixel p = im.getPixel(im.width ~/ 2, im.height ~/ 2);
          return (p.r, p.g, p.b);
        }

        // 2 s 前红、2 s 后绿；来回跳都对（清屏包是关键帧）。
        expect(await center(1.0), (255, 0, 0));
        expect(await center(3.0), (0, 255, 0));
        expect(await center(0.5), (255, 0, 0));
        expect(await center(7.0), (0, 255, 0));
      } finally {
        await player.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// 第 [frame] 帧（25 fps）稍后一点的时刻：参考视频是真帧，精确跳转落在 `pts ≤ t` 的那帧、
/// 字幕按该帧 pts 合成；画布是静态封面轨，字幕按播放时刻合成。取帧 pts + 0.1 ms，两边
/// 交给 libass 的毫秒时刻相同（mpv 按毫秒四舍五入），浮点打印也不会落到前一帧。
double _frameTime(int frame) => frame / 25 + 0.0001;

bool _samePixels(img.Image a, img.Image b) {
  if (a.width != b.width || a.height != b.height) return false;
  for (int y = 0; y < a.height; y++) {
    for (int x = 0; x < a.width; x++) {
      final img.Pixel p = a.getPixel(x, y);
      final img.Pixel q = b.getPixel(x, y);
      if (p.r != q.r || p.g != q.g || p.b != q.b) return false;
    }
  }
  return true;
}
