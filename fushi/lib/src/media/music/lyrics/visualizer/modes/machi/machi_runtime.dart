/// 町景的运行时（folia `createMachiRuntime.ts`）：建一次，换歌、换配色、换设置就地推给它；
/// 每帧推进氛围时钟（只在播放且开着动态效果时走）、时间与天气（按真实时间阻尼地追，暂停时
/// 也走完）、牌面与信号切换、副歌与闪电、节拍、车、运镜，再画天空 → 场景 → 雨雪 → 雾 →
/// 景深。场景按 id / seed / 配色缓存，换了才重建。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_director.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_lens.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_render.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_scene_konbini.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_scene_kowloon.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_scene_station.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_screen.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_weather.dart';

/// 某个场景的歌词屏尺寸（米）。
(double, double) machiScreenSizeOf(MachiSceneId id) => switch (id) {
  MachiSceneId.konbini => (machiKonbiniScreenW, machiKonbiniScreenH),
  MachiSceneId.station => (machiStationScreenW, machiStationScreenH),
  MachiSceneId.kowloon => (machiKowloonScreenW, machiKowloonScreenH),
};

/// 建场景。
MachiSceneModel buildMachiScene(
  MachiSceneId id,
  MachiPalette palette,
  int seed,
  MachiLyricScreen screen,
) => switch (id) {
  MachiSceneId.konbini => buildMachiKonbini(palette, seed, screen),
  MachiSceneId.station => buildMachiStation(palette, seed, screen),
  MachiSceneId.kowloon => buildMachiKowloon(palette, seed, screen),
};

class MachiRuntime {
  MachiRuntime();

  final MachiTextCache text = MachiTextCache();
  late LyricVisualizerContext _ctx;
  late MachiSettings _settings;

  MachiSceneId? _sceneId;
  int _sceneKey = 0;
  MachiSceneModel? _scene;
  MachiLyricScreen? _screen;
  MachiFrame? _frame;

  LyricVisualizerRuntime? _linesOf;
  MachiBeatTrack? _track;
  List<double> _lightningTimes = const <double>[];
  List<double> _paragraphs = const <double>[];

  MachiEnvironmentState? _env;
  double _lastElapsed = -1;
  double _ambient = 0;
  double _motionTime = 0;
  double _driftWeight = 0;
  double _chorusSmooth = 0;
  String _nextLine = '';
  double _nextGlitch = 0;
  MachiCamera? _camera;

  MachiSceneModel? get scene => _scene;
  MachiFrame? get frame => _frame;
  MachiCamera? get camera => _camera;
  MachiLyricScreen? get screen => _screen;
  MachiSettings get settings => _settings;

  /// 换歌 / 换配色 / 换设置 / 换字体：就地更新。
  void configure(LyricVisualizerContext ctx, TextStyle base) {
    _ctx = ctx;
    _settings = MachiSettings(ctx.tuning);
    final TextStyle style = ctx.applyThemeFont(
      base.copyWith(decoration: TextDecoration.none, shadows: null),
    );
    if (style != text.base) {
      text.reset(style);
      _screen?.invalidate();
    }
    final MachiSceneId id = resolveMachiSceneId(_settings.scene, ctx.seed);
    final List<Color> keywords = <Color>[...?ctx.theme?.wordColors.values];
    final int key = Object.hash(
      id,
      ctx.seed,
      ctx.palette,
      Object.hashAll(keywords),
    );
    if (_scene == null || key != _sceneKey) {
      _sceneKey = key;
      final bool sameScene = _sceneId == id;
      _sceneId = id;
      final MachiPalette palette = resolveMachiPalette(
        ctx.palette,
        ctx.seed,
        keywordColors: keywords,
      );
      final (double w, double h) = machiScreenSizeOf(id);
      _screen = MachiLyricScreen(w, h);
      _scene = buildMachiScene(id, palette, ctx.seed, _screen!);
      _frame = MachiFrame(palette: palette, text: text, seed: ctx.seed);
      if (!sameScene) _env = null;
    }
    if (!identical(_linesOf, ctx.runtime)) {
      _linesOf = ctx.runtime;
      _lightningTimes = buildMachiLightningTimes(ctx.runtime.lines);
      _paragraphs = buildMachiParagraphStarts(ctx.runtime.lines);
      _screen?.invalidate();
    }
    final LyricVisualizerBeats beats = LyricVisualizerBeats.of(ctx);
    if (!identical(_track?.beats, beats)) _track = MachiBeatTrack(beats);
  }

