/// 「绘光」的字形图集：整首歌用到的字拼成白字图集，每帧用 drawRawAtlas 按颜色 / 透明度 modulate 出来。
///
/// 图集按屏上**物理**字号分档（em = 64 · 2^k 物理像素，最高一档受单张图集像素预算封顶）：每个字取
/// 不小于它物理字号的那一档画，只缩小、不放大，大字不发虚；小字也不会从超大图集里一路缩下来出锯齿。
/// 只有最低一档在建场景时同步画；更高的档在屏上第一次出现那么大的字时才在后台分片排字、异步光栅化，
/// 就绪前先用已有的最近一档。换字体同样整套在后台建好再换上，旧图集一直画到新图集就绪。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:material_ui/material_ui.dart';

/// 最低一档的 em（物理像素）。
const double kLumiereAtlasBaseEm = 64;

/// 单张图集的像素预算（4096²，约 64 MB RGBA）：字多的歌最高一档按它封顶。
const int kLumiereAtlasMaxPixels = 4096 * 4096;

/// 最高一档 em 的绝对上限（物理像素）。
const double kLumiereAtlasMaxEm = 512;

/// 字格四周的留白（相对 em）：给字身外扩（斜体、重音符号）留地方。
const double _padRatio = 10 / 64;

/// 字格边长 / em。
const double kLumiereGlyphCellRatio = 1 + 2 * _padRatio;

/// 后台排字每片的时间预算：超过就让出事件循环，让帧照常出。
const Duration _slice = Duration(milliseconds: 3);

/// 图集用的字体。
@immutable
class LumiereGlyphStyle {
  const LumiereGlyphStyle({
    this.fontFamily,
    this.fontFamilyFallback,
    this.fontWeight = FontWeight.w500,
  });

  /// 取 [style] 的字族 / 回落链 / 字重（字重缺省 w500）。
  factory LumiereGlyphStyle.of(TextStyle style) => LumiereGlyphStyle(
    fontFamily: style.fontFamily,
    fontFamilyFallback: style.fontFamilyFallback,
    fontWeight: style.fontWeight ?? FontWeight.w500,
  );

  final String? fontFamily;
  final List<String>? fontFamilyFallback;
  final FontWeight fontWeight;

  TextStyle textStyle(double fontSize) => TextStyle(
    fontSize: fontSize,
    height: 1,
    color: const Color(0xFFFFFFFF),
    fontWeight: fontWeight,
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
  );

  @override
  bool operator ==(Object other) =>
      other is LumiereGlyphStyle &&
      other.fontFamily == fontFamily &&
      other.fontWeight == fontWeight &&
      listEquals(other.fontFamilyFallback, fontFamilyFallback);

  @override
  int get hashCode => Object.hash(
    fontFamily,
    fontWeight,
    fontFamilyFallback == null ? null : Object.hashAll(fontFamilyFallback!),
  );
}

/// 一页图集的边长上限（物理像素）：一档图集拆成若干页，每页单独光栅化，一次 `toImage` 的光栅活儿有上限，
/// 后台补档 / 换字体时不会在 raster 线程上一口气画几千万像素卡掉一帧。
const double _sheetSide = 1024;

/// [n] 个字时各档的 em（升序）：64、128、256…，最高一档按像素预算与 [kLumiereAtlasMaxEm] 封顶。
List<double> lumiereAtlasTiers(int n) {
  final double cellCap = math.sqrt(kLumiereAtlasMaxPixels / math.max(n, 1));
  final double cap = math.min(
    kLumiereAtlasMaxEm,
    (cellCap / kLumiereGlyphCellRatio).floorToDouble(),
  );
  final List<double> tiers = <double>[kLumiereAtlasBaseEm];
  double e = kLumiereAtlasBaseEm * 2;
  while (e < cap) {
    tiers.add(e);
    e *= 2;
  }
  if (cap > tiers.last) tiers.add(cap);
  return tiers;
}

/// em 为 [em] 时一页的列数（每页 列 × 列 个字）。
int lumiereAtlasSheetColumns(double em) =>
    math.max(1, (_sheetSide / (em * kLumiereGlyphCellRatio)).floor());

/// 一档图集：所有字按同一 em 画成白字，分页存放，槽位次序与字表一致。
class LumiereGlyphAtlas {
  LumiereGlyphAtlas._(this.sheets, this.em, this.advances)
    : _columns = lumiereAtlasSheetColumns(em);

