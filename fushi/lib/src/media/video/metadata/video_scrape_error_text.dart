/// 刮削门（[VideoScrapeOperationGate]）把普通动作挡回来时给用户看的文案。
///
/// 引擎不能引 app 的 i18n，所以「刮削资料正在清理」在引擎与 app 里一律抛类型化的
/// [VideoScrapeMaintenanceActiveError]，由这里按类型出本地化文案。它的 `message`
/// 只是给日志看的兜底串；界面上直接 `'$error'` 会露出 `Bad state: …` 和不随界面
/// 语言变的中文。
library;

import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi/i18n/strings.g.dart';

/// [error] 是「刮削资料正在清理」时的本地化文案；不是则 null，由调用方用自己那一处
/// 的文案（如「设置封面失败」）。
String? videoScrapeMaintenanceText(Object? error) =>
    error is VideoScrapeMaintenanceActiveError
    ? t.video_scrape_maintenance_active
    : null;

/// 把刮削相关操作的失败转成一句给用户看的话：「正在清理」走本地化文案，其余原样。
String videoScrapeErrorText(Object error) =>
    videoScrapeMaintenanceText(error) ?? error.toString();