  /// 本首的拍点与挑好的鼓击。
  MachiBeatTrack get beatTrack => _track!;

  /// 推进一帧。
  void step(LyricVisualizerTick tick, Size size) {
    final MachiFrame f = _frame!;
    final MachiSceneModel scene = _scene!;
    final MachiLyricScreen screen = _screen!;
    final LyricVisualizerContext ctx = _ctx;
    final bool motion = ctx.motion;
    final double realDelta = _lastElapsed < 0
        ? 0
        : machiClamp(tick.elapsed - _lastElapsed, 0, 0.1);
    _lastElapsed = tick.elapsed;
    final double ambientDelta = motion && ctx.playing ? realDelta : 0;
    _ambient += ambientDelta;

    // 时间与天气。
    final MachiWeatherKind kind = resolveMachiWeatherKind(
      _settings.weather,
      ctx.seed,
    );
    final MachiEnvironmentTarget target = MachiEnvironmentTarget.of(
      resolveMachiDaylight(_settings.timeOfDay, DateTime.now()),
      kind,
    );
    final MachiEnvironmentState? env = _env;
    _env = env == null || !motion
        ? MachiEnvironmentState.settled(target)
        : stepMachiEnvironment(env, target, realDelta);

    final List<LyricVisualizerLine> lines = ctx.runtime.lines;
    final double song = tick.timeMs / 1000;
    final MachiBoardTarget board = resolveMachiBoardTarget(lines, song);
    final double chorus = resolveMachiChorus(lines, board);
    _chorusSmooth = motion
        ? _chorusSmooth +
              (chorus - _chorusSmooth) * (1 - math.exp(-realDelta * 3))
        : chorus;

    f
      ..env = _env!
      ..look = resolveMachiEnvironmentLook(_env!)
      ..ambient = _ambient
      ..song = song
      ..motion = motion
      ..glow = _settings.glow
      ..reflections = _settings.reflections
      ..chorus = _chorusSmooth
      ..audio = motion ? ctx.audioFrameAt(tick.timeMs).power : 0
      ..intensity = ctx.intensity.pick(0.7, 1, 1.3)
      ..flicker = motion ? resolveMachiFlicker(_ambient, ctx.seed) : 1
      ..lightning = motion && _env!.rain > 0.5
          ? resolveMachiLightning(_lightningTimes, song) * _env!.rain
          : 0
      ..title = (ctx.title ?? '').trim()
      ..artist = (ctx.artist ?? '').trim()
      ..album = (ctx.album ?? '').trim()
      ..doorOpen = scene.id == MachiSceneId.konbini
          ? resolveMachiDoorOpen(_paragraphs, song)
          : 0
      ..car = motion
          ? resolveMachiCar(
              _ambient,
              ctx.seed,
              scene.lanes,
              // folia TRAFFIC_CHANCE：平静 0.4 / 普通 0.6 / 激烈 0.78
              chance: ctx.intensity.pick(0.4, 0.6, 0.78),
            )
          : null
      ..positionSec = ctx.clock.position.inMilliseconds / 1000
      ..durationSec = ctx.clock.duration.inMilliseconds / 1000
      ..lineCount = lines.length
      ..lineNumber = board.lineIndex == null ? 0 : board.lineIndex! + 1;
    _stepBeat(f, song, motion);
    final String title = f.title.isEmpty ? 'Machi' : f.title;
    f.tickerText = scene.id == MachiSceneId.kowloon
        ? _kowloonTicker(board, lines, title, f.artist)
        : resolveMachiTickerText(board, lines, title: title, artist: f.artist);
    f.tickerScroll += ambientDelta * 1.1;

    // 下一句（全息、出租车）与换字时的错位。
    final LyricVisualizerLine? next = _nextAfter(board, lines, song);
    final String nextText = next?.text ?? '';
    if (nextText != _nextLine) {
      _nextLine = nextText;
      _nextGlitch = motion ? 1 : 0;
    }
    _nextGlitch = math.max(0, _nextGlitch - realDelta / 0.3);
    f
      ..nextLine = _nextLine
      ..nextGlitch = _nextGlitch > 0 ? math.sin(math.pi * _nextGlitch) : 0;

    // 歌词屏：换牌面（静态 / 暂停时直接换），下一行快到了先排好。
    final LyricVisualizerLine? upcoming = ctx.runtime.upcomingLineAt(
      tick.timeMs,
    );
    MachiBoardTarget? preheat;
    if (upcoming != null &&
        ctx.runtime.shouldPreheat(
          upcoming,
          tick.timeMs,
          minLeadMs: 0,
          maxLeadMs: 1500,
        )) {
      final int i = lines.indexOf(upcoming);
      if (i >= 0) preheat = MachiBoardTarget.line(i);
    }
    screen.update(
      target: board,
      preheat: preheat,
      lines: lines,
      title: title,
      subtitle: f.artist,
      text: text,
      delta: realDelta,
      immediate: !motion || !ctx.playing,
      chorus: chorus,
    );

    // 镜头：自定义视角 + 运镜（随歌曲暂停，幅度用真实时间缓起缓停）。
    final bool drift = motion && _settings.motion;
    _driftWeight = drift
        ? math.min(1, _driftWeight + realDelta / 1.5)
        : (motion ? math.max(0, _driftWeight - realDelta / 1.5) : 0);
    _motionTime += ambientDelta * _settings.motionSpeed;
    final MachiViewOffset d = resolveMachiDrift(_motionTime);
    final double w = _driftWeight * _driftWeight * (3 - 2 * _driftWeight);
    final MachiCustomView view = _settings.customView
        ? _settings.viewOf(scene.id)
        : const MachiCustomView();
    final MachiViewOffset offset = MachiViewOffset(
      azimuth: view.azimuth + d.azimuth * w,
      elevation: view.elevation + d.elevation * w,
      zoom: view.zoom * math.pow(d.zoom, w).toDouble(),
      panX: view.panX + d.panX * w,
      panZ: view.panZ + d.panZ * w,
    );
    _camera = machiFitCamera(
      framing: scene.framing,
      home: scene.home,
      size: size,
      focus: scene.focus,
      offset: offset,
    );
    f
      ..camera = _camera!
      ..lighting = MachiLighting(
        palette: f.palette,
        env: _env!,
        look: f.look,
        lightning: f.lightning,
      );
  }

