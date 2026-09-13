import 'package:flutter/material.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_expansion_state.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// Shared disclosure for schema sections and complex body forms.
/// Search expansion lasts for this visit and never writes the saved preference.
class SettingsSectionContainer extends StatefulWidget {
  const SettingsSectionContainer({
    super.key,
    required this.id,
    required this.children,
    this.title,
    this.summary,
    this.presentation = SettingsSectionPresentation.alwaysExpanded,
    this.searchTargetIds = const <String>[],
    this.expansionState,
  });

  final String id;
  final String? title;
  final String? summary;
  final List<Widget> children;
  final SettingsSectionPresentation presentation;
  final List<String> searchTargetIds;
  final SettingsExpansionState? expansionState;

  @override
  State<SettingsSectionContainer> createState() =>
      _SettingsSectionContainerState();
}

class _SettingsSectionContainerState extends State<SettingsSectionContainer> {
  SettingsExpansionState get _state =>
      widget.expansionState ?? SettingsExpansionState.instance;
  bool _searchExpanded = false;
  int _searchGeneration = -1;

  @override
  void initState() {
    super.initState();
    _state.addListener(_refresh);
    _load();
  }

  Future<void> _load() async {
    try {
      await _state.load();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'settings expansion',
          context: ErrorDescription('while reading device section preferences'),
        ),
      );
    }
  }

  @override
  void didUpdateWidget(SettingsSectionContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _searchExpanded = false;
      _searchGeneration = -1;
    }
    if (oldWidget.expansionState != widget.expansionState) {
      (oldWidget.expansionState ?? SettingsExpansionState.instance)
          .removeListener(_refresh);
      _state.addListener(_refresh);
      _load();
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _state.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _toggle(bool expanded) async {
    setState(() => _searchExpanded = false);
    try {
      await _state.setExpanded(widget.id, expanded);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'settings expansion',
          context: ErrorDescription('while saving a device section preference'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_searchGeneration != SettingsSearchReveal.generation &&
        widget.searchTargetIds.contains(SettingsSearchReveal.pendingItemId)) {
      _searchGeneration = SettingsSearchReveal.generation;
      _searchExpanded = true;
    }
    final bool collapsible =
        widget.presentation != SettingsSectionPresentation.alwaysExpanded &&
        (widget.title?.isNotEmpty ?? false);
    return AdaptiveSettingsSection(
      title: widget.title,
      summary: widget.summary,
      titlePlacement: SettingsSectionTitlePlacement.inside,
      collapsible: collapsible,
      expanded:
          debugSettingsForceExpandAllSections ||
          _searchExpanded ||
          _state.value(
            widget.id,
            defaultValue:
                widget.presentation != SettingsSectionPresentation.collapsed,
          ),
      onExpansionChanged: _toggle,
      children: widget.children,
    );
  }
}