  /// 各页图（第 k 页放第 k·列² … (k+1)·列² − 1 号字）。
  final List<ui.Image> sheets;

  /// 这一档的字号（图集像素）。
  final double em;
  final int _columns;

  /// 每个字的步进（相对 em）。
  final List<double> advances;

  double get cell => em * kLumiereGlyphCellRatio;

  int get _perSheet => _columns * _columns;

  /// 字 [slot] 所在的页。
  ui.Image sheetOf(int slot) => sheets[slot ~/ _perSheet];

  /// 字 [slot] 在它那一页里的字格。
  Rect rectOf(int slot) {
    final int local = slot % _perSheet;
    return Rect.fromLTWH(
      (local % _columns) * cell,
      (local ~/ _columns) * cell,
      cell,
      cell,
    );
  }

  /// 同步画（建场景时的最低一档）。
  factory LumiereGlyphAtlas.build(
    List<String> chars,
    LumiereGlyphStyle style, {
    double em = kLumiereAtlasBaseEm,
  }) {
    final _AtlasRecorder r = _AtlasRecorder(chars, style, em);
    final List<ui.Image> sheets = <ui.Image>[];
    while (r.hasNext) {
      final ui.Picture? page = r.paintNext();
      if (page == null) continue;
      sheets.add(page.toImageSync(r.width, r.heightOf(sheets.length)));
      page.dispose();
    }
    return LumiereGlyphAtlas._(sheets, em, r.advances);
  }

  /// 后台画：排字分片（每片不超过 [_slice]，片间让出事件循环），每页排完就异步 `toImage`
  /// （光栅化在 raster 线程，一次一页）。[cancelled] 为真时中途放弃并返回 null。
  static Future<LumiereGlyphAtlas?> rasterize(
    List<String> chars,
    LumiereGlyphStyle style, {
    required double em,
    bool Function()? cancelled,
  }) async {
    final _AtlasRecorder r = _AtlasRecorder(chars, style, em);
    final List<ui.Image> sheets = <ui.Image>[];
    bool abandon() {
      if (!(cancelled?.call() ?? false)) return false;
      r.abandon();
      for (final ui.Image s in sheets) {
        s.dispose();
      }
      return true;
    }

    final Stopwatch sw = Stopwatch()..start();
    try {
      while (r.hasNext) {
        final ui.Picture? page = r.paintNext();
        if (page != null) {
          try {
            sheets.add(
              await debugRasterizePage(
                page,
                r.width,
                r.heightOf(sheets.length),
              ),
            );
          } finally {
            page.dispose();
          }
          if (abandon()) return null;
          sw.reset();
        } else if (sw.elapsed >= _slice) {
          await Future<void>.delayed(Duration.zero);
          if (abandon()) return null;
          sw.reset();
        }
      }
    } catch (_) {
      // 光栅化失败：已画好的页不能漏掉不释放，错误原样交给调用方。
      r.abandon();
      for (final ui.Image s in sheets) {
        s.dispose();
      }
      rethrow;
    }
    return LumiereGlyphAtlas._(sheets, em, r.advances);
  }

  /// 后台光栅化一页（测试可替换成会失败的实现，验证失败路径）。
  @visibleForTesting
  static Future<ui.Image> Function(ui.Picture page, int width, int height)
  debugRasterizePage = _rasterizePage;

  static Future<ui.Image> _rasterizePage(
    ui.Picture page,
    int width,
    int height,
  ) => page.toImage(width, height);

  void dispose() {
    for (final ui.Image s in sheets) {
      s.dispose();
    }
  }
}

/// 逐字排进一页页 Picture。
class _AtlasRecorder {
  _AtlasRecorder(this.chars, LumiereGlyphStyle style, this.em)
    : _style = style.textStyle(em),
      _columns = lumiereAtlasSheetColumns(em),
      advances = List<double>.filled(chars.length, 0.6);

  final List<String> chars;
  final double em;
  final TextStyle _style;
  final int _columns;
  final List<double> advances;
  ui.PictureRecorder? _recorder;
  Canvas? _canvas;
  int _next = 0;

  double get _cell => em * kLumiereGlyphCellRatio;
  int get _perSheet => _columns * _columns;

  bool get hasNext => _next < chars.length;

  /// 页宽（各页相同）。
  int get width =>
      (math.min(_columns, math.max(chars.length, 1)) * _cell).ceil();

