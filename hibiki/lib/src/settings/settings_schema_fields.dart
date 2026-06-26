import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';

class SettingsSecretField extends StatefulWidget {
  const SettingsSecretField({
    super.key,
    required this.title,
    required this.icon,
    required this.initialValue,
    required this.onChanged,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.hintText,
  });

  final String title;
  final IconData icon;
  final String initialValue;
  final bool obscureText;
  final TextInputType keyboardType;

  /// 可选占位提示（传给内部 TextField 的 decoration.hintText）。null = 不显示提示。
  final String? hintText;
  final Future<void> Function(String value) onChanged;

  @override
  State<SettingsSecretField> createState() => SettingsSecretFieldState();
}

class SettingsSecretFieldState extends State<SettingsSecretField> {
  late final TextEditingController _controller;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(widget.onChanged(value));
    });
  }

  void _submit(String value) {
    _debounce?.cancel();
    unawaited(widget.onChanged(value));
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: widget.title,
      icon: widget.icon,
      controlBelow: true,
      trailing: AdaptiveSettingsTextField(
        controller: _controller,
        obscureText: widget.obscureText,
        keyboardType: widget.keyboardType,
        textInputAction: TextInputAction.done,
        labelText: widget.title,
        hintText: widget.hintText,
        onChanged: _scheduleChanged,
        onSubmitted: _submit,
      ),
    );
  }
}

class SettingsNumberField extends StatefulWidget {
  const SettingsNumberField({
    super.key,
    required this.title,
    required this.icon,
    required this.initialValue,
    required this.resetValue,
    required this.onChanged,
    required this.onReset,
    this.suffixText,
  });

  final String title;
  final IconData icon;
  final String initialValue;
  final String resetValue;
  final String? suffixText;
  final ValueChanged<String> onChanged;
  final VoidCallback onReset;

  @override
  State<SettingsNumberField> createState() => SettingsNumberFieldState();
}

class SettingsNumberFieldState extends State<SettingsNumberField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: widget.title,
      icon: widget.icon,
      controlBelow: true,
      trailing: HibikiTextField(
        controller: _controller,
        keyboardType: TextInputType.number,
        suffixText: widget.suffixText,
        suffixIcon: HibikiIconButton(
          tooltip: t.reset,
          size: 18,
          icon: Icons.undo_outlined,
          onTap: () {
            _controller.text = widget.resetValue;
            widget.onReset();
            FocusScope.of(context).unfocus();
          },
        ),
        labelText: widget.title,
        onChanged: widget.onChanged,
      ),
    );
  }
}
