import 'commands/book_metadata_commands.dart';
import 'commands/data_commands.dart';
import 'commands/disc_commands.dart';
import 'commands/dictionary_commands.dart';
import 'commands/game_commands.dart';
import 'commands/library_commands.dart';
import 'commands/media_links_commands.dart';
import 'commands/music_commands.dart';
import 'commands/online_commands.dart';
import 'commands/op_commands.dart';
import 'commands/settings_commands.dart';
import 'commands/srs_commands.dart';
import 'commands/url_import_commands.dart';
import 'commands/video_commands.dart';
import 'commands/web_commands.dart';
import 'ctl_commands.dart';

/// 全部按域注册的命令组。每个域只改自己的 `commands/<域>_commands.dart`。
const List<CtlCommandGroup> kCtlCommandGroups = <CtlCommandGroup>[
  ...libraryCommandGroups,
  ...dictionaryCommandGroups,
  ...settingsCommandGroups,
  ...dataCommandGroups,
  ...onlineCommandGroups,
  ...videoCommandGroups,
  ...gameCommandGroups,
  ...opCommandGroups,
  ...musicCommandGroups,
  ...srsCommandGroups,
  ...bookMetadataCommandGroups,
  ...mediaLinksCommandGroups,
  ...discCommandGroups,
  ...urlImportCommandGroups,
  ...webCommandGroups,
];
