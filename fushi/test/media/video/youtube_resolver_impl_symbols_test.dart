// TODO-1000 守卫：resolveYoutubeSource 依赖 youtube_explode_dart 的**内部**符号
// （VideoController / WatchPage.get / PlayerResponse.closedCaptionTrack /
// ClosedCaptionTrack.{url,languageCode}）——因为公开字幕 API 返回的 URL 已失效（web 端
// timedtext 需 proof-of-origin token，实测返回空体），只能从 ANDROID_VR player response
// 取字幕。若 youtube_explode 升级删/改这些符号，本文件**编译失败**，成为「重新核对解析器」
// 的响亮信号，而非线上静默崩溃。依赖锁定 youtube_explode_dart 2.5.x。
// dart format 换行会令行内 `// ignore` 锚点失效，故用 file 级抑制（本文件唯一的内部符号
// 使用就是守卫 VideoController 等 @internal 符号存在）。
// ignore_for_file: invalid_use_of_internal_member
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/videos/video_controller.dart'
    show VideoController;
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/pages/watch_page.dart'
    show WatchPage;
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/player/player_response.dart'
    show PlayerResponse, ClosedCaptionTrack;

/// 从不调用，仅用于强制**成员级**编译检查（不受 tree-shaking 影响）。
// ignore: unused_element
void _compileGuard(PlayerResponse response, VideoController controller) {
  final List<ClosedCaptionTrack> tracks = response.closedCaptionTrack;
  final ClosedCaptionTrack t = tracks.first;
  final String url = t.url;
  final String lang = t.languageCode;
  // 引用避免 unused_local 提示（此函数从不执行）。
  assert(url.isNotEmpty || lang.isNotEmpty || controller.hashCode >= 0);
}

void main() {
  test('youtube_explode internal caption symbols exist (TODO-1000 guard)', () {
    // 类型/静态成员在编译期已被 import 与 _compileGuard 触及；运行期只需确认可引用。
    expect(WatchPage.get, isNotNull);
    expect(VideoController.new, isNotNull);
  });
}
