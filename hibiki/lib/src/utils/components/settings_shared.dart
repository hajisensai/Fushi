import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';

class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.text, {super.key, this.padding});
  final String text;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

const kSettingsSegmentedStyle = ButtonStyle(
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class AdaptiveSettingsScaffold extends StatelessWidget {
  const AdaptiveSettingsScaffold({
    required this.title,
    required this.children,
    super.key,
    this.actions,
    this.padding,
  });

  final Widget title;
  final List<Widget> children;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    final EdgeInsetsGeometry listPadding = padding ??
        EdgeInsets.fromLTRB(
          cupertino ? 12 : 16,
          cupertino ? 10 : 8,
          cupertino ? 12 : 16,
          8 + mediaPadding.bottom,
        );

    if (cupertino) {
      return CupertinoPageScaffold(
        backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
          context,
        ),
        child: CustomScrollView(
          slivers: <Widget>[
            CupertinoSliverNavigationBar(
              largeTitle: title,
              trailing: actions != null && actions!.isNotEmpty
                  ? Row(mainAxisSize: MainAxisSize.min, children: actions!)
                  : null,
            ),
            SliverPadding(
              padding: listPadding,
              sliver: SliverList(
                delegate: SliverChildListDelegate(children),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: adaptiveAppBar(
        context: context,
        title: title,
        actions: actions,
      ),
      body: ListView(
        padding: listPadding,
        children: children,
      ),
    );
  }
}

class AdaptiveSettingsSection extends StatelessWidget {
  const AdaptiveSettingsSection({
    required this.children,
    super.key,
    this.title,
  });

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    final bool cupertino = isCupertinoPlatform(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget group = ClipRRect(
      borderRadius: BorderRadius.circular(cupertino ? 12 : 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cupertino
              ? CupertinoColors.secondarySystemGroupedBackground
                  .resolveFrom(context)
              : scheme.surfaceContainerLowest,
          border: cupertino
              ? null
              : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
          borderRadius: BorderRadius.circular(cupertino ? 12 : 8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _withDividers(context, children),
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: cupertino ? 14 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null && title!.isNotEmpty)
            cupertino
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: Text(
                      title!.toUpperCase(),
                      style: TextStyle(
                        color:
                            CupertinoColors.secondaryLabel.resolveFrom(context),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : SettingsSectionHeader(
                    title!,
                    padding: const EdgeInsets.only(bottom: 6),
                  ),
          group,
        ],
      ),
    );
  }

  List<Widget> _withDividers(BuildContext context, List<Widget> rows) {
    final bool cupertino = isCupertinoPlatform(context);
    final Color dividerColor = cupertino
        ? CupertinoColors.separator.resolveFrom(context)
        : Theme.of(context).colorScheme.outlineVariant;
    final List<Widget> result = <Widget>[];
    for (int i = 0; i < rows.length; i++) {
      if (i > 0) {
        result.add(Divider(
          height: 1,
          thickness: 0.5,
          indent: cupertino ? 16 : 0,
          color: dividerColor,
        ));
      }
      result.add(rows[i]);
    }
    return result;
  }
}

class AdaptiveSettingsRow extends StatelessWidget {
  const AdaptiveSettingsRow({
    required this.title,
    super.key,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.controlBelow = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool controlBelow;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final Widget content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: cupertino ? 16 : 12,
        vertical: controlBelow ? 10 : 8,
      ),
      child:
          controlBelow ? _buildColumnLayout(context) : _buildRowLayout(context),
    );

    if (onTap == null) return content;
    if (cupertino) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: content,
      );
    }
    return InkWell(
      onTap: onTap,
      child: content,
    );
  }

  Widget _buildRowLayout(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: isCupertinoPlatform(context) ? 46 : 48,
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            _SettingsIcon(icon: icon!),
            const SizedBox(width: 12),
          ],
          Expanded(child: _SettingsLabel(title: title, subtitle: subtitle)),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }

  Widget _buildColumnLayout(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: isCupertinoPlatform(context) ? 58 : 60,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                _SettingsIcon(icon: icon!),
                const SizedBox(width: 12),
              ],
              Expanded(child: _SettingsLabel(title: title, subtitle: subtitle)),
            ],
          ),
          if (trailing != null) ...[
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: trailing!),
          ],
        ],
      ),
    );
  }
}

class AdaptiveSettingsSwitchRow extends StatelessWidget {
  const AdaptiveSettingsSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      trailing: adaptiveSwitch(
        context: context,
        value: value,
        onChanged: onChanged,
      ),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }
}