  /// 节拍（folia `stepBeat`），按歌曲时间取、暂停时回常态：
  /// - 霓虹随拍：有拍点且强度 > 0 时跟真拍子；否则开着「模拟节拍」时按氛围时钟上的固定节拍走；
  /// - 鼓点涟漪：有鼓击时每下底鼓在湿地面上荡开一圈（地面干时改成光斑跳一下）；没有鼓击时没有；
  /// - 大屏闪拍：有鼓击且强度 > 0 时每下军鼓亮一处；否则开着「模拟节拍」时按固定节拍。
  void _stepBeat(MachiFrame f, double song, bool motion) {
    f.beat.reset();
    if (!motion) return;
    final MachiBeatTrack track = _track!;
    final bool playing = _ctx.playing;
    if (track.beats.hasBeats && _settings.neonPulse > 0) {
      if (playing) {
        resolveMachiNeonPulse(
          track.beats.events,
          song,
          _settings.neonPulse,
          f.beat,
        );
      }
    } else if (_settings.simulatedBeat) {
      resolveMachiSteadyNeonPulse(_ambient, 1, f.beat);
    }
    if (track.hasDrums && playing) {
      f.beat.thump =
          resolveMachiDrumRipples(track, song, _settings.drumRipple, f.beat) *
          (1 - machiRippleWetness(f.env.wetness));
    }
    if (track.hasDrums && _settings.screenFlash > 0) {
      if (playing) {
        resolveMachiScreenFlash(track, song, _settings.screenFlash, f.beat);
      }
    } else if (_settings.simulatedBeat) {
      resolveMachiSteadyScreenFlash(_ambient, 1, f.beat);
    }
  }

