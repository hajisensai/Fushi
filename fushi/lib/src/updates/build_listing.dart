// 本地构建提示：不联网，按 build_info.dart 读到的签名证书摘要（h / k）判断本构建是否在
// 发布方登记的构建之列，不在时弹一次本地提示（同一组签名摘要只弹一次，记在服务端通知同一份
// 「已弹过」记录里，见 [localNoticeIdFor]），并让设置 · 关于里的「免费与开源声明」页多显示
// 一行。提示是条件式措辞：自己编译、免费分支同样会看到，所以只说「付了钱就是被骗了」。
//
// 判据（[localNoticeApplies]）：
//   - h ∪ k 非空且其中没有任何一个摘要是登记过的；或
//   - h、k 都非空却没有共同摘要（两个来源互相对不上）。
// h、k 都为空（非 Android、读取失败）一律不提示，宁可漏也不误报。只在 Android release 构建生效。
//
// 登记的摘要只存加盐后的 SHA-256（[kListedDigestHashes]），源码里搜不到官方证书指纹；
// 提示文字走 i18n（`notice_unofficial_build_*`），17 种语言都有译文。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/updates/build_info.dart';
import 'package:fushi/src/updates/notice_feed.dart';
import 'package:fushi/src/utils/misc/official_links.dart';

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

/// 本地提示在对话框队列里的 id 前缀；完整 id 见 [localNoticeIdFor]。
const String kLocalNoticeIdPrefix = '_local:';

/// 纯函数：一组签名摘要对应的本地提示 id。同一组摘要（不分大小写、顺序）恒得同一个 id，
/// 换了签名就是新 id，会再弹一次。
String localNoticeIdFor(List<String> h, List<String> k) {
  final List<String> digests = <String>{
    ...h,
    ...k,
  }.map((String d) => d.toLowerCase()).toSet().toList()..sort();
  final String hash = sha256
      .convert(utf8.encode('$_salt${digests.join(',')}'))
      .toString();
  return '$kLocalNoticeIdPrefix${hash.substring(0, 16)}';
}

Future<String?>? _cachedId;

/// 本进程要显示本地提示时返回它的 id（[localNoticeIdFor]），否则 null：只在 Android release
/// 构建上读 [readBuildInfo] 判断；永不抛，按进程缓存。
Future<String?> localNoticeId() => _cachedId ??= _resolveId();

/// 本进程是否要显示本地提示（[localNoticeId] 非 null）。
Future<bool> localNoticeActive() async => await localNoticeId() != null;

Future<String?> _resolveId() async {
  if (!kReleaseMode || !Platform.isAndroid) return null;
  try {
    final BuildInfo info = await readBuildInfo();
    return localNoticeApplies(info.h, info.k)
        ? localNoticeIdFor(info.h, info.k)
        : null;
  } on Object catch (e) {
    debugPrint('BuildListing: $e');
    return null;
  }
}

/// 本地提示的文字（当前界面语言）。
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

/// 当前界面语言下的本地提示文字。
LocalNoticeText currentLocalNoticeText() => LocalNoticeText(
  title: t.notice_unofficial_build_title,
  body: t.notice_unofficial_build_body,
  url: Uri.parse(kOfficialReleasesUrl),
);

bool _startupNoticeTaken = false;

/// 冷启动时要弹的本地提示：每个进程只返回一次（之后恒为 null）；不需要提示时返回 null。
/// 是否已经对这组签名摘要弹过由 [NoticeLayer] 按 id 查「已弹过」记录决定。
Future<RemoteNotice?> takeLocalStartupNotice({
  Future<String?> Function() id = localNoticeId,
}) async {
  if (_startupNoticeTaken) return null;
  _startupNoticeTaken = true;
  final String? noticeId = await id();
  if (noticeId == null) return null;
  final LocalNoticeText text = currentLocalNoticeText();
  return RemoteNotice(
    id: noticeId,
    level: RemoteNoticeLevel.dialog,
    title: text.title,
    body: text.body,
    url: text.url,
  );
}