  /// 第 [sheet] 页的高（最后一页按剩下的字数）。
  int heightOf(int sheet) {
    final int count = math.min(
      _perSheet,
      math.max(1, chars.length - sheet * _perSheet),
    );
    return ((count / _columns).ceil() * _cell).ceil();
  }

  /// 排下一个字；排满一页（或排完）时返回这一页的 Picture，否则 null。
  ui.Picture? paintNext() {
    final int i = _next++;
    final int local = i % _perSheet;
    if (local == 0) {
      _recorder = ui.PictureRecorder();
      _canvas = Canvas(_recorder!);
    }
    final TextPainter p = TextPainter(
      text: TextSpan(text: chars[i], style: _style),
      textDirection: TextDirection.ltr,
    )..layout();
    advances[i] = math.max(0.25, p.width / em);
    final double left = (local % _columns) * _cell;
    final double top = (local ~/ _columns) * _cell;
    p.paint(
      _canvas!,
      Offset(left + (_cell - p.width) / 2, top + (_cell - p.height) / 2),
    );
    p.dispose();
    if (local == _perSheet - 1 || _next >= chars.length) {
      final ui.Picture page = _recorder!.endRecording();
      _recorder = null;
      _canvas = null;
      return page;
    }
    return null;
  }

  void abandon() {
    _recorder?.endRecording().dispose();
    _recorder = null;
    _canvas = null;
  }
}

/// 一种字体下的整套图集（各档共用字表与槽位）。
class LumiereGlyphAtlases {
  LumiereGlyphAtlases._(this.chars, this.style, List<LumiereGlyphAtlas> levels)
    : tiers = lumiereAtlasTiers(chars.length),
      _slots = <String, int>{
        for (int i = 0; i < chars.length; i++) chars[i]: i,
      },
      _advances = <String, double>{
        for (int i = 0; i < chars.length; i++)
          chars[i]: levels.first.advances[i],
      } {
    for (final LumiereGlyphAtlas l in levels) {
      _levels[l.em] = l;
    }
  }

  /// 整首歌的字去重（空白不进图集）。
  static List<String> uniqueChars(Iterable<String> chars) =>
      chars.where((String c) => c.trim().isNotEmpty).toSet().toList();

  /// 同步建最低一档。
  factory LumiereGlyphAtlases.build(
    List<String> chars,
    LumiereGlyphStyle style,
  ) => LumiereGlyphAtlases._(chars, style, <LumiereGlyphAtlas>[
    LumiereGlyphAtlas.build(chars, style),
  ]);

  /// 后台建一整套：最低一档 + [ems] 里的各档（换字体时带上旧图集已有的档，换上后不先糊一下）。
  static Future<LumiereGlyphAtlases?> rasterize(
    List<String> chars,
    LumiereGlyphStyle style, {
    Iterable<double> ems = const <double>[],
    bool Function()? cancelled,
  }) async {
    final List<LumiereGlyphAtlas> levels = <LumiereGlyphAtlas>[];
    void release() {
      for (final LumiereGlyphAtlas done in levels) {
        done.dispose();
      }
    }

    for (final double em in <double>{kLumiereAtlasBaseEm, ...ems}) {
      final LumiereGlyphAtlas? l;
      try {
        l = await LumiereGlyphAtlas.rasterize(
          chars,
          style,
          em: em,
          cancelled: cancelled,
        );
      } catch (_) {
        release();
        rethrow;
      }
      if (l == null) {
        release();
        return null;
      }
      levels.add(l);
    }
    return LumiereGlyphAtlases._(chars, style, levels);
  }

  final List<String> chars;
  final LumiereGlyphStyle style;

  /// 这套字可用的各档 em（升序）。
  final List<double> tiers;
  final Map<String, int> _slots;
  final Map<String, double> _advances;
  final Map<double, LumiereGlyphAtlas> _levels = <double, LumiereGlyphAtlas>{};
  double? _wanted;

  /// 已经画好的各档 em。
  Iterable<double> get builtEms => _levels.keys;

  /// 想要但还没画的最大一档（画面上出现了比已有各档都大的字）。
  double? get wantedEm => _wanted;

  double advance(String char) =>
      char.trim().isEmpty ? 0.3 : (_advances[char] ?? 0.6);

  int? slotOf(String char) => _slots[char];

