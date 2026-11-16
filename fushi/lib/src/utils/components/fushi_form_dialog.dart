/// 多字段表单对话框：设计系统层，MD3 / Apple（玻璃）两套都由 [FushiAlertDialog] 与
/// [FushiTextFieldControl] 按当前设计切换，进出场动效走 [showAppDialog]。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 表单对话框的一个输入框。
@immutable
class FushiFormField {
  const FushiFormField({
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

/// 多字段输入对话框（书签编辑：标题 + 地址；搜索引擎：名称 + 模板 + 联想模板；
/// 歌词手动搜索：标题 + 艺人）。单字段用 [showFushiTextInputDialog]。
/// 返回 null = 取消；否则按 [fields] 顺序返回 trim 后的值。[message] 是输入框上方的说明。
Future<List<String>?> showFushiFormDialog({
  required BuildContext context,
  required String title,
  required List<FushiFormField> fields,
  String? message,
  IconData? icon,
  String? confirmLabel,
}) => showAppDialog<List<String>>(
  context: context,
  builder: (_) => _FushiFormDialog(
    title: title,
    message: message,
    fields: fields,
    icon: icon,
    confirmLabel: confirmLabel,
  ),
);

class _FushiFormDialog extends StatefulWidget {
  const _FushiFormDialog({
    required this.title,
    required this.message,
    required this.fields,
    required this.icon,
    required this.confirmLabel,
  });

  final String title;
  final String? message;
  final List<FushiFormField> fields;
  final IconData? icon;
  final String? confirmLabel;

  @override
  State<_FushiFormDialog> createState() => _FushiFormDialogState();
}

class _FushiFormDialogState extends State<_FushiFormDialog> {
  late final List<TextEditingController> _controllers = <TextEditingController>[
    for (final FushiFormField f in widget.fields)
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
    final FushiFormField field = widget.fields[i];
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
          if (widget.message != null) ...<Widget>[
            Text(widget.message!),
            const SizedBox(height: 16),
          ],
          for (int i = 0; i < widget.fields.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
              child: FushiTextFieldControl(
                key: ValueKey<String>('fushi_form_field_$i'),
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
          key: const ValueKey<String>('fushi_form_confirm'),
          label: widget.confirmLabel ?? t.dialog_save,
          kind: FushiDialogActionKind.primary,
          onPressed: _canSubmit ? _submit : null,
        ),
      ],
    );
  }
}
