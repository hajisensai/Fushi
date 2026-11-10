import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Name of a library, as the main app's navigation names it.
String companionLibraryLabel(CompanionLibraryKind library) => switch (library) {
  CompanionLibraryKind.books => t.books,
  CompanionLibraryKind.manga => t.manga_library,
  CompanionLibraryKind.video => t.nav_video,
  CompanionLibraryKind.music => t.nav_music,
  CompanionLibraryKind.games => t.nav_game,
};

/// One line saying what the top screen shows.
String companionContextLabel(CompanionContext context) =>
    switch (context.kind) {
      CompanionContextKind.none => t.second_screen_context_none,
      CompanionContextKind.home => t.second_screen_context_home,
      CompanionContextKind.library =>
        context.library == null
            ? t.second_screen_tab_library
            : t.second_screen_context_library(
                library: companionLibraryLabel(context.library!),
              ),
      CompanionContextKind.settings => t.second_screen_context_settings,
      CompanionContextKind.reader => t.second_screen_context_reader,
      CompanionContextKind.video => t.second_screen_context_video,
      CompanionContextKind.manga => t.second_screen_context_manga,
      CompanionContextKind.audiobook => t.second_screen_context_audiobook,
      CompanionContextKind.music => t.second_screen_context_music,
      CompanionContextKind.srs => t.second_screen_context_srs,
      CompanionContextKind.gameStream => t.second_screen_context_game_stream,
    };

IconData companionContextIcon(CompanionContextKind kind) => switch (kind) {
  CompanionContextKind.none => FushiIcons.devices,
  CompanionContextKind.home => FushiIcons.home,
  CompanionContextKind.library => FushiIcons.books,
  CompanionContextKind.settings => FushiIcons.settings,
  CompanionContextKind.reader => FushiIcons.readingMode,
  CompanionContextKind.video => FushiIcons.video,
  CompanionContextKind.manga => FushiIcons.manga,
  CompanionContextKind.audiobook => FushiIcons.audiobook,
  CompanionContextKind.music => FushiIcons.music,
  CompanionContextKind.srs => FushiIcons.ankiCard,
  CompanionContextKind.gameStream => FushiIcons.games,
};

String companionContinueKindLabel(CompanionContinueKind kind) => switch (kind) {
  CompanionContinueKind.book => t.second_screen_kind_book,
  CompanionContinueKind.manga => t.second_screen_kind_manga,
  CompanionContinueKind.video => t.second_screen_kind_video,
};

IconData companionContinueKindIcon(CompanionContinueKind kind) =>
    switch (kind) {
      CompanionContinueKind.book => FushiIcons.books,
      CompanionContinueKind.manga => FushiIcons.manga,
      CompanionContinueKind.video => FushiIcons.video,
    };
