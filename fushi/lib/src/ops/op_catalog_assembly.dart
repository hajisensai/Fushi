import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_data.dart';
import 'package:fushi/src/ops/op_descriptions_feedback.dart';
import 'package:fushi/src/ops/op_descriptions_anime_download.dart';
import 'package:fushi/src/ops/op_descriptions_leaderboard.dart';
import 'package:fushi/src/ops/op_descriptions_web.dart';
import 'package:fushi/src/ops/op_descriptions_web_search.dart';
import 'package:fushi/src/ops/op_descriptions_url_import.dart';
import 'package:fushi/src/ops/op_descriptions_disc.dart';
import 'package:fushi/src/ops/op_descriptions_media_links.dart';
import 'package:fushi/src/ops/op_descriptions_book_metadata.dart';
import 'package:fushi/src/ops/op_descriptions_library_scrape.dart';
import 'package:fushi/src/ops/op_descriptions_srs.dart';
import 'package:fushi/src/ops/op_descriptions_srs_mined_import.dart';
import 'package:fushi/src/ops/op_descriptions_tts.dart';
import 'package:fushi/src/ops/op_descriptions_music.dart';
import 'package:fushi/src/ops/op_descriptions_music_import.dart';
import 'package:fushi/src/ops/op_descriptions_dictionary.dart';
import 'package:fushi/src/ops/op_descriptions_downloads.dart';
import 'package:fushi/src/ops/op_descriptions_games.dart';
import 'package:fushi/src/ops/op_descriptions_game_hook_codes.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart';
import 'package:fushi/src/ops/op_descriptions_library_agent.dart';
import 'package:fushi/src/ops/op_descriptions_library_curate.dart';
import 'package:fushi/src/ops/op_descriptions_online.dart';
import 'package:fushi/src/ops/op_descriptions_settings.dart';
import 'package:fushi/src/ops/op_descriptions_page_backdrop.dart';
import 'package:fushi/src/ops/op_descriptions_settings_more.dart';
import 'package:fushi/src/ops/op_descriptions_video.dart';

/// 全部带描述的操作（spec §4.2 棘轮：没描述的路由照旧只给 CLI 用）。每个域只改
/// 自己的 `op_descriptions_<域>.dart`。
List<OpDescription> buildAppOpDescriptions(OpDescribeKit kit) =>
    <OpDescription>[
      ...describeSettingsOps(kit),
      ...describeSettingsMoreOps(kit),
      ...describePageBackdropOps(kit),
      ...describeOnlineOps(kit),
      ...describeDownloadOps(kit),
      ...describeVideoOps(kit),
      ...describeLibraryOps(kit),
      ...describeLibraryCurateOps(kit),
      ...describeLibraryAgentOps(kit),
      ...describeGameOps(kit),
      ...describeGameHookCodeOps(kit),
      ...describeDictionaryOps(kit),
      ...describeDataOps(kit),
      ...describeMusicOps(kit),
      ...describeMusicImportOps(kit),
      ...describeSrsOps(kit),
      ...describeSrsMinedImportOps(kit),
      ...describeTtsOps(kit),
      ...describeBookMetadataOps(kit),
      ...describeLibraryScrapeOps(kit),
      ...describeMediaLinksOps(kit),
      ...describeDiscOps(kit),
      ...describeUrlImportOps(kit),
      ...describeWebOps(kit),
      ...describeWebSearchOps(kit),
      ...describeFeedbackOps(kit),
      ...describeLeaderboardOps(kit),
      ...describeAnimeDownloadOps(kit),
    ];

/// 把描述挂到 [routes] 上组成操作目录。描述对不上路由时抛 [StateError]。
OpCatalog buildAppOpCatalog(
  OpContext context,
  List<CtlRoute> routes, {
  Iterable<FushiOp> extra = const <FushiOp>[],
}) {
  final OpDescribeKit kit = OpDescribeKit(context, routes);
  return OpCatalog.build(routes, buildAppOpDescriptions(kit), extra: extra);
}
