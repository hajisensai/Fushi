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
  共用该解析器。`910bfa9c0`：在
  `hibiki/lib/src/media/metadata/image_download.dart:34` 建立 100 秒统一原图下载截止时间，
  书籍直接复用，视频 `cover_downloader.dart:32,59` 也改用同一默认值；仍保持有界等待，
  且继续原样保存响应字节，不做二次压缩。
- **[x] ② 已加自动化测试** — `37abb62af`：
  `hibiki/test/media/metadata/bangumi_cover_url_test.dart:15-41` 覆盖 `/r/<size>/` 与
  `common/medium/small/grid` 恢复原图；三个领域映射测试守住统一入口。`910bfa9c0`：
  `hibiki/test/media/metadata/image_download_test.dart:11` 守住 100 秒共享默认值，
  `hibiki/test/media/video/scraper/cover_downloader_test.dart:28,128` 守住视频侧复用默认值及
  超时失败不落盘。12 个相关源码/测试文件定向 `dart analyze` 通过；按用户要求未等待
  Flutter 编译或测试套件。
- **备注**：实现策略对齐 Jellyfin：下载来源提供的原图字节并原样保存，展示层再按卡槽
  需要降采样；因此不移除 Hibiki 既有 720 物理像素卡片解码上限，避免把原图整帧塞进
  Flutter ImageCache。外部源主动断连/Windows `errno=121` 仍可能早于应用截止时间失败，
  本修复不把所有网络错误伪装成“延长时间即可解决”。
