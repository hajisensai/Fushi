import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

const int kGoogleLensDisclosureVersion = 1;
const String kGoogleLensDisclosurePreferenceKey =
    'manga_google_lens_disclosure_version';

/// 视频画面 / 图片字幕上传同意的设备本地键（BUG-3342）。与漫画分开：漫画那份同意书
/// 说的是「漫画页面」，用户没同意过把视频画面发给 Google。
const String kVideoGoogleLensDisclosurePreferenceKey =
    'video_google_lens_disclosure_version';

typedef GoogleLensDisclosureGate = Future<bool> Function(BuildContext context);

/// 要上传给 Google Lens 的是什么。决定同意框文案与同意记录的键。
enum GoogleLensDisclosureScene {
  /// 漫画页面（漫画阅读 / 在线直读 / 整卷 OCR）。
  mangaPages(kGoogleLensDisclosurePreferenceKey),

  /// 视频画面（暂停帧识别、图片字幕整轨转文字）。
  videoFrames(kVideoGoogleLensDisclosurePreferenceKey);

  const GoogleLensDisclosureScene(this.preferenceKey);

  /// 同意记录（版本号）存在 SharedPreferences 的键。
  final String preferenceKey;

  String get title => switch (this) {
    GoogleLensDisclosureScene.mangaPages =>
      t.manga_google_lens_disclosure_title,
    GoogleLensDisclosureScene.videoFrames =>
      t.video_google_lens_disclosure_title,
  };

  String get body => switch (this) {
    GoogleLensDisclosureScene.mangaPages => t.manga_google_lens_disclosure_body,
    GoogleLensDisclosureScene.videoFrames =>
      t.video_google_lens_disclosure_body,
  };
}

/// 本设备是否已同意把 [scene] 的内容上传给 Google Lens（当前版本的同意书）。
Future<bool> hasGoogleLensDisclosure({
  GoogleLensDisclosureScene scene = GoogleLensDisclosureScene.mangaPages,
}) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return preferences.getInt(scene.preferenceKey) ==
      kGoogleLensDisclosureVersion;
}

/// 记下本设备对 [scene] 当前版本同意书的同意——与同意框点「同意」写同一个键同一个
/// 值。桌面控制通道 `ocr start --consent-upload` 是用户在命令行里显式表态。
Future<void> recordGoogleLensDisclosureAccepted({
  GoogleLensDisclosureScene scene = GoogleLensDisclosureScene.mangaPages,
}) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.setInt(scene.preferenceKey, kGoogleLensDisclosureVersion);
}

/// Device-local, versioned privacy gate for full-page Google Lens OCR.
///
/// SharedPreferences is intentional: Drift preferences participate in profile
/// snapshots and backup/sync, while consent must be collected independently on
/// every device that uploads page images.
///
/// [scene] 决定文案与同意记录：视频调用方必须传 [GoogleLensDisclosureScene.videoFrames]，
/// 否则用户看到的是「将漫画页面发送到 Google Lens？」（BUG-3342）。
Future<bool> ensureGoogleLensDisclosure(
  BuildContext context, {
  GoogleLensDisclosureScene scene = GoogleLensDisclosureScene.mangaPages,
}) async {
  if (await hasGoogleLensDisclosure(scene: scene)) return true;
  if (!context.mounted) {
    return false;
  }
  final bool accepted = await showFushiConfirmDialog(
    context: context,
    title: scene.title,
    message: scene.body,
    icon: FushiIcons.cloudUpload,
    cancelLabel: t.manga_google_lens_disclosure_decline,
    confirmLabel: t.manga_google_lens_disclosure_accept,
  );
  if (!accepted) {
    return false;
  }
  await recordGoogleLensDisclosureAccepted(scene: scene);
  return true;
}
