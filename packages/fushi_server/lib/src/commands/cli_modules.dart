/// 已注册的命令模块（`cli.dart` 按顺序登记与分发）。
library;

import 'package:fushi_server/src/commands/audiobook_commands.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/import_commands.dart';
import 'package:fushi_server/src/commands/leaderboard_commands.dart';
import 'package:fushi_server/src/commands/ocr_commands.dart';
import 'package:fushi_server/src/commands/discover_commands.dart';
import 'package:fushi_server/src/commands/export_commands.dart';
import 'package:fushi_server/src/commands/media_server_commands.dart';
import 'package:fushi_server/src/commands/stats_commands.dart';
import 'package:fushi_server/src/commands/sync_commands.dart';
import 'package:fushi_server/src/commands/tracking_commands.dart';
import 'package:fushi_server/src/commands/subs_commands.dart';
import 'package:fushi_server/src/commands/video_commands.dart';
import 'package:fushi_server/src/commands/dict_commands.dart';

/// 每个模块一行；模块内部的命令名不得与 `cli.dart` 内建命令或其它模块重名
/// （`test/cli_modules_test.dart` 守卫）。
const List<CliModule> kCliModules = <CliModule>[
  ImportCommands(),
  OcrCommands(),
  AudiobookCommands(),
  StatsModule(),
  SyncModule(),
  ExportModule(),
  DiscoverModule(),
  MediaServerModule(),
  TrackingModule(),
  SubsCliModule(),
  VideoCliModule(),
  DictCliModule(),
  LeaderboardModule(),
];
