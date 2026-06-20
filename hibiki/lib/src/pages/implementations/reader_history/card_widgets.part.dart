// GENERATED-NOTE: extracted from reader_hibiki_history_page.dart (TODO-587).
part of '../reader_hibiki_history_page.dart';

/// 自适应标签列在给定可用高度下能放几个 chip slot。
///
/// 根因守卫：当 [maxHeight] 无界（== infinity，例如标签覆盖层用
/// `Positioned(top, left)`（无 bottom/height）落进 `Stack(fit: StackFit.expand)`
/// 时拿到 unbounded 约束），旧实现 `(maxHeight * 0.55 / chipHeight).floor()` 会在
/// Infinity 上抛 `UnsupportedError: Infinity or NaN toInt` —— 表现为书本打 tag 后
/// 封面卡片渲染异常（debug 红框/错误占位）。无界时返回全部标签数，渲染全部、由父
/// 级自然裁剪，而不是吞异常或硬编码 slot。
@visibleForTesting
int adaptiveTagSlots({
  required double maxHeight,
  required int tagCount,
  double chipHeight = 22.0,
}) {
  if (tagCount <= 0) return 0;
  if (!maxHeight.isFinite) return tagCount;
  final double usable = maxHeight * 0.55;
  return (usable / chipHeight).floor().clamp(1, tagCount);
}

/// 书架书卡封面右上角类型徽章（有声书 / 普通书）的方框边长（逻辑像素）。
///
/// 历史：早期徽章夹在封面下方的 footer 文字行里、紧贴小号书名，读作一个克制的小角标。
/// TODO-355 把徽章移到封面图上后，旧布局用 `SizedBox.square(gap*5=40) + BoxFit.scaleDown`
/// 包住内在 22px（HibikiBadge：icon 14 + padding gap 8）的徽章，徽章按 22px 满尺寸渲染。
/// TODO-361 误把方框收到 `gap*2=16` + `BoxFit.contain`，把 22px 徽章硬缩到 16px，
/// 反而「太小看不清」（TODO-552 用户报回归）。这里恢复书架徽章的正常大小：方框等于徽章
/// 内在尺寸 22px，配合 `BoxFit.contain` 既不放大也不缩小，徽章按 22px 满尺寸渲染。
/// 用顶层常量 + 测试可见，便于 widget 守卫断言渲染尺寸，防止再次漂移。
const double kShelfCoverBadgeDimension = 22.0;

/// 书架封面图按高度等比缩放、保持封面原始比例（永不变形）。
///
/// TODO-480 曾把这里从 [BoxFit.fitHeight] 改成 [BoxFit.cover] 以「占满卡片、消除
/// 留白」，但封面区域宽高比在 TODO-455 把书名移到下方 40px footer 后已经不再等于
/// 封面图比例（封面区被压扁成更宽矮的形状），`cover` 会放大裁切，封面构图被截掉
/// 上/下，肉眼读作「封面被压缩变形」。书架封面诉求是按比例正常显示（TODO-552），
/// 故改回 `fitHeight`：按封面区高度等比缩放、保持比例，两侧溢出由外层 `ClipRect`
/// 裁掉，封面竖向全貌完整不变形。
BoxFit get _bookCardCoverFit => BoxFit.fitHeight;

/// Stable below-cover title footer height for reader shelf cards.
///
/// The cover and title areas must not resize when a title wraps to two lines;
/// this fixed footer keeps long book names from pushing the grid around.
const double kShelfTitleFooterHeight = 40.0;