  /// 物理字号 [physicalPx] 该用的一档：不小于它的最小一档（顶档封顶）；那一档还没画就记下来，
  /// 先用已画好的里最接近的一档。
  LumiereGlyphAtlas levelFor(double physicalPx) {
    double target = tiers.last;
    for (final double t in tiers) {
      // 放大不超过 5% 的就不换更大一档。
      if (t * 1.05 >= physicalPx) {
        target = t;
        break;
      }
    }
    final LumiereGlyphAtlas? hit = _levels[target];
    if (hit != null) return hit;
    if (_wanted == null || target > _wanted!) _wanted = target;
    LumiereGlyphAtlas best = _levels.values.first;
    for (final LumiereGlyphAtlas l in _levels.values) {
      if ((l.em - target).abs() < (best.em - target).abs()) best = l;
    }
    return best;
  }

  /// 补上一档（后台画好的）。
  void addLevel(LumiereGlyphAtlas level) {
    _levels.remove(level.em)?.dispose();
    _levels[level.em] = level;
    if (_wanted != null && _wanted! <= level.em) _wanted = null;
  }

  void clearWanted() => _wanted = null;

  void dispose() {
    for (final LumiereGlyphAtlas l in _levels.values) {
      l.dispose();
    }
    _levels.clear();
  }
}

/// 一帧里的字形批：按页分批，每页一次 drawRawAtlas（低档先画）。
class LumiereGlyphBatch {
  final Map<ui.Image, _GlyphRun> _runs = <ui.Image, _GlyphRun>{};

  /// 把字 [slot] 以字号 [px]（逻辑像素）、中心 ([cx], [cy])、旋转 [rotation] 加进批里。
  void add(
    LumiereGlyphAtlases atlases,
    int slot,
    double cx,
    double cy,
    double px,
    double rotation,
    int argb, {
    required double devicePixelRatio,
  }) {
    final LumiereGlyphAtlas level = atlases.levelFor(px * devicePixelRatio);
    (_runs[level.sheetOf(slot)] ??= _GlyphRun(level.em)).add(
      level.rectOf(slot),
      cx,
      cy,
      px * kLumiereGlyphCellRatio,
      rotation,
      argb,
    );
  }

  void flush(Canvas canvas) {
    if (_runs.isEmpty) return;
    final List<MapEntry<ui.Image, _GlyphRun>> runs = _runs.entries.toList()
      ..sort(
        (MapEntry<ui.Image, _GlyphRun> a, MapEntry<ui.Image, _GlyphRun> b) =>
            a.value.em.compareTo(b.value.em),
      );
    final Paint paint = Paint()..filterQuality = FilterQuality.medium;
    for (final MapEntry<ui.Image, _GlyphRun> r in runs) {
      r.value.flush(canvas, r.key, paint);
    }
    _runs.clear();
  }
}

class _GlyphRun {
  _GlyphRun(this.em);

  final double em;
  final List<double> _xf = <double>[];
  final List<double> _rects = <double>[];
  final List<int> _colors = <int>[];

  void add(
    Rect source,
    double cx,
    double cy,
    double sizePx,
    double rotation,
    int argb,
  ) {
    final double scale = sizePx / source.height;
    final double c = math.cos(rotation) * scale;
    final double s = math.sin(rotation) * scale;
    final double w = source.width;
    final double h = source.height;
    _xf
      ..add(c)
      ..add(s)
      ..add(cx - c * w / 2 + s * h / 2)
      ..add(cy - s * w / 2 - c * h / 2);
    _rects
      ..add(source.left)
      ..add(source.top)
      ..add(source.right)
      ..add(source.bottom);
    _colors.add(argb);
  }

  void flush(Canvas canvas, ui.Image image, Paint paint) {
    canvas.drawRawAtlas(
      image,
      Float32List.fromList(_xf),
      Float32List.fromList(_rects),
      Int32List.fromList(_colors),
      BlendMode.modulate,
      null,
      paint,
    );
  }
}

/// 场景持有的字形：当前一套图集 + 后台任务（补更高的档 / 换字体整套重建）。
///
/// 同一时刻只有一个后台任务；换字体会作废正在进行的任务。新图集就绪前一直画旧的。
class LumiereGlyphs {
  LumiereGlyphs(Iterable<String> chars, LumiereGlyphStyle style)
    : chars = LumiereGlyphAtlases.uniqueChars(chars) {
    _current = LumiereGlyphAtlases.build(this.chars, style);
  }

