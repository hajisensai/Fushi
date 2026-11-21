/// 有声漫画工作台的入口（书卡菜单「有声漫画工作台」、侧栏速览「加声音」只调这里）。
///
/// 工作台页面要读 AppModel、直接打开演出稿 / 制作台页面，本身就在 lib/ 的大 import
/// 环里；菜单与速览所在的页面也在环里。两边直接互相 import 会把工作台页拉进环
/// （`test/build/import_cycle_guard_test.dart`）。所以这里只放环外的入口：页面实现由
/// `main()` 启动时经 [MangaAudioWorkbenchEntry.register] 注册，调用方只依赖这个文件
/// （material_ui + fushi_core + fushi_engine，不 import 任何 app 内文件）。
library;

import 'package:fushi_core/fushi_core.dart' show AudiobookRow, FushiDatabase;
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart'
    show kMangaAlignmentFormat;
import 'package:material_ui/material_ui.dart';

/// 打开 [bookKey] 这一卷的工作台。
typedef MangaAudioWorkbenchOpener =
    Future<void> Function(BuildContext context, {required String bookKey});

/// 工作台入口副行（本地化的进度一行；还没开始 / 做不了有声返回 null）。
typedef MangaAudioWorkbenchStatusReader =
    Future<String?> Function(BuildContext context, String bookKey);

/// 工作台入口的注册表：页面实现启动时注册一次，菜单 / 速览经它调用。
abstract final class MangaAudioWorkbenchEntry {
  static MangaAudioWorkbenchOpener? _open;
  static MangaAudioWorkbenchStatusReader? _status;

  /// 由 `main()` 调用（`registerMangaAudioWorkbenchEntry`）；重复注册以最后一次为准。
  static void register({
    required MangaAudioWorkbenchOpener open,
    required MangaAudioWorkbenchStatusReader statusLine,
  }) {
    _open = open;
    _status = statusLine;
  }

  /// 测试用：清掉注册。
  @visibleForTesting
  static void reset() {
    _open = null;
    _status = null;
  }

  /// 是否已注册。未注册（只挂了部分 app 的 widget test）时入口不显示。
  static bool get isAvailable => _open != null;

  /// 打开工作台；未注册时什么都不做。
  static Future<void> open(BuildContext context, {required String bookKey}) {
    final MangaAudioWorkbenchOpener? open = _open;
    if (open == null) return Future<void>.value();
    return open(context, bookKey: bookKey);
  }

  /// 菜单副行；未注册时返回 null（菜单显示「还没开始」）。
  static Future<String?> statusLine(BuildContext context, String bookKey) {
    final MangaAudioWorkbenchStatusReader? status = _status;
    if (status == null) return Future<String?>.value();
    return status(context, bookKey);
  }
}

/// 这一卷有没有登记好的漫画有声成品（生成 / 导入 / 广播剧匹配登记的都算）。与
/// `loadMangaAudio` 同一判据（`Audiobooks.alignmentFormat` = [kMangaAlignmentFormat]），
/// 只查一行库，不读清单。
Future<bool> mangaHasAudio(FushiDatabase database, String bookKey) async {
  final AudiobookRow? row = await database.getAudiobookByBookKey(bookKey);
  return row != null && row.alignmentFormat == kMangaAlignmentFormat;
}
