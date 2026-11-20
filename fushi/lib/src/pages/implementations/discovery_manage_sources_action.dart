import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';

/// 发现页「⋯ › 管理来源」与无来源引导按钮的去处：「设置 › 在线服务」（发现
/// 来源的启停 / 排序在那里）。「浏览 › 发现」与各库页的「发现」子标签共用这
/// 一处，不各写一份。
///
/// 在线服务模块关着时那一页不存在，回 null——按钮整颗不渲染，不给点了没反应的
/// 入口。
VoidCallback? discoveryManageSourcesAction({
  required BuildContext context,
  required AppModel appModel,
}) {
  if (!appModel.moduleVisibility.isEnabled(ModuleId.services)) return null;
  return () => unawaited(
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) =>
            SettingsDetailPage(destination: buildServicesDestination()),
      ),
    ),
  );
}
