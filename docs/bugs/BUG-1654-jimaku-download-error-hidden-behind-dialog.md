## BUG-1654 · 下载失败提示被对话框盖住且没有原因
- **报告**：2026-08-15（用户实测，原话「下载失败报错在弹窗底下。而不是弹窗上面，而且没有详细信息」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/pages/implementations/jimaku_subtitle_dialog.dart`
  旧 `_snack()` 走 `ScaffoldMessenger.of(context).showSnackBar`
- **[x] ① 已修复** — commit `9bfe4cdd95`
- **[x] ② 已加自动化测试** — `fushi/test/pages/jimaku_search_identity_test.dart`
  「下载失败的原因显示在对话框内部，并带上 HTTP 状态码」
- **备注**：与 [BUG-1652] / [BUG-1653] 同一批用户实测反馈，同一个对话框。

### 根因

两个独立缺陷叠在一起：

1. **位置**：本对话框是全屏 modal，而 `ScaffoldMessenger` 的 SnackBar 挂在它**底下那层页面**的
   Scaffold 上，正好被对话框整个盖住。用户看到的就是「点了没反应」，失败原因一次都没露过面。
   受影响的不止下载失败——`video_jimaku_no_key`（没填 API key）走的是同一条路。
2. **内容**：`downloadFile` 默认 fail-open 吞成 `null`，调用点只弹一句写死的「下载失败」。
   key 过期（401）、被限流（429）、文件下架（404）在用户眼里长得一模一样，无从下手。

搜索路径同样吃这个亏：条目检索失败与「真的没有这部番」都被吞成空列表，用户只看到「没有找到字幕」，
于是继续换关键词瞎试——而真实原因可能是 key 过期，换多少次关键词都不会好。

### 修复

- 新增对话框内部的错误条（`ValueKey('jimaku-error-banner')`，errorContainer 底色，恒置顶于结果区），
  `_snack` 全部改为 `_showError`；
- 下载与条目检索都开 `throwOnError: true`，经新增纯函数 `describeJimakuFailure`
  （`jimaku_client.dart`）拼成「基础文案（HTTP <状态码>）」；拿不到状态码（DNS/超时/代理挂了）
  时原样返回基础文案，不编造细节；
- `listFiles` 保持 fail-open：某个条目列不出文件不该让其它条目的结果一起消失；
- 新增 i18n key `video_jimaku_search_failed`，让「搜索失败」与「真的没有字幕」在 UI 上可区分。
