/// 更新检查 / 下载 / 安装的统一入口（barrel library，TODO-584 拆分）。
///
/// 本文件本身只声明 `library` + 4 个 `part`，零逻辑——所有实现按职责分到 4 个
/// part 文件，共享本库的 import 与私有作用域（`part of` 语义，私有符号如
/// `_DownloadOverlay` 跨 part 互相可见，对外 API、测试可见性导出、
/// `package:hibiki/src/utils/misc/update_checker.dart` import 路径全部零变化）：
///   * [update_checker_net.dart]     —— URL 候选 / 多镜像回退 / 系统代理 / 网络失败分类（纯网络层）。
///   * [update_checker_download.dart] —— 下载引擎：多线程分片 / 续传 / 校验 / staging / 元数据（最大整族）。
///   * [update_checker_release.dart]  —— [UpdateChecker] 门面 + release 检查 / 版本比较 / 通道匹配。
///   * [update_checker_ui.dart]       —— 对话框（[UpdateAvailableDialog] 等）+ 下载进度遮罩 + 字节/速度格式化。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_handoff.dart';
import 'package:hibiki/utils.dart';

part 'update_checker_net.dart';
part 'update_checker_download.dart';
part 'update_checker_release.dart';
part 'update_checker_ui.dart';
