// GENERATED-NOTE: extracted from reader_fushi_history_page.dart (TODO-587).
part of '../reader_fushi_history_page.dart';

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
/// 包住内在 22px（FushiBadge：icon 14 + padding gap 8）的徽章，徽章按 22px 满尺寸渲染。
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

/// Book / audiobook / SRT / remote shelf card slot aspect ratio (width / height).
///
/// TODO-786 是 TODO-552 「封面不裁切」决策的延续，同向而非回退：TODO-552 改回
/// [BoxFit.fitHeight] 解决「封面被压缩变形」（不变形），但旧卡槽比例 [16/9-ish] 的
/// 176/250≈0.704 比真实书封（≈2:3）宽，`fitHeight` 等比铺满高度后两侧露出明显白带
/// （TODO-786 用户报「封面两侧露白」）。这里把书类卡槽收窄到接近书封比例的
/// 160/260≈0.6154，使 `fitHeight` 自然铺满卡槽、两侧残白收敛到几像素（不改 cover，
/// 绝不触碰 TODO-552 的不裁切决策与其守卫的 cover 禁令）。
///
/// 几何说明：卡槽内有绝对 40px 的标题 footer（[kShelfTitleFooterHeight]）压在封面区
/// 下方，footer 是固定像素而非按比例，故封面区实际比例会比卡槽比例略宽（中间档
/// 封面区 W/H ≈ 0.72），残白随档位非线性，约 5–8px/侧无法跨档归零——这是 footer
/// 绝对像素的必然结果，不是 bug。
const double kShelfBookCardAspectRatio = 160 / 260;

