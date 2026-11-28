import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_data.dart';
import 'package:fushi/src/ops/op_descriptions_feedback.dart';
import 'package:fushi/src/ops/op_descriptions_web.dart';
import 'package:fushi/src/ops/op_descriptions_web_search.dart';
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

/// **旧路径**：还没迁到 [OpSpec] 的域的操作描述（按 `METHOD pattern` 挂到手写路由
/// 上）。迁走一个域就从这里删掉它的 `describe*Ops` 和 `op_descriptions_<域>.dart`；
/// 已迁的域在 `buildDomainOpRoutes`（`op_routes.dart`）里以 [FushiOp] 直接进路由表，
/// 目录从路由上取（[CtlRoute.op]）。剩余数量由 `op_catalog_ratchet_guard_test.dart`
/// 只减不增地卡住。
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
      ...describeWebOps(kit),
      ...describeWebSearchOps(kit),
      ...describeFeedbackOps(kit),
    ];

/// 组操作目录：[routes] 里 [OpSpec] 派生的路由直接带操作，旧描述挂到其余手写路由上。
/// 旧描述对不上路由时抛 [StateError]。
OpCatalog buildAppOpCatalog(
  OpContext context,
  List<CtlRoute> routes, {
  Iterable<FushiOp> extra = const <FushiOp>[],
}) {
  final OpDescribeKit kit = OpDescribeKit(context, routes);
  return OpCatalog.build(routes, buildAppOpDescriptions(kit), extra: extra);
}
