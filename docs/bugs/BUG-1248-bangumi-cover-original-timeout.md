## BUG-1248 · Bangumi封面退化图落盘且原图下载30秒超时
- **报告**：2026-07-29（用户：自动刮削封面观感模糊，并反馈弱网下封面应用失败）
- **真实性**：✅ 真 bug（含一项现场排除）。截图失败 URL
  `https://lain.bgm.tv/pic/cover/l/2c/af/520842_J06fL.jpg` 实测下载为
  350476 字节、1938×2744 JPEG，说明该条 `/l/` 本身已是来源原图，且落盘层不重编码，
  不是这张图的清晰度瓶颈；但旧映射在 `images.large` 缺失时会直接采用
  `common/medium/small` 或搜索响应的 `image` 派生尺寸并永久落盘：
  `hibiki/lib/src/media/video/scraper/bangumi_client.dart:294`、
  `hibiki/lib/src/media/metadata/book_metadata_scraper.dart:182`。此外视频与书籍下载器各自
  写死 30 秒整体截止时间；高分辨率原图在弱网/代理链路下更容易在传输完成前被应用层取消。
- **[x] ① 已修复** — `37abb62af`：新增统一 Bangumi URL 解析器
  `hibiki/lib/src/media/metadata/bangumi_cover_url.dart:14-51`，按
  `large → common → medium → small → grid` 选择可用地址后，去掉 `/r/<size>/`
  缩放层并把旧式 `c/m/s/g` 路径恢复到 `/pic/cover/l/`；视频、书籍、游戏三个刮削入口
  共用该解析器。`36c9adbb5`：在
  `hibiki/lib/src/media/metadata/image_download.dart:34` 建立 100 秒统一原图下载截止时间，
  书籍直接复用，视频 `cover_downloader.dart` 也改用同一默认值；仍保持有界等待，
  且继续原样保存响应字节，不做二次压缩。同一提交修掉截止时间**不生效于底层传输**
  的真根因：旧写法只对等待 Future 加 `.timeout()`，截止后调用方拿到
  `TimeoutException`，但源 HTTP 请求与响应流仍在后台继续下载。改为共享
  `fetchCoverImageResponse`（`image_download.dart:42-64`），用
  `http.AbortableRequest` 在截止回调里先 abort 底层请求/响应流再抛超时；
  视频侧保留 BUG-1272 的传输重试，每次尝试都走该 helper，重放不再堆积仍在下载的
  孤儿连接。client 本身不关闭，调用方注入 client 的所有权不变。
- **[x] ② 已加自动化测试** — `37abb62af`：
  `hibiki/test/media/metadata/bangumi_cover_url_test.dart:15-41` 覆盖 `/r/<size>/` 与
  `common/medium/small/grid` 恢复原图；三个领域映射测试守住统一入口。`36c9adbb5`：
  `hibiki/test/media/metadata/image_download_test.dart` 守住 100 秒共享默认值，并用
  挂住 body stream 的假 client 断言「截止时 abort 已触发、不落半成品文件」；
  `hibiki/test/media/video/scraper/cover_downloader_test.dart` 守住视频侧复用默认值、
  超时取消底层响应流且不覆盖旧封面 / 不留 `.tmp`。仅让 Future 超时（不 abort）、
  把 100 秒改回 30 秒、视频侧写死 30 秒、忽略注入的 timeout 四类变异均能让上述断言变红。
  定向 19/19 通过 + 全量 `flutter analyze` 无 issue。
- **备注**：实现策略对齐 Jellyfin：下载来源提供的原图字节并原样保存，展示层再按卡槽
  需要降采样；因此不移除 Hibiki 既有 720 物理像素卡片解码上限，避免把原图整帧塞进
  Flutter ImageCache。外部源主动断连/Windows `errno=121` 仍可能早于应用截止时间失败，
  本修复不把所有网络错误伪装成“延长时间即可解决”。
