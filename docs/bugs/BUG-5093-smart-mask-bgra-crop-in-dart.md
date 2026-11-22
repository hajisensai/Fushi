## BUG-5093 · 智能遮布：截帧 BGRA→RGBA 裁块逐像素留在 Dart（HBK-AUDIT-008）
- **报告**：2026-11-22（外部审计 Codex 2026-11-21 PR 审查 HBK-AUDIT-008，来源 PR #3842）
- **真实性**：✅ 成立（架构违规；性能影响小）。`fushi/lib/src/media/video/raw_video_frame.dart:153-191`（修前）在截帧 isolate 上用 Dart 逐像素循环做 BGRA→RGBA 并裁块；智能遮布播放中最短每 250 ms（`smart_subtitle_mask_sampler.dart:25`）抽一次，暂停 OCR 每次整帧也走它。#3842 是新功能，按 CLAUDE.md「Rust 胖核心」新计算型热路径应在 `native/fushi_*`。实测（AOT，见下）修前 1080p 遮布区域每次约 0.8～0.9 ms，占 250 ms 采样周期 <0.4%，审计「性能热点」的分量不大，主要是架构归属。
- **[x] ① 已修复** — 新增就地内核 `ffc_image_bgra_to_rgba8_inplace`（`native/fushi_compute/src/image.rs`：h 行、行跨度 stride，每行前移到紧排位置并换通道、alpha 置 255）与 Dart 绑定 `FushiComputeImage.bgraToRgba8`（矩形覆盖的那段行一次 memmove 进暂存区，就地调用，结果带可选字节头拷回 Dart 堆；只用一块暂存区，因为截帧 isolate 每次新建，多一块缓冲就多一轮缺页）。`raw_video_frame.dart` 只算裁剪矩形与 24 字节头，Dart 逐像素循环删除、不留回退。media_kit 补丁接口不变（transform 仍拿 mpv 缓冲视图）。提交 `8ab39ffa92` / `3204b4e470` / `0d27a1fea0`。
- **[x] ② 已加自动化测试** — Rust `image::tests::bgra_to_rgba8_inplace_*`（stride 填充、多种矩形含整帧 / 单像素、alpha 强制 255、越界 / 短缓冲 / 空矩形 / 空指针）；Dart `packages/fushi_compute/test/image_bgra_to_rgba_test.dart`（与迁移前 Dart 循环逐字节对照：4 种帧含非 4 倍数 stride、每帧 25 个随机矩形；原生缓冲视图 + 字节头；参数校验）；`fushi/test/media/video/smart_subtitle_mask_test.dart` 原有裁块 / stride 用例走新路径。变异实测：Rust 内核忽略 stride → `cargo test` 红（exit 101）；Dart 绑定把 stride 传成紧排 → 对照测试 2 条红（exit 1）。
- **耗时对比**（`packages/fushi_compute/benchmark/bgra_to_rgba_bench.dart`，AOT，Windows x64 本机，源帧在原生内存、stride +64 B，中位数 ms；「新 isolate」= 真实路径，每次截帧新建 isolate，含原生库加载与绑定约 0.15 ms）：

  | 场景 | 修前 Dart 热 | Rust 热 | 修前 Dart 新 isolate | Rust 新 isolate |
  |---|---|---|---|---|
  | 1080p 遮布区域 1536×238 | 0.82 | 0.59 | 0.89 | 1.11 |
  | 4K 遮布区域 3072×476 | 3.33 | 2.17 | 3.34 | 3.17 |
  | 1080p 整帧（暂停 OCR） | 4.46 | 2.78 | 4.33 | 4.03 |
  | 4K 整帧 | 17.92 | 11.99 | 18.62 | 16.36 |

  热循环快 1.4～1.6 倍；真实路径（每次新 isolate）上大块持平或略快，1080p 遮布区域慢约 0.2 ms（库加载 + 绑定 + 暂存区缺页），相对 250 ms 采样周期与 OCR 本身可以忽略。
- **备注**：未做真机复测（本轮约定不做真机）。剩余可做的（未做，登记于此）：① media_kit 补丁把 mpv 节点缓冲的原生指针直接交给 transform，可省掉一次 memmove（改补丁签名会让本机共用 pub cache 的其它工作区编不过，需随 develop 统一切换）；② 截帧 isolate 常驻（而不是每次 `compute` 新建），可省库加载与缺页；③ OCR 直接在原生侧消费 ROI，免回 Dart 堆。三者对每次采样的收益都在 1 ms 以内。
