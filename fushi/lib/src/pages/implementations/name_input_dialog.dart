import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// 通用「输入一个名字」对话框——库内**全部**改名/命名入口的唯一弹窗实现。
///
/// 在此之前，每个域各自复制了一份形状相同的命名弹窗：合集走
/// `showCollectionNameDialog`、游戏走私有 `_RenameGameDialog`、视频走一个**裸**
/// `AlertDialog`（连设计系统都没走）、Profile 走 `ProfileNameDialog`。四份实现
/// 四种壳、四套 trim/空名规则，其中视频那份还踩过「`showDialog` 返回后立刻
/// dispose controller」的过早释放坑。再往里加词典/扫描根就是第五、第六份。
///
/// 所以这里收成一个原语：**壳、令牌间距、trim、空名短路、controller 生命周期
/// 只有一处**，各域只传自己的差异（标题、输入框标签、图标、可选头部预览）。
/// 域专属的语义包装（如合集的封面网格预览）留在各自的薄 wrapper 里，本文件
/// 因此零域依赖。
///
/// 返回值语义：`null` = 用户取消；非空 = 已 trim 的新名字。**空名不会返回**
/// （输入框留空时确认键直接不响应），调用方无需再判空。
Future<String?> showNameInputDialog({
  required BuildContext context,
  required String title,
  required String labelText,
  String initialName = '',
  IconData? leadingIcon,
  Widget? header,
}) {
  return showAppDialog<String>(
    context: context,
    builder: (_) => _NameInputDialog(
      title: title,
      labelText: labelText,
      initialName: initialName,
      leadingIcon: leadingIcon,
      header: header,
    ),
  );
}

class _NameInputDialog extends StatefulWidget {
  const _NameInputDialog({
    required this.title,
    required this.labelText,
    required this.initialName,
    this.leadingIcon,
    this.header,
  });

  final String title;
  final String labelText;
  final String initialName;
  final IconData? leadingIcon;

  /// 输入框上方的可选预览块（合集命名用它铺成员封面）。空则不占位。
  final Widget? header;

  @override
  State<_NameInputDialog> createState() => _NameInputDialogState();
}

class _NameInputDialogState extends State<_NameInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    // controller 由 State 持有并在此释放。调用方**不要**在 await 弹窗返回后
    // 自己 dispose：那时 widget 树还没拆完，属于过早释放。
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: widget.title,
        leadingIcon: widget.leadingIcon,
        // TODO-1389 起沿用：外层给的是有界高度，body 又是非滚动 Column，最小窗高
        // 480（客户区 ≈440）下带 header 时会顶破界底。scrollable 提供滚动兜底。
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.header != null) ...<Widget>[
              widget.header!,
              SizedBox(height: tokens.spacing.gap),
            ],
            FushiTextField(
              controller: _controller,
              labelText: widget.labelText,
              autofocus: true,
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: _submit,
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ),
    );
  }
}
