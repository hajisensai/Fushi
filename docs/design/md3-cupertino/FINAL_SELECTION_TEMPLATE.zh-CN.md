# Hibiki MD3 + Cupertino 最终选择模板

优先从 [interface-pack-comparison.html](interface-pack-comparison.html) 点选并复制最终选择文本；需要手写时，再把这个文件复制成 `my-final-selection.txt` 后填写。不要在这里写讨论文字；生成器现在会严格检查，拼错的界面名不会被悄悄吞掉。

## 推荐起点

```text
Pack: hibiki-balanced
例外:
reader_hoshi_page.dart: B
display_settings_page.dart: B
audiobook_play_bar.dart: B
lyrics_dialog_page.dart: B
dictionary_dialog_page.dart: C
dictionary_dialog_import_page.dart: C
dictionary_settings_dialog_page.dart: C
anki_settings_page.dart: C
tag_management_page.dart: C
debug_log_page.dart: A
error_log_page.dart: A
```

上面这些例外大多已经等于 `Hibiki Balanced` 默认值；保留它们是为了让审核时先看高风险界面。你可以删掉不想显式确认的行，也可以把 `B`/`C` 改成你在 [interface-pack-comparison.html](interface-pack-comparison.html) 里选中的方向。比较页顶部复制出来的文本已经是这个格式，可以直接保存成 `my-final-selection.txt`。

## 空白模板

```text
Pack: hibiki-balanced
例外:

Notes:
- 阅读器：
- 词典：
- 词典管理：
- Anki/制卡：
- 书架/收藏：
- 日志/错误：
```

## 支持的格式

- 整包：`Pack: hibiki-balanced`
- 单界面：`reader_hoshi_page.dart: B`
- Board：`04: B`
- 注释：以 `#` 开头的整行会被忽略
- Notes：`Notes:` 后面的行会进入规格草案

可用 pack：

- `md3-practical`
- `reading-calm`
- `adaptive-power`
- `hibiki-balanced`

可用选择：

- `A`
- `B`
- `C`

## 生成最终规格

```powershell
node .\generate-implementation-spec.mjs --picks .\my-final-selection.txt --output .\IMPLEMENTATION_SPEC_FINAL_DRAFT.md
```

如果命令报 `Unrecognized picks line`，说明文件里有一行不是有效选择。修掉那行再生成，别让错误输入混进实现计划。
