import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// contentBlockers 平台（iOS / macOS）的 WebKit 内容拦截规则表：**进程级、按内容寻址、
/// 只编译一次**（BUG-4013）。
///
/// 上游 `flutter_inappwebview_ios` / `_macos` 1.1.2 每建一个 WebView（以及每次
/// `setSettings`）都把 `contentBlockers` 整份（约 5 万条）经平台通道传过去、在主线程反序列化，
/// 再用固定 identifier `ContentBlockingRules` 重新 `compileContentRuleList`，不缓存——多开几个
/// 标签页就把 iOS 的虚拟地址空间耗尽。现在：
///
/// - Rust 核心导出的 WebKit 规则 JSON（[contentRuleListIdentifierFor] 在后台 isolate 算
///   SHA-256）→ identifier `fushi-adblock-<hex>`；
/// - 每个规则集只经 [ContentRuleListInstaller] 走一次原生：`activate`（原生内存缓存 →
///   `WKContentRuleListStore.lookUpContentRuleList`，跨启动复用磁盘上的编译产物），未命中才
///   `compile` 一次原始 JSON 字节（`Uint8List` 走平台通道是整块拷贝，不逐条编码）；
/// - 每个 WebView 的 `contentBlockers` 只带一条引用 [contentRuleListReference]，原生
///   （`ci/patches/hosted/flutter_inappwebview_{ios,macos}-1.1.2/.../FushiContentRuleLists.swift`）
///   认出引用后挂上**共享**的 `WKContentRuleList`；同一引用的 `setSettings` 不动规则表；
/// - 原生在启用新规则集后删掉旧的 `fushi-adblock-*` 与上游的 `ContentBlockingRules`。
///
/// 引用本身是一条合法的 WebKit 规则（`url-filter` 是只会匹配这串字面量的正则）：补丁万一没打上，
/// 上游会把它当一条永不命中的规则编译——不拦，但也不误拦、不爆内存。
const String kContentRuleListChannelName = 'fushi/content_rule_list';

/// Fushi 编进 `WKContentRuleListStore` 的 identifier 前缀（原生按它清理旧规则表）。
const String kContentRuleListIdentifierPrefix = 'fushi-adblock-';

/// WebView 引用条目的 `url-filter` 前缀（原生按它识别引用）。
const String kContentRuleListReferencePrefix = 'fushi-content-rule-list:';

/// 原生规则表的两条命令。实现方：[MethodChannelContentRuleListInstaller]；测试可注入假实现。
abstract interface class ContentRuleListInstaller {
  /// [identifier] 已在原生内存或持久化 store 里：启用它并返回 true；否则 false。
  Future<bool> activate(String identifier);

  /// 把 WebKit 规则 JSON 原文编译成 [identifier] 并启用（编译失败抛 [PlatformException]）。
  Future<void> compile(String identifier, Uint8List json);
}

/// 走补丁注册的 `fushi/content_rule_list` 平台通道。
class MethodChannelContentRuleListInstaller
    implements ContentRuleListInstaller {
  const MethodChannelContentRuleListInstaller();

  static const MethodChannel _channel = MethodChannel(
    kContentRuleListChannelName,
  );

  @override
  Future<bool> activate(String identifier) async =>
      await _channel.invokeMethod<bool>('activate', <String, Object?>{
        'identifier': identifier,
      }) ??
      false;

  @override
  Future<void> compile(String identifier, Uint8List json) async {
    await _channel.invokeMethod<bool>('compile', <String, Object?>{
      'identifier': identifier,
      'json': json,
    });
  }
}

/// [json]（WebKit 内容拦截规则 JSON）的稳定 identifier；规则表为空（`[]`）时 null。
/// SHA-256 在后台 isolate 算，不占 UI 线程。
Future<String?> contentRuleListIdentifierFor(Uint8List json) =>
    Isolate.run<String?>(() => contentRuleListIdentifierOf(json));

/// [contentRuleListIdentifierFor] 的同步本体（给测试与后台 isolate 用）。
String? contentRuleListIdentifierOf(Uint8List json) {
  if (_isEmptyJsonArray(json)) return null;
  return '$kContentRuleListIdentifierPrefix${sha256.convert(json)}';
}

/// 只认 `[` 空白 `]`：WebKit 不接受空规则表，空表就不建引用。
bool _isEmptyJsonArray(Uint8List json) {
  int i = 0;
  bool isSpace(int c) => c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09;
  while (i < json.length && isSpace(json[i])) {
    i++;
  }
  if (i == json.length) return true;
  if (json[i] != 0x5B) return false; // [
  i++;
  while (i < json.length && isSpace(json[i])) {
    i++;
  }
  if (i == json.length || json[i] != 0x5D) return false; // ]
  i++;
  while (i < json.length && isSpace(json[i])) {
    i++;
  }
  return i == json.length;
}

/// WebView `contentBlockers` 里指向共享规则表 [identifier] 的那一条引用。
ContentBlocker contentRuleListReference(String identifier) => ContentBlocker(
  trigger: ContentBlockerTrigger(
    urlFilter: '$kContentRuleListReferencePrefix$identifier',
  ),
  action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
);

/// [blockers] 是引用时返回它指向的 identifier（与原生 `referencedIdentifier` 同口径）。
String? contentRuleListReferencedIdentifier(List<ContentBlocker>? blockers) {
  if (blockers == null || blockers.length != 1) return null;
  final String filter = blockers.single.trigger.urlFilter;
  if (!filter.startsWith(kContentRuleListReferencePrefix)) return null;
  final String id = filter.substring(kContentRuleListReferencePrefix.length);
  return id.startsWith(kContentRuleListIdentifierPrefix) ? id : null;
}
