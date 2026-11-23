/// 主题图标集（folia `Theme.lyricsIcons`）：AI 主题按歌词挑 3–5 个「画面里该出现的东西」，样式拿来
/// 当装饰（莫奈浮动装饰、时计摆轮、绘光线稿、雾笺随手画、商籁粒子）。
///
/// folia 存 Lucide 图标名、运行时按名加载 Lucide；本 app 不带 Lucide，也不新增字体。这里是一个
/// **封闭集合**：每项映射到 app 已随包的语义图标（[FushiIcons]，Material Symbols 子集）；AI / 缓存里
/// 的名字（本集合的 id 或 folia 常见的 Lucide 名）经 [LyricVisualizerThemeIcon.fromName] 认领，认不出的
/// 丢掉。[LyricVisualizerThemeIcon.wire] 落盘（AI 主题缓存），冻结。
///
/// 少数几项（花 / 叶 / 伞 / 笑脸）语义图标里没有合适字形，[LyricVisualizerThemeIcon.glyph] 为 null：
/// 自带线稿的样式（雾笺）照画，只认字形的样式跳过它们（[LyricVisualizerTheme.glyphIcons]）。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/fushi_icons.dart';

/// 封闭的主题图标集合。
enum LyricVisualizerThemeIcon {
  star('star', FushiIcons.star, <String>['star', 'starhalf', 'stars']),
  sparkles('sparkles', FushiIcons.ai, <String>[
    'sparkle',
    'sparkles',
    'wand',
    'wand2',
    'wandsparkles',
  ]),
  heart('heart', FushiIcons.favorite, <String>[
    'heart',
    'hearthandshake',
    'heartcrack',
    'heartpulse',
    'heartoff',
  ]),
  moon('moon', FushiIcons.darkMode, <String>['moon', 'moonstar', 'moonstars']),
  sun('sun', FushiIcons.lightMode, <String>[
    'sun',
    'sunrise',
    'sunset',
    'sunmedium',
    'sundim',
    'sunsnow',
  ]),
  cloud('cloud', FushiIcons.cloud, <String>[
    'cloud',
    'cloudrain',
    'cloudsnow',
    'clouddrizzle',
    'cloudfog',
    'cloudy',
    'cloudsun',
    'cloudmoon',
    'cloudrainwind',
  ]),
  lightning('lightning', FushiIcons.flash, <String>[
    'zap',
    'cloudlightning',
    'bolt',
  ]),
  flame('flame', FushiIcons.streak, <String>['flame', 'flamekindling', 'fire']),
  music('music', FushiIcons.music, <String>[
    'music',
    'music2',
    'music3',
    'music4',
    'disc',
    'disc2',
    'disc3',
    'piano',
    'guitar',
    'drum',
  ]),
  soundwave('soundwave', FushiIcons.audio, <String>[
    'audiolines',
    'audiowaveform',
    'activity',
  ]),
  mic('mic', FushiIcons.mic, <String>['mic', 'micvocal', 'mic2']),
  headphones('headphones', FushiIcons.audiobook, <String>[
    'headphones',
    'headset',
  ]),
  voice('voice', FushiIcons.voice, <String>['speech', 'megaphone']),
  lightbulb('lightbulb', FushiIcons.lightbulb, <String>['lightbulb', 'lamp']),
  party('party', FushiIcons.celebration, <String>[
    'partypopper',
    'gift',
    'cake',
  ]),
  globe('globe', FushiIcons.globe, <String>['globe', 'earth', 'globe2']),
  compass('compass', FushiIcons.travelExplore, <String>[
    'compass',
    'map',
    'mappin',
    'plane',
    'navigation',
  ]),
  home('home', FushiIcons.home, <String>['home', 'house']),
  book('book', FushiIcons.books, <String>[
    'book',
    'bookopen',
    'bookheart',
    'library',
    'notebook',
  ]),
  camera('camera', FushiIcons.camera, <String>['camera', 'aperture', 'film']),
  picture('picture', FushiIcons.image, <String>['image', 'images', 'frame']),
  phone('phone', FushiIcons.phone, <String>['phone', 'smartphone']),
  clock('clock', FushiIcons.schedule, <String>['clock', 'watch', 'alarmclock']),
  hourglass('hourglass', FushiIcons.timer, <String>['hourglass', 'timer']),
  calendar('calendar', FushiIcons.calendar, <String>[
    'calendar',
    'calendardays',
    'calendarheart',
  ]),
  key('key', FushiIcons.key, <String>['key', 'keyround']),
  lock('lock', FushiIcons.lock, <String>['lock', 'lockkeyhole']),
  shield('shield', FushiIcons.shield, <String>['shield', 'shieldcheck']),
  flag('flag', FushiIcons.flag, <String>['flag']),
  trophy('trophy', FushiIcons.trophy, <String>[
    'trophy',
    'medal',
    'award',
    'crown',
  ]),
  person('person', FushiIcons.person, <String>[
    'user',
    'userround',
    'personstanding',
  ]),
  people('people', FushiIcons.group, <String>['users', 'usersround']),
  chat('chat', FushiIcons.forum, <String>[
    'messagecircle',
    'messagesquare',
    'messagessquare',
    'messagecircleheart',
  ]),
  game('game', FushiIcons.games, <String>['gamepad', 'gamepad2', 'joystick']),
  signal('signal', FushiIcons.wifi, <String>[
    'wifi',
    'radio',
    'signal',
    'antenna',
  ]),
  fingerprint('fingerprint', FushiIcons.fingerprint, <String>['fingerprint']),
  // 以下没有合适的语义图标字形：只有自带线稿的样式画它们。
  flower('flower', null, <String>['flower', 'flower2', 'rose', 'clover']),
  leaf('leaf', null, <String>['leaf', 'sprout', 'trees', 'treepine', 'tree']),
  umbrella('umbrella', null, <String>['umbrella']),
  smile('smile', null, <String>['smile', 'laugh', 'smileplus']);