class AdaptiveSettingsSwitchActionRow extends StatelessWidget {
  const AdaptiveSettingsSwitchActionRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.body,
    this.actions = const <Widget>[],
    this.panel,
    this.controlBelow = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? body;
  final List<Widget> actions;
  final Widget? panel;
  final bool controlBelow;

  @override
  Widget build(BuildContext context) {
    final Widget switchControl = adaptiveSwitch(
      context: context,
      value: value,
      onChanged: onChanged,
    );
    final bool stacked = controlBelow || body != null || panel != null;
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      controlBelow: stacked,
      trailing: stacked
          ? _buildStackedTrailing(switchControl)
          : _buildInlineTrailing(switchControl),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }

  Widget _buildInlineTrailing(Widget switchControl) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ..._spacedActions(),
        if (actions.isNotEmpty) const SizedBox(width: 6),
        switchControl,
      ],
    );
  }

  Widget _buildStackedTrailing(Widget switchControl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (body != null) Expanded(child: body!) else const Spacer(),
            ..._spacedActions(),
            if (actions.isNotEmpty) const SizedBox(width: 6),
            switchControl,
          ],
        ),
        if (panel != null) ...[
          const SizedBox(height: 8),
          panel!,
        ],
      ],
    );
  }

  List<Widget> _spacedActions() {
    final List<Widget> spaced = <Widget>[];
    for (int i = 0; i < actions.length; i++) {
      spaced.add(Padding(
        padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
        child: actions[i],
      ));
    }
    return spaced;
  }
}

class AdaptiveSettingsSegmentedRow<T extends Object> extends StatelessWidget {
  const AdaptiveSettingsSegmentedRow({
    required this.title,
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.controlBelow = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool controlBelow;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      controlBelow: controlBelow,
      trailing: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: adaptiveSegmentedButton<T>(
          context: context,
          segments: segments,
          selected: <T>{selected},
          onSelectionChanged: (Set<T> values) {
            if (values.isEmpty) return;
            onChanged(values.first);
          },
          style: kSettingsSegmentedStyle,
        ),
      ),
    );
  }
}

class AdaptiveSettingsStepperRow extends StatelessWidget {
  const AdaptiveSettingsStepperRow({
    required this.title,
    required this.value,
    required this.step,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final double value;
  final double step;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SettingsStepButton(
            icon: Icons.remove,
            onPressed: () => onChanged((value - step).clamp(min, max)),
          ),
          SizedBox(
            width: 46,
            child: Text(
              format(value),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          _SettingsStepButton(
            icon: Icons.add,
            onPressed: () => onChanged((value + step).clamp(min, max)),
          ),
        ],
      ),
    );
  }
}

class AdaptiveSettingsSliderRow extends StatelessWidget {
  const AdaptiveSettingsSliderRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      controlBelow: true,
      trailing: adaptiveSlider(
        context: context,
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
  }
}

class AdaptiveSettingsNavigationRow extends StatelessWidget {
  const AdaptiveSettingsNavigationRow({
    required this.title,
    required this.onTap,
    super.key,
    this.subtitle,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final Color color = cupertino
        ? CupertinoColors.tertiaryLabel.resolveFrom(context)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      onTap: onTap,
      trailing: Icon(
        cupertino ? CupertinoIcons.chevron_right : Icons.chevron_right,
        size: cupertino ? 18 : 20,
        color: color,
      ),
    );
  }
}

class _SettingsLabel extends StatelessWidget {
  const _SettingsLabel({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final TextStyle? titleStyle = cupertino
        ? CupertinoTheme.of(context).textTheme.textStyle.copyWith(fontSize: 16)
        : Theme.of(context).textTheme.bodyMedium;
    final Color subtitleColor = cupertino
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(title, style: titleStyle, overflow: TextOverflow.ellipsis),
        if (subtitle != null && subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: subtitleColor),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
      ],
    );
  }
}

class _SettingsIcon extends StatelessWidget {
  const _SettingsIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cupertino ? scheme.primary : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(cupertino ? 7 : 8),
      ),
      child: SizedBox(
        width: cupertino ? 28 : 30,
        height: cupertino ? 28 : 30,
        child: Icon(
          icon,
          size: 18,
          color: cupertino ? scheme.onPrimary : scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _SettingsStepButton extends StatelessWidget {
  const _SettingsStepButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (isCupertinoPlatform(context)) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        minSize: 30,
        onPressed: onPressed,
        child: Icon(icon, size: 18),
      );
    }
    return IconButton(
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }
}
