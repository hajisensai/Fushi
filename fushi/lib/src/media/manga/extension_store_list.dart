import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:flutter/services.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/utils/net/url_input_normalizer.dart';

/// 扩展仓库管理页（漫画 Mihon / 视频 Aniyomi / 小说 LNReader 三域共用）的
/// 视觉零件：限宽居中、顶部动作、信任提示、仓库行、添加 / 改地址对话框。
///
/// 三域的数据模型与动作各不相同（Mihon 有签名 / 明文确认，LNReader 有内置仓库），
/// 但仓库页长什么样只在这里写一次——此前两边各自把「刷新 / 添加」降级成一行
/// 药丸按钮、仓库行副标题把完整 URL 与状态硬换行塞成三行、行尾两枚孤零零的
/// 图标，宽屏上整页拉满一千多像素宽。

/// 仓库页正文的最大宽度：设置类单列内容的阅读宽度（与设置详情页同口径）。
const double kExtensionStorePageMaxWidth = 760;

/// 行宽低于此值时行尾动作收进溢出菜单（MD3）：图标 24 + 间距 16 + 标题最少
/// ~200 + 三个 48 的图标按钮 + 内边距。
const double _kInlineActionsMinWidth = 480;

/// 把仓库页的一组 sliver 限宽居中：宽屏两侧留白、窄屏贴页边距（外层已给）。
class ExtensionStorePageSliver extends StatelessWidget {
  const ExtensionStorePageSliver({required this.slivers, super.key});

  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (BuildContext context, SliverConstraints constraints) {
        final double inset = math.max(
          0,
          (constraints.crossAxisExtent - kExtensionStorePageMaxWidth) / 2,
        );
        return SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: SliverMainAxisGroup(slivers: slivers),
        );
      },
    );
  }
}

/// 仓库页顶部动作：次要「刷新」+ 主操作「添加仓库」，靠右排（页头动作位）。
///
/// MD3：文字按钮 + tonal 按钮（M3 Expressive 按压变形）；Apple：两枚液态玻璃
/// 胶囊（主操作 prominent）。两者都是共享按钮组件按设计系统分派，这里不分支。
class ExtensionStoreToolbar extends StatelessWidget {
  const ExtensionStoreToolbar({
    required this.refreshLabel,
    required this.addLabel,
    required this.onRefresh,
    required this.onAdd,
    super.key,
  });

  final String refreshLabel;
  final String addLabel;

  /// null = 不可用（刷新中）。
  final VoidCallback? onRefresh;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        FushiTextButton.icon(
          onPressed: onRefresh,
          icon: const FushiIcon(FushiIcons.refresh),
          label: Text(refreshLabel),
        ),
        FushiFilledButton.tonalIcon(
          onPressed: onAdd,
          icon: const FushiIcon(FushiIcons.add),
          label: Text(addLabel),
        ),
      ],
    );
  }
}

/// 仓库行的一个动作：宽行画成行尾图标按钮，窄行 / Apple 进溢出菜单，同一份定义。
class ExtensionStoreRowAction {
  const ExtensionStoreRowAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
    this.key,
  });

  final Key? key;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// 删除这类不可撤销的动作：菜单里用破坏色。
  final bool destructive;
}

/// 「复制地址」动作：三域同一实现。
ExtensionStoreRowAction extensionStoreCopyAction(String url, {Key? key}) =>
    ExtensionStoreRowAction(
      key: key,
      label: t.copy,
      icon: FushiIcons.copy,
      onTap: () {
        Clipboard.setData(ClipboardData(text: url));
        FushiToast.show(msg: t.copied_to_clipboard);
      },
    );

/// 仓库状态行的语气：null = 中性说明（扩展数），其余上状态色。
typedef ExtensionStoreStatus = ({String text, FushiStatusTone? tone});

/// 仓库列表的一行（共享分组列表的一格）。
///
/// 前置图标（普通仓库 / 内置仓库的锁）+ 名称 + 副标题两行：地址单行省略、
/// 状态（扩展数 / 零扩展提示 / 刷新错误）；行尾是「内置」标记与动作。
///
/// - MD3：分段分组行；行宽够时动作是行尾图标按钮（带 tooltip），窄行收进
///   ⋮ 溢出菜单。
/// - Apple：inset grouped 实色行，动作一律进 ⋯ 菜单（iOS 设置行不摆一串图标）；
///   行间分隔线从文字起点开始。
class ExtensionStoreTile extends StatelessWidget {
  const ExtensionStoreTile({
    required this.index,
    required this.count,
    required this.name,
    required this.url,
    required this.actions,
    super.key,
    this.rowKey,
    this.menuKey,
    this.builtin = false,
    this.builtinLabel,
    this.status,
  });

  /// 本行在仓库列表里的位置与总行数（决定分组圆角 / 分隔线）。
  final int index;
  final int count;
  final String name;
  final String url;
  final List<ExtensionStoreRowAction> actions;

  /// 挂在行内容（[FushiListItem]）上的身份键。
  final Key? rowKey;

  /// 溢出菜单按钮的键。
  final Key? menuKey;
  final bool builtin;

