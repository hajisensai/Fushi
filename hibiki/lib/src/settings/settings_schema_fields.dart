import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/utils.dart';

class SettingsSecretField extends StatefulWidget {
  const SettingsSecretField({
    super.key,
    required this.title,
    required this.icon,
    required this.initialValue,
    required this.onChanged,
    this.obscureText = false,
    this.revealToggle = false,
    this.keyboardType = TextInputType.text,
    this.hintText,
    this.subtitle,
    this.showIcon = false,
    this.debounce = const Duration(milliseconds: 500),
    this.resetValue,
    this.onReset,
  });

  final String title;
  final IconData? icon;
  final String initialValue;
  final bool obscureText;

  /// true 时在行尾提供眼睛按钮切换 [obscureText] 的显隐（SettingsTextItem 的
  /// secret 走此路径）；false 保持既有调用点行为（固定遮蔽、无切换）。
  final bool revealToggle;
  final TextInputType keyboardType;

  /// 可选占位提示（传给内部 TextField 的 decoration.hintText）。null = 不显示提示。
  final String? hintText;
  final String? subtitle;
  final bool showIcon;

  /// 击键到 [onChanged] 的防抖间隔；[Duration.zero] = 立即写。提交（回车）恒立即写。
  final Duration debounce;

  /// 非 null（连同 [onReset]）时行尾提供重置按钮：回填输入框 + 触发 [onReset]。
  final String? resetValue;
  final VoidCallback? onReset;
  final Future<void> Function(String value) onChanged;

  @override
  State<SettingsSecretField> createState() => SettingsSecretFieldState();
}

class SettingsSecretFieldState extends State<SettingsSecretField> {
  late final TextEditingController _controller;
  late bool _obscured;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _obscured = widget.obscureText;
  }

  @override
  void dispose() {
    // 防抖窗口内关页不丢输入：还有 pending 写入（timer 未触发）时同步冲刷最新
    // 文本再销毁。[SettingsSecretField.onChanged] 是纯写穿闭包、不依赖本 widget
    // 树，dispose 后触发安全。
    if (_debounce?.isActive ?? false) {
      unawaited(widget.onChanged(_controller.text));
    }
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleChanged(String value) {
    _debounce?.cancel();
    if (widget.debounce == Duration.zero) {
      unawaited(widget.onChanged(value));
      return;
    }
    _debounce = Timer(widget.debounce, () {
      unawaited(widget.onChanged(value));
    });
  }

  void _submit(String value) {
    _debounce?.cancel();
    unawaited(widget.onChanged(value));
  }

  void _reset() {
    _debounce?.cancel();
    _controller.text = widget.resetValue!;
    widget.onReset!();
    FocusScope.of(context).unfocus();
  }

  Widget? _suffix() {
    final List<Widget> actions = <Widget>[
      if (widget.revealToggle)
        HibikiIconButton(
          tooltip: _obscured ? t.settings_secret_show : t.settings_secret_hide,
          size: 18,
          icon: _obscured
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          onTap: () => setState(() => _obscured = !_obscured),
        ),
      if (widget.resetValue != null && widget.onReset != null)
        HibikiIconButton(
          tooltip: t.reset,
          size: 18,
          icon: Icons.undo_outlined,
          onTap: _reset,
        ),
    ];
    if (actions.isEmpty) return null;
    if (actions.length == 1) return actions.single;
    return Row(mainAxisSize: MainAxisSize.min, children: actions);
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: widget.title,
      subtitle: widget.subtitle,
      icon: widget.icon,
      showIcon: widget.showIcon,
      controlBelow: true,
      trailing: AdaptiveSettingsTextField(
        controller: _controller,
        obscureText: _obscured,
        keyboardType: widget.keyboardType,
        textInputAction: TextInputAction.done,
        labelText: widget.title,
        hintText: widget.hintText,
        suffixIcon: _suffix(),
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
    required this.onChanged,
    this.resetValue,
    this.onReset,
    this.suffixText,
    this.subtitle,
    this.showIcon = false,
    this.committedText,
  });

  final String title;
  final IconData? icon;
  final String initialValue;

  /// 非 null（连同 [onReset]）时行尾提供重置按钮：回填输入框 + 触发 [onReset]。
  final String? resetValue;
  final String? suffixText;

  /// TODO-1353: 可选副标题（如「Ctrl+滚轮可直接缩放弹窗内容」提示）。null 时不渲染，
  /// 现有调用点行为不变。
  final String? subtitle;
  final bool showIcon;
  final ValueChanged<String> onChanged;
  final VoidCallback? onReset;

  /// 当前已提交（解析 + 夹取后）值的格式化文本。非 null 时失焦同步输入框——键入
  /// 中不打扰（越界值在编辑途中很常见），编辑结束把「9999 实存 100」这类静默夹取
  /// 显性化，输入框回显真实存储值。null = 保持旧行为（不回写）。
  final String Function()? committedText;

  @override
  State<SettingsNumberField> createState() => SettingsNumberFieldState();
}

class SettingsNumberFieldState extends State<SettingsNumberField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
    _focusNode.addListener(_syncCommittedOnUnfocus);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_syncCommittedOnUnfocus);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 失焦把输入框文本对齐到已提交值（见 [SettingsNumberField.committedText]）。
  void _syncCommittedOnUnfocus() {
    if (_focusNode.hasFocus) return;
    final String? committed = widget.committedText?.call();
    if (committed != null && committed != _controller.text) {
      _controller.text = committed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool resettable = widget.resetValue != null && widget.onReset != null;
    return AdaptiveSettingsRow(
      title: widget.title,
      subtitle: widget.subtitle,
      icon: widget.icon,
      showIcon: widget.showIcon,
      controlBelow: true,
      trailing: HibikiTextField(
        controller: _controller,
        focusNode: _focusNode,
        keyboardType: TextInputType.number,
        suffixText: widget.suffixText,
        suffixIcon: resettable
            ? HibikiIconButton(
                tooltip: t.reset,
                size: 18,
                icon: Icons.undo_outlined,
                onTap: () {
                  _controller.text = widget.resetValue!;
                  widget.onReset!();
                  FocusScope.of(context).unfocus();
                },
              )
            : null,
        labelText: widget.title,
        onChanged: widget.onChanged,
      ),
    );
  }
}
