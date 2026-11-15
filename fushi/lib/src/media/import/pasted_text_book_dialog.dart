import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/import_flow_mixin.dart';
import 'package:fushi/src/media/import/pasted_text_book.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 读剪贴板文本的函数签名（测试注入替身，生产用 [readSystemClipboardText]）。
typedef PastedTextClipboardReader = Future<String?> Function();

/// 生产实现：系统剪贴板里的纯文本（没有文本返回 null）。
Future<String?> readSystemClipboardText() async {
  final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
  return data?.text;
}

/// 「粘贴文本阅读」对话框（反馈 f2k9m1oU0j）。
///
/// 打开时自动把剪贴板里的文本填进正文框（正文框为空时才填，不覆盖用户已输入的），
/// 用户可再改正文 / 标题；确认后经 [importPastedTextBook] 落成书库里的一本书，
/// 以新书的 bookKey pop——调用方负责刷新书架并直接打开阅读器（点词查词即阅读器
/// 原生能力）。取消 / 返回 pop null。
class PastedTextBookDialog extends StatefulWidget {
  const PastedTextBookDialog({
    required this.db,
    this.readClipboard = readSystemClipboardText,
    super.key,
  });

  final FushiDatabase db;

  /// 读剪贴板（打开时预填 + 「从剪贴板粘贴」按钮共用）。
  final PastedTextClipboardReader readClipboard;

  @override
  State<PastedTextBookDialog> createState() => _PastedTextBookDialogState();
}

class _PastedTextBookDialogState extends State<PastedTextBookDialog>
    with ImportFlowMixin<PastedTextBookDialog> {
  final TextEditingController _bodyController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _prefillFromClipboard();
  }

  @override
  void dispose() {
    _bodyController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  bool get _canRead => !importing && pastedTextHasContent(_bodyController.text);

  /// 标题框留空时用的书名：由正文第一行推导，正文也空时用本地化兜底名。
  String get _effectiveTitle {
    final String typed = _titleController.text.trim();
    if (typed.isNotEmpty) return typed;
    return pastedTextBookTitle(_bodyController.text) ??
        t.book_paste_text_default_title;
  }

  /// 打开时预填：只在正文框还空着时写入，避免覆盖用户在剪贴板读回之前已输入的内容。
  Future<void> _prefillFromClipboard() async {
    final String? text = await widget.readClipboard();
    if (!mounted || text == null || !pastedTextHasContent(text)) return;
    if (_bodyController.text.isNotEmpty) return;
    setState(() => _bodyController.text = text);
  }

  /// 「从剪贴板粘贴」按钮：显式动作，覆盖正文框。
  Future<void> _pasteFromClipboard() async {
    final String? text = await widget.readClipboard();
    if (!mounted) return;
    if (text == null || !pastedTextHasContent(text)) {
      FushiToast.show(
        msg: t.book_paste_text_clipboard_empty,
        severity: ToastSeverity.warning,
      );
      return;
    }
    setState(() => _bodyController.text = text);
  }

  Future<void> _doRead() async {
    if (!_canRead) return;
    final String text = _bodyController.text;
    final String title = _effectiveTitle;
    await runImport(
      logTag: 'PastedTextBookDialog.import',
      action: () async {
        final String bookKey = await importPastedTextBook(
          db: widget.db,
          text: text,
          title: title,
        );
        if (!mounted) return;
        Navigator.pop(context, bookKey);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 导入进行中禁止返回键 / 点遮罩 / Esc 关闭（HBK-AUDIT-037，见 buildImportPopGuard）。
    return buildImportPopGuard(
      child: ImportDialogFrame(
        leadingIcon: FushiIcons.paste,
        title: t.book_paste_text_dialog_title,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiTextFieldControl(
              controller: _titleController,
              enabled: !importing,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: t.book_paste_text_title_label,
                // 留空时实际使用的书名直接作提示，所见即所得。
                hintText: _effectiveTitle,
                prefixIcon: const FushiIcon(FushiIcons.title),
              ),
            ),
            SizedBox(height: tokens.spacing.gap * 1.5),
            // 外框 body 已包 SingleChildScrollView；正文框自身 6–12 行后内部滚动。
            FushiTextFieldControl(
              controller: _bodyController,
              enabled: !importing,
              keyboardType: TextInputType.multiline,
              minLines: 6,
              maxLines: 12,
              decoration: InputDecoration(
                labelText: t.book_paste_text_body_label,
                hintText: t.book_paste_text_body_hint,
                alignLabelWithHint: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: tokens.spacing.gap * 1.5),
            FushiOutlinedButton.icon(
              onPressed: importing ? null : _pasteFromClipboard,
              icon: const FushiIcon(FushiIcons.paste),
              label: Text(t.book_paste_text_from_clipboard),
            ),
            SizedBox(height: tokens.spacing.gap * 1.5),
            FushiInlineNotice(
              message: t.book_paste_text_hint,
              icon: FushiIcons.info,
            ),
          ],
        ),
        actions: <Widget>[
          buildCancelAction(context),
          buildImportAction(
            context,
            label: t.book_paste_text_read,
            enabled: pastedTextHasContent(_bodyController.text),
            onImport: () {
              if (_canRead) _doRead();
            },
          ),
        ],
      ),
    );
  }
}
