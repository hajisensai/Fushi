import 'package:flutter/material.dart';

/// A draft numeric editor: partial input is not committed until Enter/blur.
/// External drags update it when unfocused; step buttons commit immediately.
class GalCalibrationNumberField extends StatefulWidget {
  const GalCalibrationNumberField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.enabled = true,
    super.key,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final double step;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  State<GalCalibrationNumberField> createState() =>
      _GalCalibrationNumberFieldState();
}

class _GalCalibrationNumberFieldState extends State<GalCalibrationNumberField> {
  late final TextEditingController _text;
  final FocusNode _focus = FocusNode();
  bool _editing = false;

  String _format(double value) => value.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: _format(widget.value));
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (!_focus.hasFocus && _editing) _commit();
  }

  @override
  void didUpdateWidget(covariant GalCalibrationNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus || !widget.enabled) {
      _text.text = _format(widget.value);
      _editing = false;
    }
  }

  void _commit([double? proposed]) {
    final double? parsed = proposed ?? double.tryParse(_text.text);
    final double value = parsed == null || !parsed.isFinite
        ? widget.value
        : parsed.clamp(widget.min, widget.max);
    _editing = false;
    _text.text = _format(value);
    if (widget.enabled && value != widget.value) widget.onChanged(value);
  }

  void _step(double direction) {
    final double? parsed = double.tryParse(_text.text);
    _commit(
      (parsed != null && parsed.isFinite ? parsed : widget.value) +
          direction * widget.step,
    );
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    focusNode: _focus,
    enabled: widget.enabled,
    keyboardType: const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
    textInputAction: TextInputAction.done,
    onChanged: (_) => _editing = true,
    onSubmitted: (_) => _commit(),
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: '${widget.label} −${widget.step}',
            icon: const Icon(Icons.remove),
            onPressed: widget.enabled && widget.value > widget.min
                ? () => _step(-1)
                : null,
          ),
          IconButton(
            tooltip: '${widget.label} +${widget.step}',
            icon: const Icon(Icons.add),
            onPressed: widget.enabled && widget.value < widget.max
                ? () => _step(1)
                : null,
          ),
        ],
      ),
    ),
  );
}
