## BUG-2161 · MDX 松散资源两条上限缺口：img src 只扫前 50 条词条、zip 全取无总量上限
- **报告**：2026-09-06（PR#1220 合入后的代码审查发现，非用户报告）
- **真实性**：✅ 真 bug（静态推导，未构造样本复现）。两条都是 BUG-2147「MDX 松散兄弟资源进 media store」放宽白名单后新暴露的面，随 PR#1220 一起进了 develop（`d9cb441bce`）。

### ① `<img src>` 收集沿用 `kCssScanEntryLimit = 50`，但 `<img>` 不是 per-entry 样板
根因：`native/fushidicts/fushidicts_src/importer.cpp:1281`（`extract_img_src_names`）+ 调用点 `:1418`。

`extract_referenced_names` 只扫前 50 条词条，原注释给的理由是「`<link>`/`<script>` 是每条词条都重复的样板」——这个前提对 `<img src>` **不成立**：图片是内容相关的，一本 10 万条的词典里没有发音的词条（多词条目、变位形）就没有 `<img>`。

失败场景：一本词典前 50 条恰好都是不带发音的词条（按 headword 排序时 `'`、数字、缩写开头的条目常常如此），`sound.png` 一样收不进 store，用户看到的仍是 0×0 破图——BUG-2147 的原始症状换本词典原样复发，而现有测试发现不了（新测试只有一条词条）。样式表 `url()` 那一路没有这个问题（扫的是整份 CSS）。

顺带一个更窄的：`ci_find(tag, "src", 0)` 会先命中 `srcset` / `data-src` 里的 `src` 子串然后 `continue` 到下一个 `<img>`，同一标签里真正的 `src=` 就被跳过。这个弱点 `<link href>`/`<script src>` 时代就在，但 `<img srcset>` 比 `href` 撞名常见得多。

方向：`<img>` 这一路把 scan_limit 抬高一个量级或直接扫全表（`extract_referenced_names` 已在 dedup，成本是一次线性扫描）；加一条「图片只出现在第 N>50 条词条上」的负样本用例。

### ② zip 抽取白名单放宽后只有**单文件**上限，没有总量/条数上限
根因：`native/fushidicts/fushidicts_src/importer.cpp:1200`（`kMaxLooseSiblingBytes`）+ `:1520`。

注释写的是「the cap only exists so a crafted archive cannot use the "take every sibling" rule to fill the temp dir」，但 `zip.entries[i].uncompressed_size <= 64 MiB` 是**逐文件**判据。

失败场景：一个含 5000 个各 50 MiB 条目的 zip（现实里更常见的形态：把三四本词典 + 一整套 `res/` 图片打在一起的合集包），旧规则只取 `.css`/`.js` 时不会碰它们，新规则会把它们全部落到 `output_dir/_mdx_temp`。用户侧表现是导入一本词典时磁盘被写满 / 导入极慢，而 `import_mdx` 最后一个都用不上（`remove_all` 在 `import_mdx` 之后才跑，撑爆是先发生的）。

次级点：非 zip 路径（直接选 `.mdx`）的 `read_file_text(dir / name)` 一点上限都没有。词条里一句 `<img src="Foo.mdd">`（`required_ext` 现在为空，任何裸名都过）就会把 GB 级 `.mdd` 整个读进内存再塞进 media store。构造性强，但正是「白名单换成全取」之后新暴露的面。

方向：加累计字节数 / 条目数上限；非 zip 路径给 `read_file_text` 也加单文件上限。

- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：与 BUG-2147 同源（同一次放宽引入）。PR#1220 的技术实现整体质量高（作者自己否决了第一版、把「刻意不修」用测试钉住、主动为自己引入的 zip 覆盖洞加了守卫），这两条是审查补充，不影响该 PR 已修好的主路径。
