part of 'music_lyrics_page.dart';

// ---------------------------------------------------------------------------
// Apple 设计系统下的歌词 / 正在播放页（用户 2026-11-24：「看看布局抄一下」，参考
// macOS Apple Music 全屏歌词）。只在 isGlassDesign 下由 build 分派进来；M3E 的
// 分栏 / 舞台 / 唱片三种布局不经过这里。
//
// 宽窗：左列（约三分之一宽，竖直居中）= 大封面 → 标题 + 「艺人 — 专辑」与右侧 ☆ ⋯
// 两枚小圆钮 → 细进度条 + 两端时间 → 五键传输行（随机 · 上一首 · 播放 · 下一首 ·
// 循环）→ 音量滑杆；右列 = Apple 式歌词（左对齐大字、当前行在约 1/3 高处、离当前行
// 越远越模糊越淡）。
// 窄窗 / iOS 档：iPhone Apple Music 的两态——封面态（大封面 + 同一套控件）与歌词态
// （顶部小封面 + 标题、歌词、底部进度与传输行），沿用 [_showLyrics] 与顶栏切换键。
// ---------------------------------------------------------------------------

/// Apple 下歌词区的外观：左对齐大号粗体、当前行停在视口约 1/3 高处，已唱 = label、
/// 未唱 = label 35%，注音 / 罗马音 / 翻译副行 secondaryLabel；非当前行按与当前行的
/// 距离递增模糊、递减不透明度（[KaraokeLyricsView] 自己按距离分级，[blur] 跟随
/// 「非当前行模糊」偏好）。翻译 / 罗马音 / 注音三条副行的显隐跟 M3E 同一组偏好。
KaraokeLyricsAppearance musicAppleLyricsAppearance(
  FushiAppleColors apple, {
  required bool blur,
  bool showTranslation = true,
  bool showRomanization = true,
  bool showRuby = true,
}) => KaraokeLyricsAppearance(
  fontSize: 34,
  fontWeight: FontWeight.w800,
  activeColor: apple.label,
  inactiveColor: apple.label.withValues(alpha: 0.35),
  secondaryColor: apple.secondaryLabel,
  blurInactive: blur,
  showTranslation: showTranslation,
  showRomanization: showRomanization,
  showRuby: showRuby,
  anchor: 1 / 3,
  rowSpacing: 38,
  horizontalPadding: 8,
  inactiveOpacity: 0.5,
);

/// Apple 下拉菜单与窗口边缘的安全距离：放不下就翻到按钮上方，而不是贴边。
const double _kAppleMenuSafeMargin = 16;

/// 测试钩子：Apple 歌词页封面（大封面复用 [_LyricsCover] 的 3D 倾斜 + 光面）。
@visibleForTesting
Widget debugMusicAppleLyricsCover(MusicPlayItem? item, double size) =>
    _AppleLyricsCover(item: item, size: size);

/// Apple 歌词页封面。大封面（宽窗左列、窄窗封面态）直接用改动前歌词页同一枚
/// [_LyricsCover]——[musicMaterialCover] 的专辑光面材质（扫光 / 高光、投影随倾斜
/// 走、光面裁在圆角内）+ [FushiHoverLift] 指针 3D 倾斜视差，强度与 M3E 一致，减弱
/// 动态效果照原实现判（用户 2026-11-24「专辑的3d斜视差没了而且光面没了」）。
/// 歌词态顶部的小封面（< 160）只要连续曲率圆角（半径同专辑材质
/// [shelfAppleAlbumRadius]），不倾斜。
class _AppleLyricsCover extends StatelessWidget {
  const _AppleLyricsCover({required this.item, required this.size});

  final MusicPlayItem? item;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (size >= 160) {
      return SizedBox.square(
        key: const ValueKey<String>('music_lyrics_apple_cover'),
        dimension: size,
        child: _LyricsCover(item: item, size: size),
      );
    }
    // 与专辑材质同一套按尺寸取的连续曲率半径（[shelfAppleAlbumRadius]）。
    final double radius = shelfAppleAlbumRadius(size);
    final RoundedSuperellipseBorder shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    return SizedBox.square(
      key: const ValueKey<String>('music_lyrics_apple_cover'),
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          shadows: size >= 160
              ? <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 40,
                    offset: const Offset(0, 14),
                  ),
                ]
              : const <BoxShadow>[],
        ),
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(radius),
          child: MusicCover(
            coverPath: item?.coverPath,
            size: size,
            borderRadius: BorderRadius.zero,
            title: item?.title,
          ),
        ),
      ),
    );
  }
}

