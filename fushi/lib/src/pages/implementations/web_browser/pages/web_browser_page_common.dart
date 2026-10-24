import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/utils.dart';

/// 数据页（历史 / 书签 / 下载）打开网址的回调：[newTab] 为 true 时在新标签页打开。
/// 页面调用后会自行 pop 回浏览器（[newTab] 为 false 时）。
typedef WebBrowserPageOpenCallback = void Function(Uri url, {bool newTab});

/// 「清除历史 / 清除浏览数据」的时间范围。
enum WebBrowserClearRange {
  lastHour(Duration(hours: 1)),
  lastDay(Duration(hours: 24)),
  lastWeek(Duration(days: 7)),
  lastMonth(Duration(days: 28)),
  allTime(null);

  const WebBrowserClearRange(this.span);

  /// null = 全部时间。
  final Duration? span;

  /// 交给 store 的 `since`：null = 全部。
  DateTime? sinceFrom(DateTime now) {
    final Duration? s = span;
    return s == null ? null : now.subtract(s);
  }

  String get label => switch (this) {
    WebBrowserClearRange.lastHour => t.web_browser_range_last_hour,
    WebBrowserClearRange.lastDay => t.web_browser_range_last_day,
    WebBrowserClearRange.lastWeek => t.web_browser_range_last_week,
    WebBrowserClearRange.lastMonth => t.web_browser_range_last_month,
    WebBrowserClearRange.allTime => t.web_browser_range_all,
  };
}

/// 显示一条普通提示。
void showWebBrowserPageSnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(FushiSnackBar(content: Text(message)));
}

/// 网址的显示文案：去掉协议与末尾斜杠。
String webBrowserDisplayUrl(Uri url) {
  String text = url.toString();
  text = text.replaceFirst(RegExp(r'^https?://'), '');
  if (text.endsWith('/')) text = text.substring(0, text.length - 1);
  return text;
}

/// 表单对话框的一个输入框。
@immutable
class WebBrowserFormField {
  const WebBrowserFormField({
    required this.label,
    this.initialValue = '',
    this.hintText,
    this.optional = false,
    this.keyboardType = TextInputType.text,
    this.validator,
  });

  final String label;
  final String initialValue;
  final String? hintText;

  /// 可留空。
  final bool optional;
  final TextInputType keyboardType;

  /// 返回非空 = 错误文案（空值且 [optional] 时不调用）。
  final String? Function(String value)? validator;
}

/// 多字段输入对话框（书签编辑：标题 + 地址；搜索引擎：名称 + 模板 + 联想模板）。
/// 返回 null = 取消；否则按 [fields] 顺序返回 trim 后的值。
Future<List<String>?> showWebBrowserFormDialog({
  required BuildContext context,
  required String title,
  required List<WebBrowserFormField> fields,
  IconData? icon,
  String? confirmLabel,
}) => showAppDialog<List<String>>(
  context: context,
  builder: (_) => _WebBrowserFormDialog(
    title: title,
    fields: fields,
    icon: icon,
    confirmLabel: confirmLabel,
  ),
);

class _WebBrowserFormDialog extends StatefulWidget {
  const _WebBrowserFormDialog({
    required this.title,
    required this.fields,
    required this.icon,
    required this.confirmLabel,
  });

  final String title;
  final List<WebBrowserFormField> fields;
  final IconData? icon;
  final String? confirmLabel;

  @override
  State<_WebBrowserFormDialog> createState() => _WebBrowserFormDialogState();
}

class _WebBrowserFormDialogState extends State<_WebBrowserFormDialog> {
  late final List<TextEditingController> _controllers = <TextEditingController>[
    for (final WebBrowserFormField f in widget.fields)
      TextEditingController(text: f.initialValue)..addListener(_onChanged),
  ];

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    for (final TextEditingController c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  String _value(int i) => _controllers[i].text.trim();

  String? _error(int i) {
    final WebBrowserFormField field = widget.fields[i];
    final String value = _value(i);
    if (value.isEmpty) return null;
    return field.validator?.call(value);
  }

  bool get _canSubmit {
    for (int i = 0; i < widget.fields.length; i++) {
      if (_value(i).isEmpty && !widget.fields[i].optional) return false;
      if (_error(i) != null) return false;
    }
    return true;
  }

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(
      context,
    ).pop(<String>[for (int i = 0; i < widget.fields.length; i++) _value(i)]);
  }

  @override
  Widget build(BuildContext context) {
    return FushiAlertDialog(
      icon: widget.icon == null ? null : FushiDialogHeroIcon(icon: widget.icon),
      title: Text(widget.title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < widget.fields.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
              child: FushiTextFieldControl(
                key: ValueKey<String>('web_browser_form_field_$i'),
                controller: _controllers[i],
                autofocus: i == 0,
                keyboardType: widget.fields[i].keyboardType,
                textInputAction: i == widget.fields.length - 1
                    ? TextInputAction.done
                    : TextInputAction.next,
                onSubmitted: i == widget.fields.length - 1
                    ? (_) => _submit()
                    : null,
                decoration: InputDecoration(
                  labelText: widget.fields[i].label,
                  hintText: widget.fields[i].hintText,
                  errorText: _error(i),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('web_browser_form_confirm'),
          label: widget.confirmLabel ?? t.dialog_save,
          kind: FushiDialogActionKind.primary,
          onPressed: _canSubmit ? _submit : null,
        ),
      ],
    );
  }
}

/// 列表页的标准外框：正文消费页头让位（`MediaQuery.paddingOf(context).top`）与
/// 底部安全区，错峰进场窗口随 [replayKey] 重开。内部用 [Builder] 取
/// [FushiPageScaffold] 注入给正文的 MediaQuery（调用方传进来的 context 可能在
/// 脚手架之外，拿不到页头让位）。
Widget webBrowserPageListView({
  required Object? replayKey,
  required List<Widget> children,
  Key? key,
}) => FushiEntranceScope(
  replayKey: replayKey,
  child: Builder(
    builder: (BuildContext context) => ListView(
      key: key,
      padding: EdgeInsets.only(
        top: 8 + MediaQuery.paddingOf(context).top,
        bottom: 24 + bottomSafeInsetOf(context),
      ),
      children: children,
    ),
  ),
);
