// 收件箱指引文案按设备取「我的 iPhone」/「我的 iPad」（拍板台 1tOPDqYm4V）。
//
// 消费端（书 / 视频 / 漫画导入页、收件箱为空的提示）一律走这里，不直接取
// `media_import_inbox_*_iphone` / `_ipad`，免得某处漏判又在 iPad 上写回「我的 iPhone」。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/ios/ios_device_family.dart';

/// 导入方式卡片上的收件箱说明：「先把文件放进 文件 › 我的 iPad › Fushi › [folder]…」。
String importInboxHintText({required String folder, IosDeviceFamily? family}) {
  switch (family ?? currentIosDeviceFamily) {
    case IosDeviceFamily.ipad:
      return t.media_import_inbox_hint_ipad(folder: folder);
    case IosDeviceFamily.iphone:
      return t.media_import_inbox_hint_iphone(folder: folder);
  }
}

/// 收件箱里没有可导入文件时的提示。
String importInboxEmptyText({required String folder, IosDeviceFamily? family}) {
  switch (family ?? currentIosDeviceFamily) {
    case IosDeviceFamily.ipad:
      return t.media_import_inbox_empty_ipad(folder: folder);
    case IosDeviceFamily.iphone:
      return t.media_import_inbox_empty_iphone(folder: folder);
  }
}
