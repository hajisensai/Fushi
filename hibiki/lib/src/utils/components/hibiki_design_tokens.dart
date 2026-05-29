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

  // HBK-AUDIT-150: `of` is named like an O(1) lookup but used to build a fresh
  // token graph (11 Color reads + 6 TextStyle.copyWith allocations) on every
  // call — i.e. on every build of every component that reads it, several of
  // which call it more than once per build. ColorScheme/TextTheme are immutable
  // and Theme.of returns the same instance until the theme changes, so we
  // memoize by (scheme, textTheme) identity: the graph is rebuilt only when the
  // theme actually changes, and repeat calls within a frame return the cache.
  static ColorScheme? _cachedScheme;
  static TextTheme? _cachedTextTheme;
  static HibikiDesignTokens? _cached;

  static HibikiDesignTokens of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;
    final HibikiDesignTokens? cached = _cached;
    if (cached != null &&
        identical(_cachedScheme, scheme) &&
        identical(_cachedTextTheme, textTheme)) {
      return cached;
    }
    final HibikiDesignTokens tokens = HibikiDesignTokens(
      radii: const HibikiRadii(),
      surfaces: HibikiSurfaceColors.fromScheme(scheme),
      type: HibikiTypeRoles.fromTheme(theme),
      spacing: const HibikiSpacingTokens(),
    );
    _cachedScheme = scheme;
    _cachedTextTheme = textTheme;
    _cached = tokens;
    return tokens;
  }
}

class HibikiRadii {
  const HibikiRadii({
    this.group = 12,
    this.card = 12,
    this.control = 16,
    this.chip = 8,
    this.menu = 12,
    this.dialog = 28,
    this.sheet = 28,
  });

  final double group;
  final double card;
  final double control;
  final double chip;
  final double menu;
  final double dialog;
  final double sheet;

  BorderRadius get groupRadius => BorderRadius.circular(group);
  BorderRadius get cardRadius => BorderRadius.circular(card);
  BorderRadius get controlRadius => BorderRadius.circular(control);
  BorderRadius get chipRadius => BorderRadius.circular(chip);
  BorderRadius get menuRadius => BorderRadius.circular(menu);
  BorderRadius get dialogRadius => BorderRadius.circular(dialog);
  BorderRadius get sheetRadius =>
      BorderRadius.vertical(top: Radius.circular(sheet));
  Radius get chipCorner => Radius.circular(chip);
}

class HibikiSurfaceColors {
  const HibikiSurfaceColors({
    required this.primary,
    required this.primaryContainer,
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

  final Color primary;
  final Color primaryContainer;
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
      primary: scheme.primary,
      primaryContainer: scheme.primaryContainer,
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
    required this.pageTitle,
    required this.listTitle,
    required this.listSubtitle,
    required this.metadata,
    required this.sectionLabel,
    required this.controlLabel,
  });

  final TextStyle pageTitle;
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
      pageTitle: (textTheme.headlineMedium ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      sectionLabel: (textTheme.labelLarge ?? const TextStyle()).copyWith(
        color: scheme.primary,
        fontWeight: FontWeight.w600,
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