/// card domain methods extracted via part-of (TODO-587); shared private scope.
extension _ReaderHistoryCardWidgets on _ReaderFushiHistoryPageState {
  Widget _tagChip(BookTagRow tag) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: _cardTagChipPadding(tokens),
      child: FushiTagChip(
        label: tag.name,
        color: Color(tag.colorValue),
      ),
    );
  }

  Widget _overflowChip(int count) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: _cardTagChipPadding(tokens),
      child: FushiTagChip(
        label: '+$count',
      ),
    );
  }

  EdgeInsetsDirectional _cardTagChipPadding(FushiDesignTokens tokens) {
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

        // 溢出时最后一个槽恒让给「+N」合并 chip。仅 1 槽（书卡容器高恒 ≈1 槽）
        // 时唯一槽也显示「+N」（N=全部标签数）——旧实现只显示第 1 个标签且无
        // +N，多标签书在书架上读作「只有 1 个标签」（巡检 PR-3）。
        final int visibleCount = maxSlots <= 1 ? 0 : maxSlots - 1;
        final int overflow = tags.length - visibleCount;
        return _uniformWidthTagColumn([
          for (final tag in tags.take(visibleCount)) _tagChip(tag),
          _overflowChip(overflow),
        ]);
      },
    );
  }

  /// BUG-220(子2): 卡片左上角竖排标签原来用 `crossAxisAlignment.start`，每个 chip
  /// 宽度等于自身文字宽度，导致一行长一行短的参差。用 `IntrinsicWidth` 把整列宽度
  /// 收敛到最宽 chip，再用 `stretch` 让每个 chip 拉到该统一宽度（chip 内部文字仍左
  /// 对齐），竖排整齐。不改 [FushiTagChip]，不影响别处用法。
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
      // BUG-959: 降采样解码，避免 EPUB 原始封面(常 1600×2400)整帧撑爆 ImageCache。
      image: resizedFileImage(File(coverPath)),
      alignment: Alignment.topCenter,
      fit: _bookCardCoverFit,
    );
  }

  Widget _coverPlaceholderIcon(IconData icon) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 巡检 B11：深色主题下无封面占位（卡面色 ≈ 页面背景）与背景零对比，占位卡
    // 读作一块空洞。给占位区补 1px outlineVariant 描边（全主题恒有；eink 的卡级
    // 描边另由 FushiCard 兜，两者叠加无害）。
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: tokens.radii.cardRadius,
      ),
      child: Center(
        child: Icon(
          icon,
          size: 40,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _bookCardShell({
    required VoidCallback onTap,
    required VoidCallback onLongPress,
    required Widget child,
    // TODO-786：卡槽宽高比由调用点显式传入——书/有声书/SRT/远端统一用
    // [kShelfBookCardAspectRatio]（书架视频分区死路径已删，视频卡归「视频」tab）。
    // 参数化而非在壳里硬编码媒体类型分支。
    required double slotAspectRatio,
    Key? cardKey,
    FushiFocusId? focusId,
    String? selectionKey,
    Object? dragBookId,
    void Function(BookTagRow tag)? onTagDropped,
    MediaRef? dragMediaRef,
    String? dragLabel,
  }) {
    final bool selected =
        selectionKey != null && _selectedKeys.contains(selectionKey);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double selectionInset = tokens.spacing.gap / 2;
    final SelectionSlot? slot =
        selectionKey == null ? null : SelectionSlot.loose(selectionKey);
    void handleTap() {
      if (slot == null) {
        onTap();
        return;
      }
      if (_selectionMode) {
        _toggleSelection(slot.looseKey!);
        return;
      }
      // 桌面 Ctrl/⌘（macOS）/ Shift + 点击 = 不经工具栏直接进多选并选中该卡。
      if (selectionEntryModifierPressed(context)) {
        _enterSelectionWith(slot);
        return;
      }
      onTap();
    }

    Widget interactiveCard = Padding(
      key: cardKey,
      padding: EdgeInsets.all(tokens.spacing.rowVertical),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          canRequestFocus: false,
          borderRadius: tokens.radii.cardRadius,
          onTap: handleTap,
          // 未进入选择态时，触屏与桌面长按都保留上下文菜单；只有显式进入选择态后
          // 才摘掉卡片识别器，让祖先 SelectionDragArea 接管长按扫选。
          onLongPress: _selectionMode ? null : onLongPress,
          // 桌面端鼠标右键打开与长按相同的书籍上下文菜单（PC 用户惯例）。多选态
          // 压制不变。
          onSecondaryTap: _selectionMode ? null : onLongPress,
          child: AspectRatio(
            aspectRatio: slotAspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                child,
                if (_selectionMode && selectionKey != null)
                  Positioned(
                    top: selectionInset,
                    left: selectionInset,
                    child: ShelfSelectionCheck(selected: selected),
                  ),
                if (selected)
                  const Positioned.fill(child: ShelfSelectedOverlay()),
              ],
            ),
          ),
        ),
      ),
    );
    if (focusId != null && FushiFocusRoot.maybeControllerOf(context) != null) {
      interactiveCard = Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              handleTap();
              return null;
            },
          ),
        },
        child: FushiFocusTarget(id: focusId, child: interactiveCard),
      );
    }
    // Gamepad long-press (hold A) on the focused card invokes the same
    // onLongPress as the mouse (book details / actions). In selection mode the
    // long-press is disabled (tap toggles selection), so it's a pass-through.
    final Widget card = GamepadLongPressActions(
      onLongPress: _selectionMode ? null : onLongPress,
      child: interactiveCard,
    );
    Widget result = card;
    if (dragBookId != null && onTagDropped != null && !_selectionMode) {
      result = BookDragTarget(
        bookId: dragBookId,
        onTagDropped: onTagDropped,
        child: result,
      );
    }
    // 拖卡进合集：拖拽源包在标签 drop target **外面**——两者方向相反（这张卡既能
    // 被拖走、也能接住落下的标签），泛型不同互不干扰；Draggable 只加 Listener，
    // 不改变布局（`book_drag_target_layout_test.dart` 的等尺寸断言仍成立）。
    if (dragMediaRef != null && !_selectionMode) {
      result = MediaCardDraggable(
        mediaRef: dragMediaRef,
        label: dragLabel ?? '',
        child: result,
      );
    }
    // 长按扫选靠命中测试反查「手指下面是哪一格」，故身份标记包在最外层（
    // [MetaData] 默认 deferToChild，只有真命中卡片时才进命中路径）。不改布局。
    if (slot != null) {
      result = SelectionSlotTarget(slot: slot, child: result);
    }
    return result;
  }

  /// 块2：合集行头整选勾选框（选=选中整个合集）。与散卡 [_bookCardShell] 的封面
  /// 勾选框同为共享 [ShelfSelectionCheck]（内建 [IgnorePointer] 让点击穿透到行头
  /// InkWell 整选回调；eink 实心底由组件统一处理）。
  Widget _buildSelectionCheck(bool selected) =>
      ShelfSelectionCheck(selected: selected);

  Widget _bookCardLayout({
    required String title,
    required Widget cover,
    Widget? tagLabels,
    Widget? coverBadge,
    Widget? leadingBadge,
    Widget? metadata,
    Widget? loadingOverlay,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
                    // 徽章内在尺寸是 22px（FushiBadge: icon 14 + padding gap）。方框等于
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
                if (leadingBadge != null)
                  PositionedDirectional(
                    start: overlayInset,
                    top: overlayInset,
                    // 封面左上角类型徽章（TODO-655a）：远端书卡右上角被下载按钮 /
                    // 进度徽章占用，类型徽章（有声书耳机 / 普通书本）放左上角，与
                    // coverBadge 同尺寸渲染。本地书卡用 tagLabels 占左上角而不传
                    // leadingBadge，二者不会共存。
                    child: SizedBox.square(
                      dimension: kShelfCoverBadgeDimension,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: leadingBadge,
                      ),
                    ),
                  ),
                if (tagLabels != null)
                  PositionedDirectional(
                    start: overlayInset,
                    top: overlayInset,
                    child: _bookCardTagArea(tagLabels),
                  ),
                // 有声书两阶段下载空窗期的加载指示（BUG-990）：EPUB 已落库、有声书还在
                // 下，占位卡已被本地卡顶替，靠这个居中全幅覆盖层继续显示「还在下」——
                // 不抢占已被占用的 coverBadge/leadingBadge/tagLabels 槽，叠在最上层。
                if (loadingOverlay != null)
                  Positioned.fill(child: Center(child: loadingOverlay)),
              ],
            ),
          ),
        ),
        SizedBox(
          // BUG-1184：随文字缩放变高，否则大字号下书名第二行被裁（见 [heightFor]）。
          height: ShelfCardFooter.heightFor(context),
          child: ShelfCardFooter(title: title),
        ),
      ],
    );
  }

  Widget _bookCardCoverFrame(Widget child) {
    return FushiCard(
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      child: child,
    );
  }

  Widget _bookCardTagArea(Widget tagLabels) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
    String? tooltip,
  }) {
    final Widget badge = FushiBadge(
      icon: icon,
      background: background,
      foreground: foreground,
    );
    if (tooltip == null) return badge;
    return Tooltip(message: tooltip, child: badge);
  }

  /// [completed] = 该书已被显式标记「读完」（EpubBooks.completedAt 非 null）。命中时
  /// 进度条恒满格并用区分色（tertiary），让手动标记完成但进度停在 99%（跳过后记/附录）
  /// 的书在书架上也一眼可辨「已读完」，而非停在一条差一点的普通进度条。
  Widget _progressBar(MediaItem item, {bool completed = false}) {
    double value = 0;
    if (completed) {
      value = 1;
    } else if (item.duration > 0) {
      final double v = item.position / item.duration;
      if (v.isFinite) {
        value = v > 0.97 ? 1 : v;
      }
    }
    return LinearProgressIndicator(
      value: value,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      color: completed ? theme.colorScheme.tertiary : theme.colorScheme.primary,
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
