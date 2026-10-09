import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/reader/font_catalog.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/sync/font_sync.dart';

/// 字体同步的 app 侧实现：读写字体库页同一份目录状态。
///
/// 写入走 [persistCustomFontState]——与字体库页、浏览器扩展字体端点同一条路径：
/// 写穿 DB 之后刷新阅读器设置缓存、app 全局字体、galgame 浮窗，下载下来的字体当场
/// 注册生效（FontLoader），不用重启。
class AppFontSyncLocal implements FontSyncLocal {
  AppFontSyncLocal(this._appModel);

  final AppModel _appModel;

  @override
  String get fontsRoot => customFontsDirectory(_appModel.appDirectory).path;

  Future<ReaderSettings> _settings() async {
    ReaderSettings? settings = ReaderFushiSource.readerSettings;
    if (settings == null) {
      settings = ReaderSettings(_appModel.database);
      await settings.refreshFromDb();
      ReaderFushiSource.readerSettings = settings;
    }
    return settings;
  }

  @override
  Future<FontCatalogState> readState() async => readCustomFontCatalogState(
        database: _appModel.database,
        settings: await _settings(),
      );

  @override
  Future<void> applyState(FontCatalogState state) async {
    await persistCustomFontState(
      appModel: _appModel,
      settings: await _settings(),
      state: state,
      legacy: <String, List<Map<String, dynamic>>>{
        for (final FontTarget target in FontTarget.values)
          if (state.hasTarget(ReaderSettings.fontKeyForTarget(target)))
            ReaderSettings.fontKeyForTarget(target): state
                .fontListForTarget(ReaderSettings.fontKeyForTarget(target)),
      },
    );
  }
}
