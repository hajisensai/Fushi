## BUG-1506 · 视频横滑 seek 守卫锚点在 BUG-1485 后失效
- **报告**：2026-08-11（用户：integration owner，合并 develop 时实测）
- **真实性**：✅ 真 bug（守卫自身塌掉，develop 恒红）。根因 `fushi/test/media/video/video_drag_gesture_test.dart:59`（旧行号）——用例
  `enables horizontal seek-drag gesture with absolute-time HUD (TODO-916)` 里
  `expect(videoPage.contains('horizontalGestureSensitivity:'), isTrue)` 钉的是 fork
  内建的比例制灵敏度具名参数。BUG-1485 把移动控制条的像素→时间换算入口换成了
  Hibiki 侧注入的 `horizontalSeekResolver` + `VideoHorizontalSeekGesture.resolveDelta(...)`
  （`fushi/lib/src/pages/implementations/video_fushi/controls_theme.part.dart:197` 起），
  fork 的 `horizontalGestureSensitivity` 在 resolver 在场时根本不再被读、也不再传，
  于是该断言恒假。BUG-1485 那轮只更新了同域的专项测试
  `fushi/test/pages/video_horizontal_seek_test.dart`，漏了这条跨域守卫；合并时只跑了
  被点名的文件，红就随合并进了 develop。
- **[x] ① 已修复** — 把过期锚点换成跟住真实契约的三条断言（`fushi/test/media/video/video_drag_gesture_test.dart`）：
  ① `horizontalSeekResolver:` 必须在；② `VideoHorizontalSeekGesture.resolveDelta(`
  必须在（只有字段名不算接线，钉住它真的接到了可单测的 Hibiki 侧纯函数）；
  ③ `horizontalGestureSensitivity:`（**带冒号**的具名参数形态）必须不在——否则有人
  把换算改回按视频总时长比例（BUG-1485 的「一拽就起飞」根因）会静默通过。
  三条都走 `containsCodeLine`（剥注释）而不是裸 `contains`：本文件读的是合并语料
  `readVideoFushiSource()`（主壳 + `video_fushi/*.part.dart`），而
  `video_fushi_page.dart:872` 的解释性注释里就写着 `horizontalGestureSensitivity`，
  裸 `contains` + 不带冒号会让第 ③ 条凭空判红。修的是守卫，不是产品行为；
  `controls_theme.part.dart` 一个字节没动。
- **[x] ② 已加自动化测试** — 改的就是守卫本身，做了四轮变异实测（还原一律用反向
  Edit，未对未提交文件用 `git checkout --`）：
  - 基线（当前源码原样）：`PASSED - 10 tests ran` ⇒ 假绿检查通过，注释里现存的
    `horizontalGestureSensitivity` 写法不会让第 ③ 条误红。
  - 正向变异：`controls_theme.part.dart` 的 `horizontalSeekResolver:` 改名 ⇒ 红
    （「横滑换算必须经 Hibiki 侧 resolver 注入」）。
  - 接线变异：`VideoHorizontalSeekGesture.resolveDelta(` 换成别的调用 ⇒ 红
    （「resolver 必须真接到纯函数」）。
  - 反向变异：加回真的 `horizontalGestureSensitivity: 1000,` 具名参数 ⇒ 红
    （「改回按视频总时长比例换算即回归」）。
  测试文件：`fushi/test/media/video/video_drag_gesture_test.dart`。
- **备注**：普查了 BUG-1485 那轮的全部改动符号（`horizontalSeekResolver` /
  `HorizontalSeekResolver` / `VideoHorizontalSeekGesture` / `swipeDuration` /
  `seekGesture` / `_videoHorizontalGestureSensitivity` / `dragSeekSensitivity`）在
  `fushi/test/` 与 `fushi/integration_test/` 的引用面，除本条外没有第二条同形态的
  过期锚点：`video_horizontal_seek_test.dart` 里剩余的 `horizontalGestureSensitivity`
  引用都是**禁止型**（桌面 theme / 移动 theme 各一条 `isFalse`），BUG-1485 之后仍然成立。
