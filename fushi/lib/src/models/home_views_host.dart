/// 首页视图（[HomeView]）的窄宿主接口：「首页显示」菜单与「管理视图」页只经它读写
/// 视图，不 import AppModel（AppModel 实现它）。这样这两个 UI 文件留在 `lib/` 最大
/// import 环外（`test/build/import_cycle_guard_test.dart`）。
library;

import 'package:flutter/foundation.dart' show Listenable;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

import 'package:fushi/src/models/home_view.dart';

/// 视图读写 + 编辑器取语言 / 标签选项用的数据库。变更经 [Listenable] 通知。
abstract interface class HomeViewsHost implements Listenable {
  /// 保存的视图（本配置）。
  List<HomeView> get homeViews;

  Future<void> setHomeViews(List<HomeView> views);

  /// 本配置首页默认显示的视图 id（[kHomeViewEverythingId] = 全部）。
  String get homeViewActiveId;

  Future<void> setHomeViewActiveId(String id);

  /// 此刻生效的视图（开关关着 / 全部 / 指不到 = null）。
  HomeView? get activeHomeView;

  FushiDatabase get database;
}