  const LyricVisualizerThemeIcon(this.wire, this.glyph, this.aliases);

  /// 落盘 id（冻结）。
  final String wire;

  /// 语义图标字形；null = 只有自带线稿的样式能画。
  final IconData? glyph;

  /// 认领的名字（小写、去掉非字母数字后比对）：folia 常见的 Lucide 名。
  final List<String> aliases;

  /// 一个主题最多带几个图标（folia 提示词要 3–5 个）。
  static const int maxPerTheme = 6;

  static final Map<String, LyricVisualizerThemeIcon> _byName =
      <String, LyricVisualizerThemeIcon>{
        for (final LyricVisualizerThemeIcon i
            in values) ...<String, LyricVisualizerThemeIcon>{
          for (final String a in i.aliases) a: i,
          i.wire: i,
        },
      };

  /// 本集合的 id 或 Lucide 名（`CloudRain` / `cloud-rain` / `cloudrain` 都认）→ 图标；认不出 null。
  static LyricVisualizerThemeIcon? fromName(Object? name) {
    if (name is! String) return null;
    final String key = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    if (key.isEmpty) return null;
    return _byName[key];
  }

  /// 一串名字 → 去重、保序、最多 [maxPerTheme] 个（AI 回复与缓存共用这一道校验）。
  static List<LyricVisualizerThemeIcon> listFrom(Object? raw) {
    if (raw is! List) return const <LyricVisualizerThemeIcon>[];
    final List<LyricVisualizerThemeIcon> out = <LyricVisualizerThemeIcon>[];
    for (final Object? e in raw) {
      final LyricVisualizerThemeIcon? icon = fromName(e);
      if (icon == null || out.contains(icon)) continue;
      out.add(icon);
      if (out.length >= maxPerTheme) break;
    }
    return List<LyricVisualizerThemeIcon>.unmodifiable(out);
  }
}

final Map<(int, String?, int, int), ui.Paragraph> _glyphCache =
    <(int, String?, int, int), ui.Paragraph>{};

/// 在 [canvas] 上以 [center] 为中心画一个图标字形（边长 [size]，颜色 [color]）。字形按（码位、字族、
/// 字号、颜色）缓存排版结果，逐帧调用不重新排版。
void paintLyricVisualizerIconGlyph(
  Canvas canvas,
  IconData icon,
  Offset center,
  double size,
  Color color,
) {
  if (size <= 0 || color.a <= 0) return;
  final int px = size.round().clamp(1, 1024);
  final (int, String?, int, int) key = (
    icon.codePoint,
    icon.fontFamily,
    px,
    color.toARGB32(),
  );
  ui.Paragraph? p = _glyphCache[key];
  if (p == null) {
    if (_glyphCache.length > 256) {
      for (final ui.Paragraph old in _glyphCache.values) {
        old.dispose();
      }
      _glyphCache.clear();
    }
    final ui.ParagraphBuilder b =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: icon.fontFamily,
              fontSize: px.toDouble(),
              height: 1,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: color,
              fontFamily: icon.fontFamily,
              fontSize: px.toDouble(),
              height: 1,
            ),
          )
          ..addText(String.fromCharCode(icon.codePoint));
    p = b.build()..layout(const ui.ParagraphConstraints(width: 4096));
    _glyphCache[key] = p;
  }
  final double scale = size / px;
  canvas.save();
  canvas.translate(center.dx, center.dy);
  if (scale != 1) canvas.scale(scale);
  canvas.drawParagraph(p, Offset(-p.maxIntrinsicWidth / 2, -p.height / 2));
  canvas.restore();
}
