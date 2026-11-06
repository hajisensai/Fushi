// GENERATED-NOTE: extracted from reader_fushi_history_page.dart (TODO-587).
part of '../reader_fushi_history_page.dart';

/// 书架封面图按高度等比缩放、保持封面原始比例（永不变形）。
///
/// TODO-480 曾把这里从 [BoxFit.fitHeight] 改成 [BoxFit.cover] 以「占满卡片、消除
/// 留白」，但封面区域宽高比在 TODO-455 把书名移到下方 40px footer 后已经不再等于
/// 封面图比例（封面区被压扁成更宽矮的形状），`cover` 会放大裁切，封面构图被截掉
/// 上/下，肉眼读作「封面被压缩变形」。书架封面诉求是按比例正常显示（TODO-552），
/// 故改回 `fitHeight`：按封面区高度等比缩放、保持比例，两侧溢出由外层 `ClipRect`
/// 裁掉，封面竖向全貌完整不变形。
BoxFit get _bookCardCoverFit => BoxFit.fitHeight;

/// Book / audiobook / SRT / remote shelf card slot aspect ratio (width / height).
///
/// TODO-786 是 TODO-552 「封面不裁切」决策的延续，同向而非回退：TODO-552 改回
/// [BoxFit.fitHeight] 解决「封面被压缩变形」（不变形），但旧卡槽比例 [16/9-ish] 的
/// 176/250≈0.704 比真实书封（≈2:3）宽，`fitHeight` 等比铺满高度后两侧露出明显白带
/// （TODO-786 用户报「封面两侧露白」）。这里把书类卡槽收窄到接近书封比例的
/// 160/260≈0.6154，使 `fitHeight` 自然铺满卡槽、两侧残白收敛到几像素（不改 cover，
/// 绝不触碰 TODO-552 的不裁切决策与其守卫的 cover 禁令）。
///
/// 2026-10-25 库页定版：封面下的文字块换成 [ShelfCardMeta]（标题两行 + 副行一行
/// + 进度条，约 74px，随文字缩放），封面区要保持约 1:1.42 的竖长书封比例。按
/// 三档网格宽度（150 / 180 / 210，卡内四边各让 12px）推算：封面高 = 1.42 × 内宽，
/// 卡槽高 = 封面高 + 文字块 + 24，卡槽比例落在 0.55–0.58，取中间档 180 / 320。
/// 文字块是固定像素，跨档仍有一两像素残差，由 fitHeight 两侧的衬底吸收。
const double kShelfBookCardAspectRatio = 180 / 320;

