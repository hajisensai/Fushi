## BUG-1293 · Mihon 在线漫画 OCR 横竖排错位且加载缓存调度未对齐 Niratan
- **报告**：2026-07-29（用户）
- **真实性**：✅ 真 bug。`manga_hibiki_page.dart` 给未知在线页统一写死
  `1000×1400`，而 `manga_overlay_html.dart` 用该尺寸决定页容器比例和 OCR 百分比映射；
  `google_lens_protocol.dart` 又按 rotation 正负号切字符，`-90°` 竖排的字符命中顺序
  会翻转。在线页会话只有关闭即删除的 256 MiB 临时缓存，OCR 启动前还会串行下载
  整章，与 Niratan 的两级持久缓存、邻页预取和当前页优先逐页识别均不一致。
- **[x] ① 已修复** — 页图解码后把 EXIF 烘焙尺寸同步到 Flutter payload 与 WebView
  容器；字符命中按 Niratan 的最终视觉方向固定为横排左到右、竖排上到下，同时保留
  Hibiki 已验证的非方形页旋转宽高比修正。在线页改为 96 MiB 内存 LRU +
  1 GiB/1024 文件磁盘 LRU、稳定来源身份、请求去重、4 路有界预取和精确取消；
  Lens 限制单主机 2 连接。在线 OCR 保留 24 页内存 LRU，并把预览与入架章节映射到
  同一份稳定磁盘缓存；来源返回的页身份发生变化时会先淘汰旧 OCR，避免错套文本层。
  识别从当前页扫到末页再绕回首页，图片获取最多 3 次并按 350/700 ms 退避，每页
  识别后立即原子缓存和热更新，不再预下载整章。
- **[x] ② 已加自动化测试** —
  `google_lens_protocol_test.dart` 覆盖横排、正/负 90° 竖排和非方形页；
  `manga_page_provider_test.dart` 覆盖横版/竖版真实尺寸、跨会话缓存和 4 路并发上限；
  `manga_overlay_html_test.dart` 守卫 natural size 动态布局；
  `mihon_online_ocr_test.dart` 覆盖当前页优先、重试退避、逐页缓存及重开零上传。
- **[x] ③ Windows 真章节验收** — Debug 包实际打开 Raw Otaku 的 17 页章节并完成
  Google Lens OCR：17/17 页图片与最终 JSON 的真实尺寸逐页一致（`1403×2048` 或
  `1370×2000`），横排和竖排块均有产出；全量检查所有块及字符区域，越界/倒置为 0。
  逐页缓存按约 8–10 秒节奏串行落盘，最终图片清单和 OCR 页缓存均为 17 页，未留下
  `.tmp`/`.part` 文件；全局页图缓存使用稳定散列文件，实测约 18 MiB。
- **备注**：实现以 `W1ght/Niratan` v1.5.1 的行为契约作 clean-room 参考，没有复制
  GPL-3.0 源码。