  final List<String> chars;
  late LumiereGlyphAtlases _current;
  final _Changed _changed = _Changed();

  /// 想要的字体（可能还在后台建）。
  LumiereGlyphStyle? _pendingStyle;
  int _generation = 0;
  Future<void>? _job;
  bool _disposed = false;

  /// 当前这套图集上光栅化失败过的档：不再每帧重试（换了一套图集才清空）。
  final Set<double> _failedEms = <double>{};

  /// 图集换了（补了档 / 换了字体），要重画。
  Listenable get changed => _changed;

  LumiereGlyphAtlases get current => _current;

  /// 后台正在建的字体（没有则 null）。
  @visibleForTesting
  LumiereGlyphStyle? get debugPendingStyle => _pendingStyle;

  /// 后台任务全部落定（测试用）。
  @visibleForTesting
  Future<void> get settled async {
    while (_job != null) {
      await _job;
    }
  }

  /// 换成 [style]：同字体且没有后台任务时什么都不做。旧图集一直画到新的一套就绪。
  void requestStyle(LumiereGlyphStyle style) {
    if (_disposed) return;
    if (_pendingStyle == style) return;
    if (style == _current.style) {
      // 切回了正在画的字体：作废还在建的那套就行。
      if (_pendingStyle != null) {
        _generation++;
        _pendingStyle = null;
      }
      return;
    }
    _startRebuild(style);
  }

  /// 字体注册表变了（运行时加载完自定义字体）：同字体整套重画一遍，拿到真字形而不是回落字体。
  void reload() {
    if (_disposed) return;
    _startRebuild(_pendingStyle ?? _current.style);
  }

  /// 帧末调用：画面上出现了比已有各档都大的字就在后台补那一档。
  void afterFrame() {
    if (_disposed || _job != null) return;
    final double? em = _current.wantedEm;
    if (em == null || _failedEms.contains(em)) return;
    final LumiereGlyphAtlases target = _current;
    final int gen = _generation;
    _run(onError: () => _failedEms.add(em), () async {
      final LumiereGlyphAtlas? level = await LumiereGlyphAtlas.rasterize(
        chars,
        target.style,
        em: em,
        cancelled: () => _disposed || gen != _generation,
      );
      if (level == null) return;
      if (_disposed || !identical(target, _current)) {
        level.dispose();
        return;
      }
      target.addLevel(level);
      _changed.fire();
    });
  }

  void _startRebuild(LumiereGlyphStyle style) {
    _pendingStyle = style;
    final int gen = ++_generation;
    final Set<double> ems = <double>{
      ..._current.builtEms,
      if (_current.wantedEm != null) _current.wantedEm!,
    };
    final Future<void>? previous = _job;
    _run(
      onError: () {
        // 这次没建成：放下挂起的字体，下次 build 再请求时重新建，不卡在「永远在建」。
        if (gen == _generation) _pendingStyle = null;
      },
      () async {
        // 等前一个任务退出（它看到代数变了会尽快放弃），同一时刻只排一份字。
        if (previous != null) await previous;
        if (_disposed || gen != _generation) return;
        final LumiereGlyphAtlases? next = await LumiereGlyphAtlases.rasterize(
          chars,
          style,
          ems: ems,
          cancelled: () => _disposed || gen != _generation,
        );
        if (next == null) return;
        if (_disposed || gen != _generation) {
          next.dispose();
          return;
        }
        _current.dispose();
        _current = next;
        _failedEms.clear();
        _pendingStyle = null;
        _changed.fire();
      },
    );
  }

  /// 起一个后台任务。失败（如 GPU 上下文不可用时 `toImage` 报错）照常上报 FlutterError，
  /// 任务本身正常结束：后面排队的任务不会跟着抛，旧图集继续画；[onError] 收拾状态。
  void _run(Future<void> Function() body, {required void Function() onError}) {
    late final Future<void> job;
    job = Future<void>(body)
        .catchError((Object error, StackTrace stack) {
          onError();
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'lumiere glyph atlas',
              context: ErrorDescription('while rasterizing the glyph atlas'),
            ),
          );
        })
        .whenComplete(() {
          if (identical(_job, job)) _job = null;
        });
    _job = job;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // `_changed` 不在这里 dispose：画家（RenderCustomPaint）在场景之后才从它摘监听。
    _current.dispose();
  }
}

class _Changed extends ChangeNotifier {
  void fire() => notifyListeners();
}
