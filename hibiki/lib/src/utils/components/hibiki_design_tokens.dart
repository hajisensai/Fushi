import 'package:flutter/material.dart';

class HibikiDesignTokens {
  const HibikiDesignTokens({
    required this.radii,
    required this.surfaces,
    required this.type,
    required this.spacing,
  });

  final HibikiRadii radii;
  final HibikiSurfaceColors surfaces;
  final HibikiTypeRoles type;
  final HibikiSpacingTokens spacing;

  static HibikiDesignTokens of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return HibikiDesignTokens(
      radii: const HibikiRadii(),
      surfaces: HibikiSurfaceColors.fromScheme(scheme),
      type: HibikiTypeRoles.fromTheme(theme),
      spacing: const HibikiSpacingTokens(),
    );
  }
}

class HibikiRadii {
  const HibikiRadii({
    this.group = 8,
    this.card = 8,
    this.control = 16,
    this.chip = 8,
    this.menu = 8,
    this.dialog = 16,
  });

  final double group;
  final double card;
  final double control;
  final double chip;
  final double menu;
  final double dialog;

  BorderRadius get groupRadius => BorderRadius.circular(group);
  BorderRadius get cardRadius => BorderRadius.circular(card);
  BorderRadius get controlRadius => BorderRadius.circular(control);
  BorderRadius get chipRadius => BorderRadius.circular(chip);
  BorderRadius get menuRadius => BorderRadius.circular(menu);
  BorderRadius get dialogRadius => BorderRadius.circular(dialog);
}

class HibikiSurfaceColors {
  const HibikiSurfaceColors({
    required this.page,
    required this.group,
    required this.card,
    required this.selected,
    required this.search,
    required this.overlay,
    required this.outline,
    required this.onSurface,
    required this.onVariant,
  });

  final Color page;
  final Color group;
  final Color card;
  final Color selected;
  final Color search;
  final Color overlay;
  final Color outline;
  final Color onSurface;
  final Color onVariant;

  factory HibikiSurfaceColors.fromScheme(ColorScheme scheme) {
    return HibikiSurfaceColors(
      page: scheme.surface,
      group: scheme.surfaceContainerLow,
      card: scheme.surfaceContainer,
      selected: scheme.secondaryContainer,
      search: scheme.surfaceContainerHigh,
      overlay: scheme.surfaceContainerHighest,
      outline: scheme.outlineVariant,
      onSurface: scheme.onSurface,
      onVariant: scheme.onSurfaceVariant,
    );
  }
}

class HibikiTypeRoles {
  const HibikiTypeRoles({
    required this.listTitle,
    required this.listSubtitle,
    required this.metadata,
    required this.sectionLabel,
    required this.controlLabel,
  });

  final TextStyle listTitle;
  final TextStyle listSubtitle;
  final TextStyle metadata;
  final TextStyle sectionLabel;
  final TextStyle controlLabel;

  factory HibikiTypeRoles.fromTheme(ThemeData theme) {
    final TextTheme textTheme = theme.textTheme;
    final ColorScheme scheme = theme.colorScheme;
    return HibikiTypeRoles(
      listTitle: (textTheme.bodyLarge ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      listSubtitle: (textTheme.bodySmall ?? const TextStyle()).copyWith(
        color: scheme.onSurfaceVariant,
      ),
      metadata: (textTheme.labelMedium ?? const TextStyle()).copyWith(
        color: scheme.onSurfaceVariant,
      ),
      sectionLabel: (textTheme.labelLarge ?? const TextStyle()).copyWith(
        color: scheme.onSurfaceVariant,
      ),
      controlLabel: textTheme.labelLarge ?? const TextStyle(),
    );
  }
}

class HibikiSpacingTokens {
  const HibikiSpacingTokens({
    this.page = 16,
    this.rowHorizontal = 16,
    this.rowVertical = 10,
    this.card = 16,
    this.gap = 8,
  });

  final double page;
  final double rowHorizontal;
  final double rowVertical;
  final double card;
  final double gap;
}
