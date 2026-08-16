## BUG-1679 · 换音频后沿用旧时间轴的播放进度导致不响/乱跳页
- **报告**：2026-08-16（用户转述：「偶尔能响的那几次，它会随机把我正在看的页面换掉」）
- **真实性**：✅ 真 bug
  - 进度 pref 的键是 `audiobook_pos_<bookKey>`（`packages/fushi_audio/lib/src/audiobook/audiobook_repository.dart:96`），
    值是**毫秒偏移**——它只在当初绑定的那一套音频上有意义。
  - 换音频的两条写入路径都不碰它：`AudiobookImportDialog._doImport`（经
    `AudiobookRepository.saveAudiobook`）与 `SrtBookRepository.replaceAudio`
    （`srt_book_repository.dart:176`）。`ReaderFushiSource` 侧的删书
    （`reader_fushi_source.dart:863` → `FushiDatabase.deleteEpubBook`）也只删表行，
    不删 `preferences`；而 `bookKey` 是 sanitize 后的书名（`epub_importer.dart:141`），
    删书重导拿到同一个 key，上一世的进度会原样复活。
  - 恢复点在 `packages/fushi_audio/lib/src/audiobook/audiobook_controller.dart:712`：
    `setAudioSource(..., preload: false)` 之后无条件 `await _player.seek(Duration(milliseconds: savedMs))`，
    没有任何按新音频时长的钳制（`preload: false` 时此刻也拿不到时长）。于是：
    - **位置超出新音频总时长** → seek 被平台钳到末尾，播放器停在 EOF，按播放立刻结束
      ——用户看到的是「音频不响」；
    - **位置落在新时长内** → 起播点随机，`_updateCurrentCue` 解析出该位置的 cue，
      followAudio 立刻把阅读器拽到那条 cue 所在的页（`_restoreFromCurrentAudioCue`
      / `audiobook.part.dart`）——用户看到的是「乱跳页」。
- **[x] ① 已修复** — 在**音频集合真的变了**时把进度归零（判据是数据本身，不是「谁在调」，
  所以只回写 health / 只换字幕的保存不会误伤听到哪儿了）：
  - `AudiobookRepository.replaceAudio`：写入前读旧行，`AudiobookStorage.sameAudioPathList`
    + `audioRoot` 比对；变了（含旧行不存在＝重建行，防上一世进度复活）就
    `updatePositionMs(positionMs: 0)`（连带写新时间戳，互联 LWW 能把这次作废传出去）。
  - `SrtBookRepository.replaceAudio`：同判据，键用 `uid`（与
    `AudiobookSessionLauncher._readPrefs` 的 SRT 分支同源）。
  - **归零挂在「换音频」这个动作上，而不是挂在某次保存上**：BUG-1678 的结构性修复
    把有声书写入拆成了四个窄动作，换音频只有 `replaceAudio` 这一个入口，绕不过去。
    第一版把判定塞在整行 `saveAudiobook` 里——那要求「凡是换了音频的路径都得记得
    调那个保存」，仍是纪律；现在是「想换音频只能调它」，是结构。
  - 提交：`fix(audiobook): stop re-import from wiping existing audio`（第一版）
    + `refactor(audiobook): 让「清空没碰的列」在结构上写不出来`（收口到窄动作）。
- **[x] ② 已加自动化测试** —
  `packages/fushi_audio/test/audiobook/audiobook_reimport_audio_survival_test.dart`
  四条：换音频 → 归零；喂同一组音频 → 进度纹丝不动；`replaceAlignment` / `writeHealth`
  从不碰进度；SRT 书 `replaceAudio` 同一组不动、换一组归零。变异实测让对应用例变红，
  还原后 sha256 校验一致。
- **备注**：与 [BUG-1678](BUG-1678-audiobook-reimport-wipes-existing-audio.md) 是同一条用户报告的两半。
  **未做**：`AudiobookController.load` 仍不按真实时长钳制恢复 seek。那是症状层的兜底，
  且 `preload: false` 下此刻拿不到时长，硬做要么强制预加载（拖慢开书）要么额外探测一次时长；
  根因（进度与音频集合脱钩）已在写入侧修掉，钳制留作后续可选加固。