  /// 城寨的跑马灯：这一句的译文，没有译文时滚曲名、歌手。
  String _kowloonTicker(
    MachiBoardTarget board,
    List<LyricVisualizerLine> lines,
    String title,
    String artist,
  ) {
    final int? i = board.lineIndex;
    final String? tr = i != null && i < lines.length
        ? lines[i].translation
        : null;
    if (tr != null && tr.trim().isNotEmpty) return '$tr   ◆   ';
    return '♪ $title${artist.isEmpty ? '' : ' — $artist'}   ◆   九龍城寨   ◆   OPEN ALL NIGHT   ◆   ';
  }

  LyricVisualizerLine? _nextAfter(
    MachiBoardTarget board,
    List<LyricVisualizerLine> lines,
    double song,
  ) {
    final int from = board.lineIndex == null
        ? _ctx.runtime.lastStartedLineAt((song * 1000).round()) + 1
        : board.lineIndex! + 1;
    for (int k = math.max(0, from); k < lines.length; k++) {
      if (!machiIsInterludeText(lines[k].text)) return lines[k];
    }
    return null;
  }

  /// 对焦线（屏幕 y）。
  double focusY(Size size) {
    final MachiCamera cam = _camera!;
    switch (_settings.focus) {
      case 'lyrics':
        return cam.project(_scene!.focus).dy;
      case 'manual':
        final MachiV3 flat = MachiV3(cam.dir.x, 0, cam.dir.z).normalized();
        return cam.project(cam.target + flat * _settings.focusOffset).dy;
    }
    return cam.anchor.dy;
  }

  void paint(Canvas canvas, Size size) {
    final MachiFrame f = _frame!;
    final MachiCamera cam = _camera!;
    final List<MachiLensBand> bands = resolveMachiLensBands(
      height: size.height,
      focusY: focusY(size),
      aperture: _settings.aperture,
      dof: _settings.dof,
      dofRange: _settings.dofRange,
      tiltShift: _settings.tiltShift,
    );
    if (bands.isEmpty) {
      _paintWorld(canvas, size, f, cam);
      return;
    }
    final ui.PictureRecorder rec = ui.PictureRecorder();
    _paintWorld(Canvas(rec), size, f, cam);
    final ui.Picture picture = rec.endRecording();
    canvas.drawPicture(picture);
    // 歌词屏不虚（folia 里歌词屏与默认对焦处差不多远；这里横带近似会误伤它）。
    Path? keep;
    final List<MachiV3> face = _scene!.screenFace;
    if (face.length >= 3) {
      keep = Path();
      for (int i = 0; i < face.length; i++) {
        final Offset o = cam.project(face[i]);
        if (i == 0) {
          keep.moveTo(o.dx, o.dy);
        } else {
          keep.lineTo(o.dx, o.dy);
        }
      }
      keep.close();
    }
    for (final MachiLensBand b in bands) {
      canvas.save();
      final Rect band = Rect.fromLTRB(0, b.top, size.width, b.bottom);
      if (keep != null && keep.getBounds().overlaps(band)) {
        canvas.clipPath(
          Path.combine(PathOperation.difference, Path()..addRect(band), keep),
        );
      } else {
        canvas.clipRect(band);
      }
      canvas.saveLayer(
        Offset.zero & size,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: b.sigma,
            sigmaY: b.sigma,
            tileMode: TileMode.clamp,
          ),
      );
      canvas.drawPicture(picture);
      canvas.restore();
      canvas.restore();
    }
    picture.dispose();
  }

  void _paintWorld(Canvas canvas, Size size, MachiFrame f, MachiCamera cam) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    paintMachiSky(canvas, size, f);
    MachiRenderer(canvas, cam, f).drawScene(_scene!);
    if (f.motion) paintMachiPrecipitation(canvas, cam, f, _scene!);
    paintMachiAtmosphere(canvas, size, f);
    canvas.restore();
  }

  void dispose() => text.dispose();
}
