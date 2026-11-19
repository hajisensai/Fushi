// 本地构建提示：不联网，按 build_info.dart 读到的签名证书摘要（h / k）判断本构建是否在
// 发布方登记的构建之列，不在时每次冷启动弹一次本地提示，并让设置 · 关于里的「免费与开源
// 声明」页多显示一行。
//
// 判据（[localNoticeApplies]）：
//   - h ∪ k 非空且其中没有任何一个摘要是登记过的；或
//   - h、k 都非空却没有共同摘要（两个来源互相对不上）。
// h、k 都为空（非 Android、读取失败）一律不提示，宁可漏也不误报。只在 Android release 构建生效。
//
// 登记的摘要只存加盐后的 SHA-256（[kListedDigestHashes]）；提示文字不进 i18n json，按界面语言
// 在运行时解出（[localNoticeText]）。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/updates/build_info.dart';
import 'package:fushi/src/updates/notice_feed.dart';

const String _salt = 'q7Lr2:';

/// 登记过的构建：证书摘要加盐后的 SHA-256（小写十六进制）。
final Set<String> kListedDigestHashes = Set<String>.unmodifiable(<String>{
  <String>[
    '86f1ab0c8acfca0791f2f8dba8251cc0',
    '819af707884079fcf17b555a048b1cad',
  ].join(),
});

/// 证书摘要加盐后的 SHA-256。
String listedDigestHash(String digest) =>
    sha256.convert(utf8.encode('$_salt${digest.toLowerCase()}')).toString();

/// [digest] 是否登记过。
bool isListedDigest(String digest, {Set<String>? listed}) =>
    (listed ?? kListedDigestHashes).contains(listedDigestHash(digest));

/// 纯判据：给定两个来源的证书摘要，是否要显示本地提示（见文件头）。
bool localNoticeApplies(List<String> h, List<String> k, {Set<String>? listed}) {
  final Set<String> all = <String>{...h, ...k};
  if (all.isEmpty) return false;
  if (h.isNotEmpty && k.isNotEmpty && !h.any(k.contains)) return true;
  return !all.any((String d) => isListedDigest(d, listed: listed));
}

Future<bool>? _cachedActive;

/// 本进程是否要显示本地提示：只在 Android release 构建上读 [readBuildInfo] 判断；永不抛，
/// 按进程缓存。
Future<bool> localNoticeActive() => _cachedActive ??= _resolveActive();

Future<bool> _resolveActive() async {
  if (!kReleaseMode || !Platform.isAndroid) return false;
  try {
    final BuildInfo info = await readBuildInfo();
    return localNoticeApplies(info.h, info.k);
  } on Object catch (e) {
    debugPrint('BuildListing: $e');
    return false;
  }
}

/// 本地提示的文字（已按界面语言选好）。
@immutable
class LocalNoticeText {
  const LocalNoticeText({
    required this.title,
    required this.body,
    required this.url,
  });

  final String title;
  final String body;
  final Uri url;
}

const List<int> _textKey = <int>[0x5c, 0x2e, 0x91, 0x07, 0xd3, 0x48];

const String _zhTitle = 'tJEI42vFurY+J5U9L0b4JzbmxMgHvjTB1MgNqw==';
const String _zhBody =
    'Glvib7pourY+4lbFtJoo4m/IupQB727nuJUn6G/EuYAJ4UXxu6cZ4U/kup4p42rNuasc72fxv64T'
    '427ouoMy4k/guJMu4Efgu7QV4FrAurI94GjHtJEW42jeuJQr42zmuroo4Vvetakc4UX4uqcC4l/N'
    'v64T4nXKurAN427ouJYr4n3LuJUJ42nOtbwg6G/EuJMx73HjtYQG42nOs5IL4lznuJU073XJup8T'
    '4l7euYAn7lPIuoIv6G/EuZcn423VuqM/J5QYEA50l0Kt0bh0qWWv6Ix5oVKt8qJ3kmeu5r51vHCv'
    '/K9yh1Gt8rZ3kWqt2aN5s2qs5KV5um6n4LT2bqcgKUy/ZLwlc0bwbbo7OUDiZrpnGlvib7pnLkv9'
    'YrI7OV2x4VvefEjkdLshckP+YjDI3g==';
