## BUG-3817 · 删除动漫只删正片：特典与其余下载资源残留在目录
- **报告**：2026-10-25（用户反馈 fuQcFmZZxb，Windows：用 Fushi 下载的动漫会自动区分本体与特典，在 Fushi 里删除动漫后只删了本体，特典与其余资源仍留在目录里）
- **真实性**：✅ 真 bug（行号按基线 `4f66a48452`）。三处缺口叠加：
  1. **删除集合只有合集成员**：视频库删「一部动漫」= `fushi/lib/src/pages/implementations/home_video_page.dart` `onDeleteMembersMedia`（`:9363` 起）只把合集成员 uid 交给 `deleteVideoBooksWithDecision`（`fushi/lib/src/media/video/video_library_delete.dart:57`）。而特典**不是合集成员**：来源扫描把 `Extras/`、`SPs/`、NCOP 等附件也建成视频行、归组时排除（`fushi/lib/src/media/source_library/source_library_scanner.dart:1131-1135`），再由元数据索引器绑成作品的本地特典 `video_metadata_extras`（`packages/fushi_engine/lib/media/video/metadata/video_source_metadata_indexer.dart:133-165`）——作品页「特典」一栏就是它们。正片删完，特典行与特典文件原样留下。
  2. **下载任务停泊态不整删**：库删后的对账 `reconcileVideoDownloadJobsAfterLocalDelete`（`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:664-667`）只在 completed / cancelled / failed 时整删任务（连带删任务记过的附件、扫图 / CD / 字体等非视频资源）；`needsAttention`（文件已入库、刮削待确认或失败停在这里——同一台设备的另一条反馈 kg41f2PGdC 就是整理阶段 needsAttention）只把命中行标 skipped，非视频资源永远留在盘上。
  3. **空目录从不回收**：任务删除只删记录过的文件（同文件 `:544` 遇目录一律 `continue`），整理器建的 `<作品>/Season 01/`、`<作品>/Extras/…` 与种子原发布目录在文件删光后整棵空壳留在来源里。
  - 未拿到用户库快照，具体是哪一条（任务是否 needsAttention、特典是否已被索引器绑定）**未核实**；三处都是真实代码路径上的缺口，修复覆盖全部。
- **[x] ① 已修复** — 本条提交（分支 `worktree-agent-a31007b195567c055`，message 尾行 `Feedback: fuQcFmZZxb`）：
  - 新增 `packages/fushi_engine/lib/media/video/video_work_companions.dart` `videoWorkCompanionBookUids`：「整理产物 / 作品附属」的真相源有两份，都用上——(a) `video_metadata_works` + `video_metadata_extras(source_kind='local')`：电影作品 `book_uid` 在删除集合里、或剧集作品绑定合集的**每个**视频成员都在删除集合里时，返回它的本地特典行；(b) 下载任务文件行：任务记过的**每条** `kind: 'video'`（本作正片 + BUG-3816 的同包并列作品）落盘路径都是被删行的视频文件时，返回任务 `kind: 'extra'` 附件对应的库行（未被索引器绑定的特典也认得出）。只删部分集时一条不碰；并列作品还在库里时任务不算被整体删除。
  - `deleteVideoBooksWithDecision`（全部视频库删除入口的唯一落地）删前把这些附属行并入删除集合，走同一条链（行 + app 副本 + 勾了「同时删除本地文件」时连原件，仍受「幸存行引用」护栏保护）。`removeFromCollections: false`（只删配对设备下载来的本机副本）不扩。
  - 对账把 `needsAttention` 并入可整删的停泊态（`active` 仍绝不整删）；有流水线时走 `deleteJob`，它本就会先把非终态任务转 cancelled。
  - 新增 `pruneEmptyVideoDownloadDirectories`：任务删完文件后，自下而上删除这些文件所在、**已经变空**的目录（非递归 `Directory.delete()`，目录里还有任何东西就停手），只在任务的本机保存根之内动，根本身保留。用户自己放进作品目录的文件不属于任何任务记录，既不删、也让所在目录保留。
  - 取舍：没有在删除对话框里另列清单——删除集合扩展严格限定在「作品被整体删除」，与对话框「同时删除合集中的视频 / 本地文件」的语义一致。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_work_companion_delete_test.dart`（真实 SQLite + 临时目录）：整部剧集 / 电影删除返回本地特典、只删部分集不扩；下载任务视频全删时返回未绑定的 extra 附件行、任务仍有其它视频（并列作品）时不扩；UI 入口删整部剧集连特典行与特典文件一起删；只删本机副本不扩；needsAttention 任务视频删光后整删，扫图等非视频资源删除、`Season 01/` `Extras/` 与发布目录空壳回收、用户文件与来源根保留。
- **备注**：未真机复测（纯 DB / 文件系统行为，测试在真实 SQLite 与临时目录上跑）。没有下载任务记录（用户先在任务页「删除任务、保留文件」）且特典未被索引器绑定的作品，仍无归属依据可追溯——这是有意的：没有归属记录就不删用户目录里的文件。