/// card domain methods extracted via part-of (TODO-587); shared private scope.
extension _ReaderHistoryCardWidgets on _ReaderFushiHistoryPageState {
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
      imageErrorBuilder: (_, __, ___) => _coverPlaceholderIcon(placeholderIcon),
      placeholder: MemoryImage(kTransparentImage),
      // BUG-959: 降采样解码，避免 EPUB 原始封面(常 1600×2400)整帧撑爆 ImageCache。
      image: resizedFileImage(File(coverPath)),
      alignment: Alignment.topCenter,
      fit: _bookCardCoverFit,
    );
  }

  Widget _coverPlaceholderIcon(IconData icon) {
    // 巡检 B11：深色主题下无封面占位与背景零对比。改走共享占位
    // [ShelfCoverPlaceholder]（与视频库 / 游戏库同一件）：MD3 = 比卡面高一阶的
    // surfaceContainerHigh 柔和填充、Apple = tertiaryFill 系统灰填充，都不再画
    // 1px 描边方框；墨水屏由组件自己保留描边不填充。
    return ShelfCoverPlaceholder(icon: icon);
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
    final SelectionSlot? slot = selectionKey == null
        ? null
        : SelectionSlot.loose(selectionKey);
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

    Widget interactiveCard = ContextMenuTrigger(
      // 桌面端鼠标右键打开与长按相同的书籍上下文菜单（PC 用户惯例），多选态压制不变。
      // 哪个鼠标键唤出由绑定表决定（默认右键），不再硬绑次按钮。
      onInvoke: contextMenuInvoker(_selectionMode ? null : onLongPress),
      child: Padding(
        key: cardKey,
        padding: EdgeInsets.all(tokens.spacing.rowVertical),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            canRequestFocus: false,
            // 封面即卡片：状态层 / 水波与封面同圆角（[shelfCoverRadius]）。
            borderRadius: shelfCoverRadius(context),
            // 封面卡不画状态层 / 水波（2026-10-25）：悬停 / 按下的灰底会在
            // 封面后面露出一块底板，反馈由 FushiHoverLift 与材质扫光负责。
            overlayColor: const WidgetStatePropertyAll<Color>(
              Colors.transparent,
            ),
            splashFactory: NoSplash.splashFactory,
            onTap: handleTap,
            // 未进入选择态时，触屏与桌面长按都保留上下文菜单；只有显式进入选择态后
            // 才摘掉卡片识别器，让祖先 SelectionDragArea 接管长按扫选。
            onLongPress: _selectionMode ? null : onLongPress,
            child: AspectRatio(
              aspectRatio: slotAspectRatio,
              // 勾选圈与选中罩画在**封面上**（卡内 [ShelfCoverFrame] 读这一层），
              // 不再连标题 footer 一起罩住整个卡槽。
              child: ShelfCoverSelection(
                selectionMode: _selectionMode && selectionKey != null,
                selected: selected,
                child: child,
              ),
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
    // 悬停抬升：与游戏库 / 视频库同一个壳（内含墨水屏与「减弱动态效果」两处
    // 降级）。多选态关掉——那时卡片是勾选目标，跟指针放大只会干扰框选。
    // AnimatedScale 只做绘制变换、不改变 layout 尺寸，
    // `book_drag_target_layout_test.dart` 的等尺寸断言仍成立。
    Widget result = FushiHoverLift(
      enabled: !_selectionMode,
      builder: (BuildContext _, bool __) => card,
    );
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

  /// 书卡布局（2026-10-25 库页定版）：上面是封面（材质由网格外的
  /// [ShelfCoverMaterialScope] 决定），下面是 [ShelfCardMeta] 文字块。
  ///
  /// 用户原话「全部都不用角标设计」：封面上**不压任何角标**——类型、对齐状态、
  /// 远端 ☁、下载状态、标签、进度条一律进封面下的副行（[meta] + [tags]）。封面上
  /// 只剩多选勾选圈 / 选中罩（共享 [ShelfCoverFrame] 画）和导入 / 下载中的居中
  /// 加载遮罩（[loadingOverlay]，BUG-990 / 远端下载进行中）。
  Widget _bookCardLayout({
    required String title,
    required Widget cover,
    required _ShelfMetaSpec meta,
    List<BookTagRow> tags = const <BookTagRow>[],
    Widget? loadingOverlay,
  }) {
    final Widget metaBlock = ShelfCardMeta(
      title: title,
      subtitle: meta.status,
      leadingIcon: meta.icon,
      tone: meta.tone,
      progress: meta.progress,
      completed: meta.completed,
      trailing: tags.isEmpty ? null : ShelfMetaTags(tags: _shelfMetaTags(tags)),
    );
    final String? tooltip = meta.tooltip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _bookCardCoverFrame(
            Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(child: cover),
                if (loadingOverlay != null)
                  Positioned.fill(child: Center(child: loadingOverlay)),
              ],
            ),
          ),
        ),
        SizedBox(
          // 随文字缩放变高（BUG-1184 同一诉求：大字号下文字不被裁）。
          height: ShelfCardMeta.heightFor(context),
          child: KeyedSubtree(
            key: meta.key,
            child: tooltip == null
                ? metaBlock
                : FushiTooltip(message: tooltip, child: metaBlock),
          ),
        ),
      ],
    );
  }

  /// 封面框是共享 [ShelfCoverFrame]：材质库页（网格外有 [ShelfCoverMaterialScope]）
  /// 画光面书皮 + 接触阴影 + 悬停扫光；墨水屏 / 无材质时退回描边或圆角封面框。
  Widget _bookCardCoverFrame(Widget child) {
    return ShelfCoverFrame(child: child);
  }

  /// 副行尾部的用户标签（[ShelfMetaTags]：标签色点 + 名字）。状态文字留在副行
  /// 正文，标签不再拼成 `#tag` 文本（用户 2026-10-26：「#4⭐」太抽象）。
  List<ShelfMetaTag> _shelfMetaTags(List<BookTagRow> tags) => <ShelfMetaTag>[
    for (final BookTagRow tag in tags)
      (label: tag.name, color: Color(tag.colorValue)),
  ];

  /// 条目的阅读比例（0–1）：标了读完恒为 1；超过 97% 视同读完（跳过后记 / 附录）。
  double _itemReadFraction(MediaItem item, {bool completed = false}) {
    if (completed) return 1;
    if (item.duration <= 0) return 0;
    final double v = item.position / item.duration;
    if (!v.isFinite) return 0;
    return v > 0.97 ? 1 : v.clamp(0.0, 1.0);
  }

  /// 阅读状态文案：已读完 / 未读 / 百分比（不足 1% 记 1%，避免「0%」与「未读」混淆）。
  String _readProgressLabel(double fraction, {bool completed = false}) {
    if (completed || fraction >= 1) return t.shelf_filter_read_status_finished;
    if (fraction <= 0) return t.shelf_filter_read_status_unread;
    return '${(fraction * 100).floor().clamp(1, 99)}%';
  }

  /// 本地书卡的副行：普通书 / 漫画只写阅读状态（不标类型）；有声书写「🎧 有声书 ·
  /// 46%」，对齐失败 / 部分对齐换错误 / 警示语气与原因。
  _ShelfMetaSpec _localBookMeta({
    required double fraction,
    required bool completed,
    bool audiobook = false,
    HealthKind health = HealthKind.notApplicable,
  }) {
    final String status = _readProgressLabel(fraction, completed: completed);
    final bool done = completed || fraction >= 1;
    if (!audiobook) {
      return _ShelfMetaSpec(
        status: status,
        progress: fraction,
        completed: done,
      );
    }
    switch (health) {
      case HealthKind.failed:
        return _ShelfMetaSpec(
          status: t.shelf_card_meta_alignment_failed,
          icon: FushiIcons.error,
          tone: ShelfMetaTone.error,
          progress: fraction,
          completed: done,
        );
      case HealthKind.partial:
        return _ShelfMetaSpec(
          status: '${t.shelf_card_meta_alignment_partial} · $status',
          icon: FushiIcons.warning,
          tone: ShelfMetaTone.warning,
          progress: fraction,
          completed: done,
        );
      case HealthKind.ok:
      case HealthKind.unrun:
      case HealthKind.running:
      case HealthKind.notApplicable:
        return _ShelfMetaSpec(
          status: '${t.section_audiobook} · $status',
          icon: FushiIcons.audiobook,
          progress: fraction,
          completed: done,
        );
    }
  }
}

/// 封面下副行的内容（[_ReaderHistoryCardWidgets._bookCardLayout] 的 `meta`）。
///
/// [status] 是副行的状态段（标签由布局接在后面）；[progress] 为 null 时不画进度条
/// （仍占位，同一网格行高一致）；[key] 挂在文字块上，供 widget 测试定位某一种状态
/// （如远端「未下载」/「下载失败」）；[tooltip] 非空时整块文字悬停给出完整说明。
class _ShelfMetaSpec {
  const _ShelfMetaSpec({
    this.status,
    this.icon,
    this.tone = ShelfMetaTone.normal,
    this.progress,
    this.completed = false,
    this.key,
    this.tooltip,
  });

  final String? status;
  final IconData? icon;
  final ShelfMetaTone tone;
  final double? progress;
  final bool completed;
  final Key? key;
  final String? tooltip;
}