/// card domain methods extracted via part-of (TODO-587); shared private scope.
extension _ReaderHistoryCardWidgets on _ReaderHibikiHistoryPageState {
  Widget _tagChip(BookTagRow tag) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: _cardTagChipPadding(tokens),
      child: HibikiTagChip(
        label: tag.name,
        color: Color(tag.colorValue),
      ),
    );
  }

  Widget _overflowChip(int count) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: _cardTagChipPadding(tokens),
      child: HibikiTagChip(
        label: '+$count',
      ),
    );
  }

  EdgeInsetsDirectional _cardTagChipPadding(HibikiDesignTokens tokens) {
    return EdgeInsetsDirectional.only(
      end: tokens.spacing.gap / 2,
      bottom: tokens.spacing.gap / 4,
    );
  }

  Widget _adaptiveTagColumn(List<BookTagRow> tags) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final int maxSlots = adaptiveTagSlots(
          maxHeight: constraints.maxHeight,
          tagCount: tags.length,
        );

        if (maxSlots >= tags.length) {
          return _uniformWidthTagColumn(
            [for (final tag in tags) _tagChip(tag)],
          );
        }

        final int visibleCount = maxSlots <= 1 ? 1 : maxSlots - 1;
        final int overflow = tags.length - visibleCount;
        return _uniformWidthTagColumn([
          for (final tag in tags.take(visibleCount)) _tagChip(tag),
          if (overflow > 0 && maxSlots > 1) _overflowChip(overflow),
        ]);
      },
    );
  }

  /// BUG-220(子2): 卡片左上角竖排标签原来用 `crossAxisAlignment.start`，每个 chip
  /// 宽度等于自身文字宽度，导致一行长一行短的参差。用 `IntrinsicWidth` 把整列宽度
  /// 收敛到最宽 chip，再用 `stretch` 让每个 chip 拉到该统一宽度（chip 内部文字仍左
  /// 对齐），竖排整齐。不改 [HibikiTagChip]，不影响别处用法。
  Widget _uniformWidthTagColumn(List<Widget> chips) {
    return IntrinsicWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: chips,
      ),
    );
  }

  String? _existingCoverFilePath(String? coverPath) {
    if (coverPath == null || coverPath.isEmpty) return null;
    try {
      return File(coverPath).existsSync() ? coverPath : null;
    } catch (_) {
      return null;
    }
  }

  Widget? _buildCoverFromUri(String? coverUri, IconData placeholderIcon) {
    if (coverUri == null || coverUri.isEmpty) return null;
    String? coverPath;
    if (coverUri.startsWith('file://')) {
      try {
        coverPath = Uri.parse(coverUri).toFilePath();
      } catch (_) {
        coverPath = null;
      }
    } else if (p.isAbsolute(coverUri)) {
      coverPath = coverUri;
    }
    final String? existingPath = _existingCoverFilePath(coverPath);
    return existingPath == null
        ? null
        : _buildFileCover(existingPath, placeholderIcon);
  }

  Widget _buildFileCover(String coverPath, IconData placeholderIcon) {
    return FadeInImage(
      imageErrorBuilder: (_, __, ___) => _coverPlaceholderIcon(
        placeholderIcon,
      ),
      placeholder: MemoryImage(kTransparentImage),
      image: FileImage(File(coverPath)),
      alignment: Alignment.topCenter,
      fit: _bookCardCoverFit,
    );
  }

  Widget _coverPlaceholderIcon(IconData icon) {
    return Center(
      child: Icon(
        icon,
        size: 40,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _bookCardShell({
    required VoidCallback onTap,
    required VoidCallback onLongPress,
    required Widget child,
    Key? cardKey,
    HibikiFocusId? focusId,
    String? selectionKey,
    Object? dragBookId,
    void Function(BookTagRow tag)? onTagDropped,
  }) {
    final bool selected =
        selectionKey != null && _selectedKeys.contains(selectionKey);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color selectionColor = tokens.surfaces.primary;
    final double selectionInset = tokens.spacing.gap / 2;
    final double selectionPadding = tokens.spacing.gap / 4;
    final double selectionIconSize = tokens.spacing.gap * 1.75;
    final VoidCallback effectiveTap = _selectionMode && selectionKey != null
        ? () => _toggleSelection(selectionKey)
        : onTap;
    Widget interactiveCard = Padding(
      key: cardKey,
      padding: EdgeInsets.all(tokens.spacing.rowVertical),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          canRequestFocus: false,
          borderRadius: tokens.radii.cardRadius,
          onTap: effectiveTap,
          onLongPress: _selectionMode ? null : onLongPress,
          // 桌面端鼠标右键打开与长按相同的书籍上下文菜单（PC 用户惯例）。
          onSecondaryTap: _selectionMode ? null : onLongPress,
          child: AspectRatio(
            aspectRatio: mediaSource.aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                child,
                if (_selectionMode && selectionKey != null)
                  Positioned(
                    top: selectionInset,
                    left: selectionInset,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: selected
                              ? selectionColor
                              : tokens.surfaces.page.withValues(alpha: 0.7),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected
                                ? selectionColor
                                : tokens.surfaces.outline,
                            width: 1.5,
                          ),
                        ),
                        padding: EdgeInsets.all(selectionPadding),
                        child: Icon(
                          Icons.check,
                          size: selectionIconSize,
                          color: selected
                              ? theme.colorScheme.onPrimary
                              : Colors.transparent,
                        ),
                      ),
                    ),
                  ),
                if (selected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color:
                              tokens.surfaces.primary.withValues(alpha: 0.12),
                          borderRadius: tokens.radii.cardRadius,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (focusId != null && HibikiFocusRoot.maybeControllerOf(context) != null) {
      interactiveCard = Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              effectiveTap();
              return null;
            },
          ),
        },
        child: HibikiFocusTarget(id: focusId, child: interactiveCard),
      );
    }
    // Gamepad long-press (hold A) on the focused card invokes the same
    // onLongPress as the mouse (book details / actions). In selection mode the
    // long-press is disabled (tap toggles selection), so it's a pass-through.
    final Widget card = GamepadLongPressActions(
      onLongPress: _selectionMode ? null : onLongPress,
      child: interactiveCard,
    );
    if (dragBookId == null || onTagDropped == null || _selectionMode) {
      return card;
    }
    return BookDragTarget(
      bookId: dragBookId,
      onTagDropped: onTagDropped,
      child: card,
    );
  }

  Widget _bookCardLayout({
    required String title,
    required Widget cover,
    Widget? tagLabels,
    Widget? coverBadge,
    Widget? metadata,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double overlayInset = tokens.spacing.gap * 0.75;
    // 封面和标题 footer 分区稳定：封面内只叠加标签、类型徽章、进度条；
    // 书名移到封面下方，避免遮住封面图，也避免长标题撑坏网格。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _bookCardCoverFrame(
            Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(child: cover),
                if (metadata != null)
                  PositionedDirectional(
                    start: 0,
                    end: 0,
                    bottom: 0,
                    child: metadata,
                  ),
                if (coverBadge != null)
                  PositionedDirectional(
                    end: overlayInset,
                    top: overlayInset,
                    // 封面右上角类型徽章（TODO-284 / TODO-355 / TODO-361 / TODO-552）。
                    // 徽章内在尺寸是 22px（HibikiBadge: icon 14 + padding gap）。方框等于
                    // 徽章内在尺寸 kShelfCoverBadgeDimension=22，配合 `BoxFit.contain` 既不
                    // 放大也不缩小，徽章按 22px 满尺寸渲染——TODO-361 曾把方框收到 16px 把徽章
                    // 缩得太小看不清，TODO-552 恢复正常大小。
                    child: SizedBox.square(
                      dimension: kShelfCoverBadgeDimension,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: coverBadge,
                      ),
                    ),
                  ),
                if (tagLabels != null)
                  PositionedDirectional(
                    start: overlayInset,
                    top: overlayInset,
                    child: _bookCardTagArea(tagLabels),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: kShelfTitleFooterHeight,
          child: _bookCardFooter(title),
        ),
      ],
    );
  }

  Widget _bookCardCoverFrame(Widget child) {
    return HibikiCard(
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      child: child,
    );
  }

  Widget _bookCardFooter(String title) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.gap * 0.75,
        tokens.spacing.gap / 2,
        tokens.spacing.gap * 0.75,
        0,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: Text(
          title,
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
          textAlign: TextAlign.center,
          softWrap: true,
          style: tokens.type.metadata.copyWith(
            color: tokens.surfaces.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _bookCardTagArea(Widget tagLabels) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: tokens.spacing.gap * 9,
        maxHeight: tokens.spacing.gap * 3.5,
      ),
      child: ClipRect(child: tagLabels),
    );
  }

  Widget _cardBadge({
    required IconData icon,
    required Color background,
    required Color foreground,
  }) {
    return HibikiBadge(
      icon: icon,
      background: background,
      foreground: foreground,
    );
  }

  Widget _progressBar(MediaItem item) {
    double value = 0;
    if (item.duration > 0) {
      final double v = item.position / item.duration;
      if (v.isFinite) {
        value = v > 0.97 ? 1 : v;
      }
    }
    return LinearProgressIndicator(
      value: value,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      color: theme.colorScheme.primary,
      minHeight: 3,
    );
  }

  Widget _audiobookBadge(HealthKind kind) {
    final ColorScheme cs = theme.colorScheme;
    final Color bg;
    final Color fg;
    switch (kind) {
      case HealthKind.failed:
        bg = cs.errorContainer;
        fg = cs.onErrorContainer;
      case HealthKind.partial:
        bg = cs.tertiaryContainer;
        fg = cs.onTertiaryContainer;
      case HealthKind.ok:
      case HealthKind.unrun:
      case HealthKind.running:
      case HealthKind.notApplicable:
        bg = cs.secondaryContainer;
        fg = cs.onSecondaryContainer;
    }
    return _cardBadge(
      icon: Icons.headphones_outlined,
      background: bg,
      foreground: fg,
    );
  }
}
