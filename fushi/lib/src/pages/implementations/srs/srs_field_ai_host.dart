/// 卡片字段 AI 入口要的宿主能力（AppModel 实现、调用方注入）。
///
/// 字段 AI 入口被笔记编辑页 / 浏览页检查器 / 复习页（本就在大 import 环里）import；它若直接 import
/// AppModel，就跟着进环。只认这个窄接口，环不随字段 AI 变大。
library;

import 'package:fushi/src/models/module_id.dart' show ModuleVisibility;
import 'package:fushi/src/models/preferences_repository.dart';

abstract interface class SrsFieldAiHost {
  /// 模块可见性（AI 模块门，[isAiModuleEnabled] 的输入）。
  ModuleVisibility get moduleVisibility;

  /// 偏好仓库（「复习卡片字段」的提供商指派、设备本地的示例提示词库）。
  PreferencesRepository get prefsRepo;
}