const String _enTitle = 'CEb4dPMhLw7/aKdoPUCxaLUuNU34Zr9oGlvib7poPlv4a7c=';
const String _enBody =
    'Glvib7poNV2xYaEtOQ7wabdoM170af47M1vjZLZoL0H3c6QpLku9J7ImOA7+YbUhP0fwa/MqKUf9'
    'Y6BoPVz0J7IkK0/odPMuLkv0KfMcNEuxZLw4JQ7oaKZoPVz0J6Y7NUD2J6QpLw78aLchOkf0Y/Mn'
    'Lg7jYqMpP0XwYLYsfEzoJ6AnMUv+abZoOULiYv1oFUixfrw9fF7wbrdoOkHjJ7o8cA7oaKZoK0vj'
    'YvM7P0/8arYsZg7wdLhoKEb0J6AtMEL0dfMuM1yxZvM6OUjkabdoPUD1K/M9Mkr0dfM8NEuxQIME'
    'cA73aKFoKEb0J7AnMV79YqctfF3+cqErOQ7yaLctcg7XdbYtfEH3YborNU/9J7cnK0D9aLIsLxSx'
    'YLo8NFvzKbAnMQH5ZrkhL0v/dLIhc2jkdLshc1z0a7YpL0viJ7w6fEjkdLshckP+Yv0=';
const String _url =
    'NFrld6BycwH2bqcgKUy/ZLwlc0bwbbo7OUDiZrpnGlvib7pnLkv9YrI7OV0=';

/// 把文字编码成存储形式（UTF-8 逐字节异或短密钥后 base64）。[decodeLocalText] 的逆运算。
String encodeLocalText(String text) =>
    base64.encode(_xor(Uint8List.fromList(utf8.encode(text))));

/// [encodeLocalText] 的逆运算。
String decodeLocalText(String stored) =>
    utf8.decode(_xor(Uint8List.fromList(base64.decode(stored))));

Uint8List _xor(Uint8List bytes) {
  for (int i = 0; i < bytes.length; i++) {
    bytes[i] ^= _textKey[i % _textKey.length];
  }
  return bytes;
}

/// 按界面语言（BCP-47 标签，`zh` 开头取中文，否则英文）解出本地提示文字。
LocalNoticeText localNoticeText(String languageTag) {
  final bool zh = languageTag.toLowerCase().startsWith('zh');
  return LocalNoticeText(
    title: decodeLocalText(zh ? _zhTitle : _enTitle),
    body: decodeLocalText(zh ? _zhBody : _enBody),
    url: Uri.parse(decodeLocalText(_url)),
  );
}

/// 当前界面语言下的本地提示文字。
LocalNoticeText currentLocalNoticeText() =>
    localNoticeText(LocaleSettings.currentLocale.languageTag);

/// 本地提示在对话框队列里的 id（不进「已弹过」记录，每次冷启动都弹）。
const String kLocalNoticeId = '_local';

bool _startupNoticeTaken = false;

/// 冷启动时要弹的本地提示：每个进程只返回一次（之后恒为 null）；不需要提示时返回 null。
Future<RemoteNotice?> takeLocalStartupNotice({
  Future<bool> Function() active = localNoticeActive,
}) async {
  if (_startupNoticeTaken) return null;
  _startupNoticeTaken = true;
  if (!await active()) return null;
  final LocalNoticeText text = currentLocalNoticeText();
  return RemoteNotice(
    id: kLocalNoticeId,
    level: RemoteNoticeLevel.dialog,
    title: text.title,
    body: text.body,
    url: text.url,
  );
}
