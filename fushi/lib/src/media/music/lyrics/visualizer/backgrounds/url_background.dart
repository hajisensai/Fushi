/// 背景「自定义图片」（对应 folia `backgrounds/url/`）。folia 在这里用 iframe 嵌一个网页当背景；
/// Fushi 不在歌词动画下面跑网页（嵌网页要整套 WebView、还会吃掉输入与功耗），改成用户自己的图：
/// 素材库里的一组图（取最新导入的那张），或一个图片链接（走全应用的图片缓存与代理）。
/// 图按 cover 铺满，上面压 folia 同款的「上 15% → 下 35%」黑色渐变保证歌词可读。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/background_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_cover.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

abstract final class UrlBackgroundKeys {
  static const String source = 'source';
  static const String imagePack = 'imagePack';
  static const String url = 'url';
}

/// 来源：素材库。
const String kUrlBackgroundSourceImages = 'images';

/// 来源：图片链接。
const String kUrlBackgroundSourceLink = 'link';

final List<LyricVisualizerTuningSpec> urlBackgroundTunings =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerChoiceSpec(
        key: UrlBackgroundKeys.source,
        label: () => t.music_visualizer_background_url_source,
        options: <(String, String Function())>[
          (
            kUrlBackgroundSourceImages,
            () => t.music_visualizer_background_url_source_images,
          ),
          (
            kUrlBackgroundSourceLink,
            () => t.music_visualizer_background_url_source_link,
          ),
        ],
        initial: kUrlBackgroundSourceImages,
      ),
      lyricBgImagePackSpec(
        UrlBackgroundKeys.imagePack,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.choice(UrlBackgroundKeys.source, kUrlBackgroundSourceImages) ==
            kUrlBackgroundSourceImages,
      ),
      LyricVisualizerTextSpec(
        key: UrlBackgroundKeys.url,
        label: () => t.music_visualizer_background_url_link,
        maxLength: 2048,
        hint: () => 'https://',
        visibleWhen: (LyricVisualizerTuning v) =>
            v.choice(UrlBackgroundKeys.source, kUrlBackgroundSourceImages) ==
            kUrlBackgroundSourceLink,
      ),
    ];

final LyricVisualizerBackgroundEntry urlBackgroundEntry =
    LyricVisualizerBackgroundEntry(
      id: 'url',
      label: () => t.music_visualizer_background_url,
      icon: FushiIcons.link,
      tunings: urlBackgroundTunings,
      builder: (LyricVisualizerContext c, LyricVisualizerTuning tu) =>
          LyricVisualizerBackgroundView(
            context: c,
            tuning: tu,
            create: UrlBackgroundScene.new,
          ),
    );

/// 只认 http(s) 链接（其余协议当没填，不去读本地任意路径）。
String? urlBackgroundLinkOf(String raw) {
  final String s = raw.trim();
  final Uri? u = Uri.tryParse(s);
  if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return null;
  if (u.host.isEmpty) return null;
  return s;
}

/// 换图淡入（秒）。
const double _kFadeSeconds = 0.6;

class UrlBackgroundScene extends LyricVisualizerBackgroundScene {
  UrlBackgroundScene() {
    _pack.addListener(_onImage);
    _link.addListener(_onImage);
  }

  final LyricBgImageSource _pack = LyricBgImageSource();
  final LyricVisualizerImageLoader _link = LyricVisualizerImageLoader();
  late LyricVisualizerContext _c;
  bool _useLink = false;
  ui.Image? _shown;
  ui.Image? _sourceRef;
  ui.Image? _previous;
  double _wall = 0;
  double _fadeStart = 0;

  ui.Image? get _image => _useLink ? _link.image : _pack.image;

  void _onImage() {
    final ui.Image? next = _image;
    if (identical(next, _sourceRef)) return;
    _sourceRef = next;
    _previous?.dispose();
    _previous = _shown;
    _shown = next?.clone();
    _fadeStart = _wall;
    notifyListeners();
  }

  @override
  void configure(
    LyricVisualizerContext context,
    LyricVisualizerTuning tuning,
    double devicePixelRatio,
  ) {
    _c = context;
    _useLink =
        tuning.choice(UrlBackgroundKeys.source, kUrlBackgroundSourceImages) ==
        kUrlBackgroundSourceLink;
    if (_useLink) {
      _pack.select(coverPath: null);
      _link.load(urlBackgroundLinkOf(tuning.text(UrlBackgroundKeys.url, '')));
    } else {
      _link.load(null);
      _pack.select(
        coverPath: null,
        pack: tuning.assetPack(UrlBackgroundKeys.imagePack, 'default'),
        preferPack: true,
      );
    }
    _onImage();
  }

  @override
  void advance(LyricVisualizerTick tick) {
    _wall += tick.dt;
  }

  void _draw(Canvas canvas, ui.Image img, Rect all, double opacity) {
    final Size src = Size(img.width.toDouble(), img.height.toDouble());
    canvas.drawImageRect(
      img,
      Offset.zero & src,
      lyricBgCoverRect(src, all),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(0, 0, 0, opacity),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Rect all = Offset.zero & size;
    canvas.drawRect(all, Paint()..color = _c.palette.background);
    final ui.Image? img = _shown;
    // folia 没选网页时什么都不画（下面的纯色底透出来）。
    if (img == null && _previous == null) return;
    final double fade = _c.motion
        ? ((_wall - _fadeStart) / _kFadeSeconds).clamp(0.0, 1.0)
        : 1;
    if (_previous != null && fade < 1) _draw(canvas, _previous!, all, 1);
    if (img != null) _draw(canvas, img, all, fade);
    canvas.drawRect(
      all,
      Paint()
        ..shader = ui.Gradient.linear(
          all.topCenter,
          all.bottomCenter,
          const <Color>[
            Color.fromRGBO(0, 0, 0, 0.15),
            Color.fromRGBO(0, 0, 0, 0.35),
          ],
        ),
    );
  }

  @override
  void dispose() {
    _pack.removeListener(_onImage);
    _link.removeListener(_onImage);
    _pack.dispose();
    _link.dispose();
    _shown?.dispose();
    _previous?.dispose();
    super.dispose();
  }
}
