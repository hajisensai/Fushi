import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi/utils.dart';

/// 推一页独立的「设置 › 模型 › LLM」（提供商 + 功能指派），返回即回到原入口。
/// LLM 页已不是一级分类，所以直接给构造闭包而不是按 id 在一级分类里找。
///
/// 「AI 下视频」（首页）与「AI 下载」（浏览 › 发现的小说 / 漫画 / 游戏域）在未指派
/// 提供商时都经这一处引导去配置。
Future<void> pushAiSettingsPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => Scaffold(
        body: SafeArea(
          child: ModuleSettingsView.route(
            destinationId: SettingsDestinationId.ai,
            destination: buildAiDestination,
            title: t.ai_settings_title,
          ),
        ),
      ),
    ),
  );
}
