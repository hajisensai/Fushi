import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_now_tab.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/audiobook_companion_panel.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/manga_companion_panel.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/music_companion_panel.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/reader_companion_panel.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/srs_companion_panel.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/video_companion_panel.dart';
import 'package:material_ui/material_ui.dart';

/// The Now tab's module panels (one per media context the main screen
/// publishes a snapshot for). The game stream keeps its own panel mode.
final Map<CompanionContextKind, CompanionContextPanelBuilder>
companionContextPanels = <CompanionContextKind, CompanionContextPanelBuilder>{
  CompanionContextKind.reader:
      (BuildContext context, CompanionPanelSession session) =>
          ReaderCompanionPanel(session: session),
  CompanionContextKind.audiobook:
      (BuildContext context, CompanionPanelSession session) =>
          AudiobookCompanionPanel(session: session),
  CompanionContextKind.video:
      (BuildContext context, CompanionPanelSession session) =>
          VideoCompanionPanel(session: session),
  CompanionContextKind.manga:
      (BuildContext context, CompanionPanelSession session) =>
          MangaCompanionPanel(session: session),
  CompanionContextKind.music:
      (BuildContext context, CompanionPanelSession session) =>
          MusicCompanionPanel(session: session),
  CompanionContextKind.srs:
      (BuildContext context, CompanionPanelSession session) =>
          SrsCompanionPanel(session: session),
};
