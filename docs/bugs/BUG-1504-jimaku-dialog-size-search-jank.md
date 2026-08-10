## BUG-1504 · Jimaku 字幕框偏小且搜索首帧卡顿
- **报告**：2026-08-11（用户：Wight）
- **真实性**：✅ 真 bug。`jimaku_subtitle_dialog.dart` 把桌面对话框硬限制为 720dp、左栏仅 252dp；`_search` 又在设置 `_searching` 之前先等待 API key 持久化，慢磁盘/数据库下按钮与 loading 首帧无法及时绘制，表现为点击后 UI 卡一下。
- **[x] ① 已修复** — `f5945cfacc`：桌面对话框扩大至 1040dp / 92% 屏高、左栏 300dp；搜索与系列切换在重工作前等待 busy 状态完成一帧绘制。
- **[x] ② 已加自动化测试** — `jimaku_two_pane_layout_test.dart` 守卫桌面框宽度大于 900dp，并静态锁定 `_searching → endOfFrame → 持久化 → client` 的执行顺序。按用户先前要求未运行自动化测试。
- **备注**：Windows Debug 构建成功并已启动；重启后应用回到首页，未复用先前视频/Jimaku 状态执行联网交互。自动化测试按用户要求未运行。
