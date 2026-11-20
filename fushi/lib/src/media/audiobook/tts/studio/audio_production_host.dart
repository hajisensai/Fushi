/// 有声制作（小说 TTS 制作台 / 漫画有声 / 广播剧音轨）服务层对 app 的窄依赖。
///
/// 这些服务只用到数据库、数据目录、偏好仓库与有声书会话（换音轨前停掉正在播的
/// 那本），由 `AppModel` 实现本接口、调用方把它注入进来。服务文件因此不 import
/// `app_model.dart`，不会经 AppModel 被拖进 lib/ 的 import 大环（见
/// `test/build/import_cycle_guard_test.dart`）。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/models/preferences_repository.dart';

abstract interface class AudioProductionHost {
  /// 主库。
  FushiDatabase get database;

  /// 数据根目录（制作台的演出稿 / 声线 / 渲染工作区都在它下面）。
  Directory get databaseDirectory;

  /// 偏好仓库；读之前先看 [isPreferencesReady]（启动早期还没装好）。
  PreferencesRepository get prefsRepo;

  /// [prefsRepo] 是否已就绪。
  bool get isPreferencesReady;

  /// 全局有声书会话：重新生成 / 换掉一本书的音轨前要先停掉它。
  AudiobookSession get audiobookSession;
}