  /// 内置仓库的行尾标记文案（[builtin] 时显示）。
  final String? builtinLabel;
  final ExtensionStoreStatus? status;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ExtensionStoreStatus? status = this.status;
    final FushiStatusTone? tone = status?.tone;
    return FushiGroupedListItem(
      index: index,
      count: count,
      margin: EdgeInsets.only(
        bottom: index >= count - 1 ? tokens.spacing.gap : 0,
      ),
      // Apple 分隔线从名称起点开始（跳过行首图标列）。
      separatorIndent:
          metrics.rowHorizontal + metrics.leadingIconSize + metrics.leadingGap,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool menu =
              glass || constraints.maxWidth < _kInlineActionsMinWidth;
          return FushiListItem(
            key: rowKey,
            // M3E 行首形状底（12 圆角方块，secondaryContainer）；Apple 是 iOS
            // 设置式彩色圆角方块。内置仓库用锁，普通仓库用枢纽。
            leading: FushiListLeadingIcon(
              builtin ? FushiIcons.lock : FushiIcons.hub,
              shape: FushiLeadingShape.square,
            ),
            title: Text(name),
            subtitleMaxLines: 3,
            subtitle: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (status != null)
                  Text(
                    status.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tone == null
                        ? null
                        : TextStyle(color: fushiStatusColor(context, tone)),
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (builtin && builtinLabel != null)
                  FushiTag(
                    text: builtinLabel!,
                    tone: FushiTagTone.neutral,
                    dense: true,
                  ),
                if (actions.isNotEmpty)
                  if (menu)
                    _ExtensionStoreRowMenu(menuKey: menuKey, actions: actions)
                  else
                    for (final ExtensionStoreRowAction action in actions)
                      FushiIconButtonControl(
                        key: action.key,
                        tooltip: action.label,
                        onPressed: action.onTap,
                        icon: FushiIcon(action.icon),
                      ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ExtensionStoreRowMenu extends StatelessWidget {
  const _ExtensionStoreRowMenu({required this.menuKey, required this.actions});

  final Key? menuKey;
  final List<ExtensionStoreRowAction> actions;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final Color destructive = glass
        ? appleColorsOf(context).destructive
        : Theme.of(context).colorScheme.error;
    return FushiPopupMenuButton<ExtensionStoreRowAction>(
      key: menuKey,
      tooltip: t.common_more_actions,
      icon: FushiIcon(glass ? FushiIcons.moreHoriz : FushiIcons.more),
      onSelected: (ExtensionStoreRowAction action) => action.onTap(),
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<ExtensionStoreRowAction>>[
            for (final ExtensionStoreRowAction action in actions)
              PopupMenuItem<ExtensionStoreRowAction>(
                key: action.key,
                value: action,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FushiIcon(
                      action.icon,
                      size: 20,
                      color: action.destructive ? destructive : null,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        action.label,
                        style: action.destructive
                            ? TextStyle(color: destructive)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
          ],
    );
  }
}

/// 输入仓库地址的标准对话框（添加 / 改地址共用）：单行 URL 输入 + 主次按钮，
/// 提交时就地校验（http(s) + 主机名），不合法用输入框的 errorText 说明，
/// 不关框、不丢输入。返回归一化后的地址（全角符号已折半角，见
/// [normalizeUrlInput]）；取消返回 null。
///
/// [warning] 非空时在输入框上方放一条警告提示（[FushiInlineNotice]）。
Future<String?> showExtensionStoreUrlDialog({
  required BuildContext context,
  required String title,
  required String confirmLabel,
  String initial = '',
  String? warning,
  Key? fieldKey,
}) {
  return showAppDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => _ExtensionStoreUrlDialog(
      title: title,
      confirmLabel: confirmLabel,
      initial: initial,
      warning: warning,
      fieldKey: fieldKey,
    ),
  );
}

/// 地址是否是仓库可用的形态：http / https 且带主机名（三域 manager 的同一判据）。
bool isPlausibleExtensionStoreUrl(String normalized) {
  final Uri? uri = Uri.tryParse(normalized);
  if (uri == null || uri.host.isEmpty) return false;
  return uri.scheme == 'https' || uri.scheme == 'http';
}

class _ExtensionStoreUrlDialog extends StatefulWidget {
  const _ExtensionStoreUrlDialog({
    required this.title,
    required this.confirmLabel,
    required this.initial,
    required this.warning,
    required this.fieldKey,
  });

  final String title;
  final String confirmLabel;
  final String initial;
  final String? warning;
  final Key? fieldKey;

  @override
  State<_ExtensionStoreUrlDialog> createState() =>
      _ExtensionStoreUrlDialogState();
}

class _ExtensionStoreUrlDialogState extends State<_ExtensionStoreUrlDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    // 在出口处归一化一次，后面的 scheme 判定与 addStore 就都拿到半角地址；
    // 否则全角输入会让 `scheme == 'http'` 判空而漏掉明文确认。
    final String url = normalizeUrlInput(_controller.text);
    if (!isPlausibleExtensionStoreUrl(url)) {
      setState(() => _error = t.sync_pair_invalid_url);
      return;
    }
    Navigator.pop(context, url);
  }

  @override
  Widget build(BuildContext context) {
    final String? warning = widget.warning;
    return FushiAlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (warning != null) ...<Widget>[
              FushiInlineNotice(
                severity: FushiNoticeSeverity.warning,
                icon: FushiIcons.shield,
                message: warning,
              ),
              const SizedBox(height: 16),
            ],
            FushiTextFieldControl(
              key: widget.fieldKey,
              controller: _controller,
              autofocus: true,
              // 不声明就是普通文本键盘，中文/日文输入法会把 `:` `/` `.` 转成
              // 全角，用户根本输不进任何合法地址（BUG-1804）。归一化在
              // normalizeUrlInput 里兜底，这里让键盘一开始就给半角。
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: t.mihon_store_url,
                hintText: 'https://example.org/repo.json',
                prefixIcon: const FushiIcon(FushiIcons.link),
                errorText: _error,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        adaptiveDialogAction(
          context: context,
          isDefaultAction: true,
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