/// 标题行右侧的小圆钮（☆ / ⋯）：Apple Music 那两枚细的半透明填充圆，字形 label 色；
/// 自带焦点 / Enter（[FushiPlainButton]）与悬停提示。
class _AppleTitleCircleButton extends StatelessWidget {
  const _AppleTitleCircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final double extent = fushiAppleCompact(context)
        ? 30 * fushiAppleMacScale(context)
        : 36;
    final bool on = selected ?? false;
    return FushiTooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        selected: selected,
        child: FushiPlainButton(
          onPressed: onPressed,
          borderRadius: BorderRadius.circular(extent / 2),
          semanticLabel: tooltip,
          fill: apple.tertiaryFill,
          child: SizedBox.square(
            dimension: extent,
            child: Center(
              child: AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                transitionBuilder: (Widget child, Animation<double> a) =>
                    FadeTransition(
                      opacity: a,
                      child: ScaleTransition(scale: a, child: child),
                    ),
                child: FushiIcon(
                  on ? FushiIcons.filled(icon) : icon,
                  key: ValueKey<bool>(on),
                  size: extent * 0.5,
                  color: apple.label,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Apple 音量行：speaker — 细滑杆 — speaker.wave.3（secondaryLabel 字形），读写
/// [AppModel.musicVolume]（与迷你条音量键同一份偏好）。
class _AppleVolumeRow extends StatefulWidget {
  const _AppleVolumeRow({required this.appModel});

  final AppModel appModel;

  @override
  State<_AppleVolumeRow> createState() => _AppleVolumeRowState();
}

class _AppleVolumeRowState extends State<_AppleVolumeRow> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final double v = (_dragging ?? widget.appModel.musicVolume).clamp(0, 100);
    return Row(
      key: const ValueKey<String>('music_lyrics_apple_volume'),
      children: <Widget>[
        FushiIcon(
          v <= 0 ? FushiIcons.volumeOff : FushiIcons.volumeDown,
          size: 16,
          color: apple.secondaryLabel,
        ),
        Expanded(
          child: Semantics(
            label: t.music_volume_title,
            // 与进度条同一份配色（[fushiAppleTrackPlayedColor]）：静止
            // secondaryLabel、拖动时过渡到 label，不用强调色。
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: _dragging == null ? 0 : 1),
              duration: fushiMotionDuration(context, FushiMotion.short),
              builder: (BuildContext context, double emphasis, _) =>
                  FushiSlider(
                    key: const ValueKey<String>(
                      'music_lyrics_apple_volume_slider',
                    ),
                    value: v,
                    max: 100,
                    activeColor: fushiAppleTrackPlayedColor(apple, emphasis),
                    inactiveColor: apple.fill,
                    onChanged: (double next) {
                      setState(() => _dragging = next);
                      unawaited(widget.appModel.setMusicVolume(next));
                    },
                    onChangeEnd: (_) => setState(() => _dragging = null),
                  ),
            ),
          ),
        ),
        FushiIcon(FushiIcons.volumeUp, size: 16, color: apple.secondaryLabel),
      ],
    );
  }
}

extension _MusicLyricsAppleLayout on _MusicLyricsPageState {
  /// Apple 宽窗：左列控件 + 右列歌词（见文件头）。
  Widget _buildAppleWide(BuildContext context, MusicPlayItem? item) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 左列宽 = 封面边长：约三分之一窗宽，且给下面的标题 / 进度 / 传输 / 音量
        // （约 260）留出高度。
        final double column = math
            .min(c.maxWidth * 0.32, c.maxHeight - 320)
            .clamp(220.0, 520.0);
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: _buildTopActions(context, showBack: true),
            ),
            Expanded(
              child: Row(
                children: <Widget>[
                  Expanded(
                    flex: 9,
                    child: Center(
                      child: SingleChildScrollView(
                        // 右侧歌词才是主滚动（同分栏布局）。
                        primary: false,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        child: SizedBox(
                          width: column,
                          child: Column(
                            key: const ValueKey<String>(
                              'music_lyrics_apple_column',
                            ),
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              _AppleLyricsCover(item: item, size: column),
                              const SizedBox(height: 28),
                              _buildAppleTitleRow(context, item),
                              const SizedBox(height: 20),
                              _buildSeek(),
                              const SizedBox(height: 8),
                              _buildAppleTransport(context, column),
                              const SizedBox(height: 12),
                              _AppleVolumeRow(appModel: appModelNoUpdate),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 11,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 24,
                        end: 48,
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: _buildLyricsArea(context, item),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Apple 窄窗 / iOS：iPhone Apple Music 的封面态 ↔ 歌词态（[_showLyrics]，顶栏
  /// 「显示歌词 / 显示封面」切换）。
  Widget _buildAppleNarrow(BuildContext context, MusicPlayItem? item) {
    final Widget face = _showLyrics
        ? KeyedSubtree(
            key: const ValueKey<String>('apple_lyrics'),
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                  child: Row(
                    children: <Widget>[
                      _AppleLyricsCover(item: item, size: 56),
                      const SizedBox(width: 12),
                      Expanded(child: _buildAppleTitleRow(context, item)),
                    ],
                  ),
                ),
                Expanded(child: _buildLyricsArea(context, item)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildSeek(),
                      LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints c) =>
                            _buildAppleTransport(context, c.maxWidth),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        : KeyedSubtree(
            key: const ValueKey<String>('apple_cover'),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                final double width = c.maxWidth - 48;
                final double cover = math
                    .min(width, c.maxHeight - 300)
                    .clamp(120.0, 520.0);
                return SingleChildScrollView(
                  primary: false,
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: Column(
                    key: const ValueKey<String>('music_lyrics_apple_column'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Center(
                        child: _AppleLyricsCover(item: item, size: cover),
                      ),
                      const SizedBox(height: 28),
                      _buildAppleTitleRow(context, item),
                      const SizedBox(height: 16),
                      _buildSeek(),
                      const SizedBox(height: 4),
                      _buildAppleTransport(context, width),
                      const SizedBox(height: 8),
                      _AppleVolumeRow(appModel: appModelNoUpdate),
                    ],
                  ),
                );
              },
            ),
          );
    return Column(
      children: <Widget>[
        _buildTopActions(context, showBack: true, showFaceToggle: true),
        Expanded(
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            transitionBuilder: (Widget child, Animation<double> a) =>
                FushiSharedAxisTransition(
                  animation: a,
                  secondaryAnimation: const AlwaysStoppedAnimation<double>(0),
                  child: child,
                ),
            child: face,
          ),
        ),
      ],
    );
  }

  /// 标题（半粗 label）+ 「艺人 — 专辑」（secondaryLabel，两段各自可点）左对齐，
  /// 同一行最右是 ☆（喜欢，只有能收藏的曲目才有）与 ⋯（次级功能菜单）。
  Widget _buildAppleTitleRow(BuildContext context, MusicPlayItem? item) {
    final FushiAppleColors apple = appleColorsOf(context);
    return Row(
      key: const ValueKey<String>('music_lyrics_apple_title_row'),
      children: <Widget>[
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                item?.title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.titleMedium.copyWith(
                  fontWeight: FontWeight.w600,
                  color: apple.label,
                ),
              ),
              _buildArtistAlbumLinks(
                context,
                item,
                context.fushiType.bodyMedium.copyWith(
                  color: apple.secondaryLabel,
                ),
                separator: ' — ',
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _buildAppleStarButton(),
        const SizedBox(width: 8),
        _buildAppleMoreMenu(context),
      ],
    );
  }

  /// ☆ / ★：在线平台的「喜欢」（原 ♥），只有声明了收藏能力的插件曲目才出现。
  Widget _buildAppleStarButton() {
    final MusicSession session = appModelNoUpdate.musicSession;
    return ListenableBuilder(
      listenable: session,
      builder: (BuildContext context, _) {
        final MusicPlayItem? item = session.engine.current;
        if (item == null || !session.canFavorite(item)) {
          return const SizedBox.shrink();
        }
        final bool liked = session.isFavorite(item);
        return _AppleTitleCircleButton(
          key: const ValueKey<String>('music_lyrics_favorite'),
          icon: FushiIcons.star,
          selected: liked,
          tooltip: liked ? t.music_favorite_remove : t.music_favorite_add,
          onPressed: () => unawaited(_toggleFavorite(session, item)),
        );
      },
    );
  }

  /// ⋯：次级功能收进 Apple pull-down（[FushiMenuAnchor] 的 Apple 面板，与右上「⋯」
  /// 的顶栏菜单同一套菜单外观 / 行高 / 对勾列）。两组：
  /// - 歌词：偏移当前值作组标题，「延后 / 提前」点了不收起可连点；「循环当前行」是
  ///   勾选项（开 = ✓）；循环开着时多一行「再加一行」。
  /// - 播放：音质 / 音效 / 播放队列 = 标题 + 行尾 secondaryLabel 当前值；音效处理中、
  ///   桌面歌词开着时 ✓。
  /// 下方空间不够时 MenuAnchor 整块翻到按钮上方，四周留 [_kAppleMenuSafeMargin]。
  Widget _buildAppleMoreMenu(BuildContext context) {
    final bool synced = _lyrics?.timeline.isSynced ?? false;
    final MusicPlayItem? item = _engine.current;
    final String? quality = item != null && musicItemQualitySelectable(item)
        ? musicPluginQualityLabel(
            appModelNoUpdate.musicPluginQualityFor(item.path),
          )
        : null;
    final bool effectsOn = appModelNoUpdate.musicAudioEffects.isActive;
    final String effects = appModelNoUpdate.musicAudioEffects.enabled
        ? musicEqPresetLabel(appModelNoUpdate.musicEqPreset)
        : t.music_eq_off;
    Widget value(String text) => Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: appleColorsOf(context).secondaryLabel),
    );
    Widget action(
      String key,
      IconData icon,
      String label,
      VoidCallback onPressed, {
      bool close = true,
      String? trailing,
    }) => MenuItemButton(
      key: ValueKey<String>(key),
      closeOnActivate: close,
      leadingIcon: FushiIcon(icon),
      trailingIcon: trailing == null ? null : value(trailing),
      onPressed: onPressed,
      child: Text(label),
    );
    Widget toggle(
      String key,
      String label,
      bool on,
      VoidCallback onPressed, {
      String? trailing,
    }) => CheckboxMenuButton(
      key: ValueKey<String>(key),
      value: on,
      onChanged: (_) => onPressed(),
      trailingIcon: trailing == null ? null : value(trailing),
      child: Text(label),
    );
    final List<Widget> lyricTools = <Widget>[
      if (synced) ...<Widget>[
        FushiAppleMenuSectionHeader(t.music_lyrics_offset_value(ms: _offsetMs)),
        action(
          'music_lyrics_offset_earlier',
          FushiIcons.remove,
          t.music_lyrics_offset_later,
          () => _nudgeOffset(-kMusicLyricsOffsetStepMs),
          close: false,
        ),
        action(
          'music_lyrics_offset_later',
          FushiIcons.add,
          t.music_lyrics_offset_earlier,
          () => _nudgeOffset(kMusicLyricsOffsetStepMs),
          close: false,
        ),
        if (_engine.capabilities.abLoop)
          toggle(
            'music_lyrics_ab_loop',
            t.music_lyrics_ab_loop_line,
            _loopLines != null,
            () => unawaited(_toggleLoop()),
          ),
        if (_loopLines != null)
          action(
            'music_lyrics_ab_loop_extend',
            FushiIcons.addCircle,
            t.music_lyrics_ab_loop_extend,
            () => unawaited(_extendLoop()),
          ),
      ],
    ];
    final List<Widget> playback = <Widget>[
      if (quality != null)
        action(
          'music_lyrics_quality',
          FushiIcons.highQuality,
          t.music_quality_title,
          () => unawaited(
            showMusicQualitySheet(_themedContext, appModelNoUpdate),
          ),
          trailing: quality,
        ),
      if (_engine.capabilities.signalPath)
        toggle(
          'music_lyrics_effects',
          t.music_effects_title,
          effectsOn,
          () => unawaited(_openEffects()),
          trailing: effects,
        ),
      if (FloatingLyricChannel.supported)
        toggle(
          'music_lyrics_desktop_menu',
          t.music_desktop_lyrics_title,
          appModel.musicDesktopLyrics,
          () => unawaited(_toggleDesktopLyrics()),
        ),
      action(
        'music_lyrics_queue',
        FushiIcons.playlist,
        t.music_queue_title,
        () => unawaited(showMusicQueue(_themedContext, _engine)),
        trailing: '${_engine.queue.length}',
      ),
    ];
    return FushiMenuAnchor(
      reservedPadding: const EdgeInsets.all(_kAppleMenuSafeMargin),
      menuChildren: <Widget>[
        ...lyricTools,
        if (lyricTools.isNotEmpty) const FushiAppleMenuDivider(),
        ...playback,
      ],
      builder: (BuildContext context, MenuController menu, Widget? _) =>
          _AppleTitleCircleButton(
            key: const ValueKey<String>('music_lyrics_apple_more'),
            icon: FushiIcons.moreHoriz,
            tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          ),
    );
  }

  /// 五键传输行，沿 [width]（= 封面宽）均匀铺开：随机 · 上一首 · 播放 / 暂停（最大）·
  /// 下一首 · 循环。全是无底无着色裸字形；随机 / 循环开时实心 + label 色。
  Widget _buildAppleTransport(BuildContext context, double width) {
    final MusicPlayerEngine engine = _engine;
    final double k = width.isFinite
        ? (width / 360).clamp(0.8, 1.15).toDouble()
        : 1.0;
    final MusicRepeatMode repeat = engine.repeatMode;
    final bool modes = engine.canShuffleOrRepeat;
    final MusicRepeatMode nextRepeat = switch (repeat) {
      MusicRepeatMode.off => MusicRepeatMode.all,
      MusicRepeatMode.all => MusicRepeatMode.one,
      MusicRepeatMode.one => MusicRepeatMode.off,
    };
    return Row(
      key: const ValueKey<String>('music_lyrics_apple_transport'),
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        FushiAppleGlyphButton(
          key: const ValueKey<String>('music_lyrics_shuffle'),
          icon: FushiIcons.shuffle,
          selected: engine.shuffled,
          tooltip: t.music_play_mode_shuffle,
          glyphSize: 20 * k,
          extent: 44,
          onPressed: modes
              ? () => unawaited(engine.setShuffle(!engine.shuffled))
              : null,
        ),
        FushiAppleGlyphButton(
          key: const ValueKey<String>('music_lyrics_previous'),
          icon: FushiIcons.fastRewind,
          tooltip: t.shortcut_action_music_previous_track,
          prominent: true,
          glyphSize: 32 * k,
          extent: 56 * k,
          onPressed: engine.canSkipPrevious
              ? () => unawaited(engine.skipPrevious())
              : null,
        ),
        FushiApplePlayPauseButton(
          key: const ValueKey<String>('music_lyrics_play_pause'),
          isPlaying: engine.isPlaying,
          tooltip: engine.isPlaying ? t.pause : t.play,
          glyphSize: 50 * k,
          extent: 68 * k,
          onPressed: () => unawaited(engine.togglePlayPause()),
        ),
        FushiAppleGlyphButton(
          key: const ValueKey<String>('music_lyrics_next'),
          icon: FushiIcons.fastForward,
          tooltip: t.shortcut_action_music_next_track,
          prominent: true,
          glyphSize: 32 * k,
          extent: 56 * k,
          onPressed: () => unawaited(engine.skipNext()),
        ),
        FushiAppleGlyphButton(
          key: const ValueKey<String>('music_lyrics_repeat'),
          icon: repeat == MusicRepeatMode.one
              ? FushiIcons.repeatOne
              : FushiIcons.repeat,
          selected: repeat != MusicRepeatMode.off,
          tooltip: switch (repeat) {
            MusicRepeatMode.off => t.music_play_mode_sequential,
            MusicRepeatMode.all => t.music_play_mode_repeat_all,
            MusicRepeatMode.one => t.music_play_mode_repeat_one,
          },
          glyphSize: 20 * k,
          extent: 44,
          onPressed: modes
              ? () => unawaited(engine.setRepeatMode(nextRepeat))
              : null,
        ),
      ],
    );
  }
}
