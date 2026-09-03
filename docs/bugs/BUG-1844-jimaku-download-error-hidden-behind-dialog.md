## BUG-1844 · 下载失败提示被对话框盖住且没有原因
- **报告**：2026-08-15（用户实测，原话「下载失败报错在弹窗底下。而不是弹窗上面，而且没有详细信息」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/pages/implementations/jimaku_subtitle_dialog.dart`
  旧 `_snack()` 走 `ScaffoldMessenger.of(context).showSnackBar`；两处「下载失败」都是写死文案
- **[x] ① 已修复** — 见本轮提交
- **[x] ② 已加自动化测试** — `fushi/test/pages/jimaku_search_identity_test.dart` 的
  「BUG-1844 失败原因可见」组（3 例）
- **备注**：与 [BUG-1842] / [BUG-1843] / [BUG-1847] 同一批用户实测反馈，同一个对话框。

### 根因

三个独立缺陷叠在一起：

1. **位置**：本对话框是全屏 modal，而 `ScaffoldMessenger` 的 SnackBar 挂在它**底下那层页面**的
   Scaffold 上，正好被对话框整个盖住。用户看到的就是「点了没反应」，失败原因一次都没露过面。
   受影响的不止下载失败——`video_jimaku_no_key`（没配来源）走的是同一条路。
2. **内容**：`_downloadSource` 的两个失败出口都只弹一句写死的「下载失败」。
   key 过期（401）、被限流（429）、文件下架（404）在用户眼里长得一模一样，无从下手——而
   `ExternalProviderFailure` 早就把 `statusCode` 归一好了，UI 一路把它丢掉。
3. **搜索失败被吞成「没有字幕」**：`_fetchCandidates` 拿到 `ProviderBatchResult` 后只用
   `result.items`，`result.failures` **一次都没被读过**。所有来源都挂了与「真的没有这部番的
   字幕」在界面上完全同形，用户只会继续换关键词瞎试——而真实原因可能是 key 过期，换多少次
   关键词都不会好。

### 修复：把三种「要说给用户听的话」合成一套呈现

对话框内部只有**一条**提示条（`kSubtitleNoticeBannerKey`，errorContainer 底色，恒置顶于结果
区），一个 `_noticeBanner` 实现，按优先级挑内容：

1. `_error`（硬失败：搜索 / 下载失败、没有可用来源）——带 HTTP 状态码，无重试按钮；
2. `_seriesLookupFailed`（BUG-1782 的 AniList 降级说明）——带「重试」。

`_snack` 整个删掉，三处调用点全部改为 `_showError`。此前是「一种失败走 SnackBar、一种降级自绘
一行 Row」两套并存，现在只有一份。

状态码拼装走 i18n key `video_subtitle_error_with_code`（`${msg} (HTTP ${code})` / 中文用全角
括号），**不在数据层写死括号**——括号形态是语言相关的，硬编码等于让英文界面也吃到全角括号。
拿不到状态码（DNS / 超时 / 代理挂了）时原样返回基础文案，不编造细节。

零候选**且**有 provider 级失败时，文案用新增的 `video_jimaku_search_failed`，与
「没有找到字幕」区分开。

### 变异实测

把下载失败出口的 `describeSubtitleFailure(...)` 换回裸 `t.video_jimaku_download_failed`
→ 「下载失败的原因显示在对话框内部，并带上 HTTP 状态码」转红；还原后文件 sha256 与变异前一致。
