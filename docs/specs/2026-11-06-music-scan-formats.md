# 音乐扫描补格式：m4b 章节 / AC-3 / E-AC-3 / MPEG Layer II，纯音频判据与扫描器同表

反馈 QAondMh4M5 的后续项，叠在 #2977（纯音频改归音乐库）之上。用户拍板：「正常应该支持的就支持」。

## 问题（已核实）

「是不是纯音频」有两张表，彼此不一致：

- Dart `kAudioExtensions`（`packages/fushi_engine/lib/media/media_extensions.dart`）有 `.m4b` / `.ac3` / `.eac3`，
  音乐扫描器的 `AUDIO_EXTENSIONS`（`native/fushi_music/src/tags.rs`）没有这三个。#2977 里视频来源扫到的 `.m4b`
  被 `isAudioOnlyMediaPath` 分流出视频库（`source_library_scanner.dart` 的 `collectPureAudio` 分支），音乐扫描又不认，
  **新增文件两个库里都没有**；存量行因为「入库成功才删」留在视频库。
- 反过来 Rust 认 `oga/aifc/ape/wv/tak/tta/mpc/dsf/dff/mka/caf/w64/alac`，Dart 不认：视频来源里、或拖进视频页的
  这些文件被静默丢掉。

## 方案

- **一张表**：`kAudioExtensions` = Rust `AUDIO_EXTENSIONS` 去掉 `mp4`（`mp4` 首先是视频容器；音乐来源目录里的 mp4
  照收）。守卫 `fushi/test/build/music_audio_extensions_rust_parity_guard_test.dart` 读 `tags.rs` 文本钉死。判据仍只在
  `isAudioOnlyMediaPath` 一处。
- **新增格式**（Rust 胖核心，wire / FFI 不变）：
  - `.m4b`：lofty 按 MP4 读标签与属性；章节由 `mp4_chapters.rs` 读——QuickTime 章节轨优先（`tref/chap` → 文本轨，
    时间单位取**文本轨 `mdhd`** 的 timescale，样本位置 `stsc` + `stsz` + `stco`/`co64`，样本 `u16 长度 + 文本`，
    UTF-16 BOM 按 BOM 解，尾随 `encd` 等原子按长度截掉），没有再读 Nero `chpl`（100 ns）。
  - `.ac3` / `.eac3` / `.ec3`：`ac3.rs` 读同步帧头。AC-3 恒定码率查表算时长；E-AC-3 逐帧数，只数独立子流 0，
    7.1 的从属子流不会把时长算多。帧头对不上（伪装扩展名）如实报错。
  - `.mp2` / `.mpa`：lofty 归 MPEG，按 Layer 报 `mp1` / `mp2` / `mp3`。
- **m4b 两章以上拆成 CUE 同款虚拟曲目**（`cue_start_ms` / `cue_end_ms`，`scan.rs` 的 `embedded_split_tracks`）：书名作
  专辑，每章一首。播放端已有的 EDL 分段播放、CUE 列表渲染（MD3 / Apple 两套）直接覆盖，没有新 UI。**只拆 `.m4b`**：
  已在库的 `.m4a` 若也按章节拆，曲目 uid 会变、收藏与历史会断。
- **拖放**：`DroppedFiles.pureAudios` 在分类循环里按 `isAudioOnlyMediaPath` 填（命中即 matched，不落 unknown），不再
  从有声书表筛出来；书卡挂音频仍只看 `audios`（= 有声书表，just_audio 在 Android 上解不了 ape / dsf 等）。
- **外挂音轨**：表里加了 `.mka` 后，`Show/Audio/ep01.jpn.mka` 这类配音 / 评论音轨会被登记成常驻音乐来源。
  `music_audio_roots.dart` 规则 2b：视频所在目录的**直接子目录**里、文件名主干 = 视频主干或以「主干 + `.`」开头的
  音频不收；纯数字主干（`01.mkv`）不参与，避免误伤与剧集同号的专辑曲目。
- **存量迁移**：一个文件拆成多首后，播放记录落在断点所在那一首、收听时长按章内偏移折算；看完落最后一首
  （`pickMigratedTrack`）。逐曲断点本身的迁移归「音乐按曲断点续播」那一项（同一个 `_carryOverPlay`，本项只改
  「选哪一首 + 章内偏移」）。

## 与同批兄弟项的前提

- **ASR 字幕生成 / 按曲断点续播**：m4b 章节曲目与 FLAC + CUE 虚拟曲目是同一种记录（同路径、不同起止），这两项本来
  就要支持 CUE 分段（广播剧 CD 常是整轨 + CUE），所以按段转写 / 按段记断点即可，不需要为 m4b 另开分支。
- **标签写回**：`music_tag_writeback.dart` 拒绝写 CUE 虚拟曲目（一份文件一组标签，写一首会改到整本书）。m4b 拆章后
  同样不能按章写回——这不是回退：m4b 原来在视频库，本就没有音乐标签写回。

## 已知缺口

- iOS 解码未实测：音乐与视频共用 `media_kit_libs_video` 的 libmpv，视频库已在播 ac3 / eac3；ape / tta / wavpack / dsd /
  tak / wma 在 iOS libmpv 构建里是否齐全，要在 iOS 上读 mpv 的 `decoder-list` 确认，缺了只能换 libmpv 变体。
- 时长：lofty 认不出的 `wma` / `tak` / `tta` / `mka` / `caf` / `w64` 仍无时长（存量问题，本项只补 ac3 / eac3）。
- 裸 AC-3 / E-AC-3 无标签容器：标题取文件名，标签写回会被 lofty 拒绝并报错。
- 外挂音轨判据只认「同名主干」：子目录里命名与视频无关的配音轨仍会进音乐库；同一目录里既有外挂音轨又有别的音频时，
  该目录会被登记成音乐来源，外挂音轨随目录扫描入库。
