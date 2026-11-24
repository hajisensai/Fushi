# Fushi settings reference

> Every setting of the Fushi app (version 3.4.0), generated from the app's own settings schema on each change. 928 entries. Machine-readable copy: <https://fushi.moe/settings.json>.

How to read this:

- **Key** is the stable id of a setting. `fushi_cli config get <key>` / `fushi_cli config set <key> <value>` and the in-app AI assistant use the same keys.
- **Where** is the place inside the Settings page of the category (section › sub-page). Titles are given in English and Simplified Chinese; the app shows them in the interface language.
- **Type**: `bool`, `choice` (one of **Values**), `number` (range in **Values**), `text`, `secret` (a credential; never readable), `action` (a button), `status` (read-only), `list` (records), `custom` (a row drawn by the app, changed only in the Settings page).
- **Default** is the value on a fresh install. Where it differs between platforms, each value is listed with the platforms it applies to (android, ios, windows, macos).
- *Only on ...* in Notes: the row is shown only on those platforms. Rows without it may still depend on another setting or module being enabled.
- Notes: *user only* = the AI assistant may not change it; *destructive* = asks for confirmation.

## General (通用)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `appearance.language` | Interface language | 界面语言 | Language | choice | `en-US`, `zh-CN`, `zh-HK`, `ja`, `ko`, `es`, `fr`, `de`, `pt-BR`, `ru`, `vi`, `th`, `id`, `ar`, `nl`, `it`, `tr` | `en-US` |  |
| `system.focus_navigation` | Keyboard & gamepad focus navigation | 键盘/手柄焦点导航 | Keyboard and gamepad | bool |  | `false` | Move focus with arrow keys or a gamepad and show a focus ring. |
| `appearance.controller_lookup_style` | Controller lookup mode | 手柄查词模式 | Keyboard and gamepad | choice | `holdL1`, `selectToggle`, `off` | `holdL1` | Move a lookup cursor over text with the controller. Default: hold L1. |
| `reading.stats_idle_timeout_minutes` | Idle timeout | 空闲判定时长 | Study timer | number | 1.0 – 120.0 | `10.0` | Stop counting study time after this many minutes without turning a page, scrolling, looking up a word or playing video. Applies to novels, PDFs, manga and video; video always counts while it plays. |
| `reading.stats_clock_start_mode` | Reading timer start | 阅读计时开始方式 | Study timer | choice | `manual`, `onOpen`, `onPageTurn` | `onOpen` | When the reading timer starts after you open a book (applies the next time a book is opened). You can pause or resume it anytime with the timer button or P. |
| `music.listening_counts_as_study` | Count listening as study time | 听歌计入学习 | Study timer | bool |  | `false` | Counts listening time and lyric characters (each line once). When off, only what follows a lookup, card or loop on the lyrics page counts |
| `study_goals.list` | Your goals | 我的目标 | Study timer › Goals › Your goals | custom |  |  |  |
| `study_goals.text_unit` | Text unit | 文字单位 | Study timer › Goals › What to count | choice | `auto`, `chars`, `words` | `auto` | Auto counts words for languages written with spaces (English, French…) and characters for the rest. |
| `study_goals.week_start` | Week starts on | 每周开始于 | Study timer › Goals › What to count | choice | `1`, `7`, `6` | `1` | Used by weekly goals, the Today tile and weekly statistics |
| `study_goals.today_layout` | Layout | 布局 | Study timer › Goals › Today tile | choice | `focus`, `overview` | `focus` | Focus shows one goal large; swipe to see the others. Overview lists all your goals at once. |
| `study_goals.today_main` | Main goal | 主目标 | Study timer › Goals › Today tile | choice |  |  |  |
| `study_goals.today_swipe` | Swipe through | 左右滑动 | Study timer › Goals › Today tile | choice | `daily`, `all` | `daily` | Which goals the Today tile shows when you swipe it |
| `general.listening_reminder` | Listening break reminder | 连续收听提醒 | Hearing care | bool |  | `false` | When music, audiobooks or video have played continuously for the chosen time, remind you once to rest your ears. Volume and playback are left alone. |
| `general.listening_reminder_minutes` | Remind after | 提醒间隔 | Hearing care | choice | `15`, `30`, `45`, `60`, `90`, `120` | `60` |  |
| `general.media_lock_show` | Show locked titles | 显示已上锁的作品 | Title privacy | bool |  | `false` | Off every time the app starts. Turning it on asks for your passcode or system verification. · *user only* |
| `general.media_lock_passcode` | Unlock passcode | 解锁口令 | Title privacy | action |  |  | Set or change the passcode for showing locked titles. Changing it asks you to verify first. |
| `general.media_lock_passcode_remove` | Remove unlock passcode | 删除解锁口令 | Title privacy | action |  |  | Asks you to verify first. While titles are still locked, only possible on devices with system verification. |
| `general.archive_passwords_clear` | Clear remembered archive passwords | 清除已记住的压缩包密码 | Title privacy | action |  |  | Passwords saved with “Remember password” when importing encrypted zip / 7z / rar archives · *destructive* |
| `appearance.nsfw_blur_covers` | Blur NSFW covers | 模糊 NSFW 封面 | Title privacy | bool |  | `true` | Covers of titles marked NSFW (title menu › Privacy; games also follow Adult title), and of everything in an NSFW collection, are blurred in the library and on Continue cards. |
| `appearance.nsfw_blur_card_images` | Blur card images too | 制卡图片也模糊 | Title privacy | bool |  | `false` | Cards mined from an NSFW book or manga get a blurred cover or page image. The blurred image is what gets saved in the card, so turning NSFW off later does not restore cards already made. |
| `system.low_memory_mode` | Low memory mode | 小内存模式 | Performance and getting started | bool |  | `false` | Reduce cache and memory usage for low-end devices. Some changes take effect after restart. |
| `system.recommended_pack_download` | Recommended pack | 推荐包 | Performance and getting started | custom |  |  | Japanese dictionaries, pitch accent, word frequency and JA/EN pronunciation audio in one download. Learning another language? Skip this and import your own dictionaries. |
| `appearance.steam_shortcut` | Add to Steam | 添加到 Steam | Performance and getting started | action |  |  | Show Fushi in your Steam library, so you can start it in Steam Deck Game Mode · *destructive* |
| `appearance.steam_shortcut_remove` | Remove from Steam | 从 Steam 移除 | Performance and getting started | action |  |  | Removes Fushi's entry and artwork from your Steam library · *destructive* |
| `appearance.content_language.cli.value` | Default content language | 默认内容语言 |  | text | `none`, `ja`, `zh-Hans`, `zh-Hant`, `ko`, `en` | `none` | none / ja / zh-Hans / zh-Hant / ko / en（none = 未设置） |
| `library.content_language.cli.item` | Content language | 内容语言 |  | action |  |  | Decides which font renders this book's text. Automatic uses the language declared in the EPUB. |

## Appearance (外观)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `appearance.design_system` | Design system | 设计系统 | Theme | choice | `auto`, `material`, `glass` | `auto` |  |
| `appearance.theme` | Theme | 主题 | Theme | choice | `system-theme`, `m3-baseline`, `m3-indigo`, `m3-blue`, `m3-teal`, `m3-green`, `m3-yellow`, `m3-orange`, `m3-red`, `m3-pink`, `m3-neutral` | `system-theme` |  |
| `appearance.brightness` | Dark mode | 深色模式 | Theme | choice | `light`, `system`, `dark` | `system` |  |
| `appearance.reader_paper_light` | Light reading paper | 浅色阅读纸色 | Theme | text | `follow`, `ecru-theme`, `water-theme`, `eyecare-theme` | `follow` | follow \| ecru-theme \| water-theme \| eyecare-theme |
| `appearance.reader_paper_dark` | Dark reading paper | 深色阅读纸色 | Theme | text | `follow`, `gray-theme`, `dark-theme`, `black-theme` | `follow` | follow \| gray-theme \| dark-theme \| black-theme |
| `appearance.pure_black_dark` | Pure black dark | 纯黑深色背景 | Theme | bool |  | `false` | Use true black backgrounds in dark mode (OLED) |
| `appearance.eink_mode` | E-ink mode | 墨水屏模式 | Theme | bool |  | `false` | Pure black-and-white theme with no animations and line-style highlights, for e-ink displays |
| `appearance.eink_full_refresh_interval` | E-ink full refresh | 墨水屏全刷 | Theme | choice | `0`, `1`, `2`, `3`, `5`, `10`, `20` | `0` | While reading novels or manga, do a full e-ink refresh every few page turns to clear ghosting |
| `appearance.eink_full_refresh_method` | Full refresh method | 全刷方式 | Theme | choice | `auto`, `flash` | `auto` | Auto uses the e-reader's own full refresh when supported (Onyx BOOX, Rockchip-based readers, Nook / Tolino) and briefly flashes the screen black otherwise. Choose Black flash if Auto has no effect on your device. |
| `appearance.glass_material` | Glass quality | 玻璃画质 | Theme | choice | `off`, `minimal`, `standard`, `premium` | `minimal` | Only affects floating controls such as buttons, bars and menus; text and video stay the same. Higher levels look closer to the system effect and use more power. Solid is used automatically in e-ink mode and when the system's Reduce Transparency is on. |
| `appearance.shell_content_layout` | Library layout | 库页布局 | Theme | text | `collage`, `grid` | `collage` |  |
| `appearance.shell_block_arrangement` | Block arrangement | 色块摆放 | Theme | text | `aligned`, `staggered`, `scattered` | `aligned` | How color blocks sit on library pages. Does not apply to the cover grid. |
| `appearance.shell_rail_style` | Sidebar style | 侧栏样式 | Theme | text | `notch`, `spine` | `notch` |  |
| `appearance.shell_smooth_corners` | Smooth corners | 平滑圆角 | Theme | bool |  | `true` | Continuous-curvature corners, like app icons |
| `appearance.second_screen_mode` | Second screen | 第二块屏幕 | Theme | choice | `auto`, `always`, `off` | `auto` | Show controls and dictionary on a connected second screen, such as the bottom screen of a dual-screen handheld. |
| `appearance.second_screen_lookup_screen` | Lookups open on | 查词结果显示在 | Theme | choice | `bottom`, `top` | `bottom` | Where words you look up on the main screen show while the second screen is in use |
| `appearance.page_backdrop.preset` | Style | 样式 | Background and scaling › Page background › Style | custom |  |  |  |
| `appearance.page_backdrop.strength` | Intensity | 强度 | Background and scaling › Page background › Style | choice | `subtle`, `standard`, `strong` | `standard` | How bold the decoration is |
| `appearance.page_backdrop.blur` | Blur | 模糊 | Background and scaling › Page background › Custom image | choice | `none`, `light`, `heavy` | `none` |  |
| `appearance.page_backdrop.scrim` | Overlay | 遮罩浓度 | Background and scaling › Page background › Custom image | number | 0.0 – 0.85 | `0.5` | Tints the image so text stays readable |
| `appearance.page_backdrop.follow_accent` | Colors from image | 从图片取色 | Background and scaling › Page background › Custom image | bool |  | `true` | Use the image's colors as the app theme |
| `appearance.page_backdrop.accent_candidates` | Theme color | 主题色 | Background and scaling › Page background › Custom image | custom |  |  |  |
| `appearance.page_backdrop.motion` | Slow drift | 缓慢漂移 | Background and scaling › Page background | bool |  | `false` | The background drifts or turns very slowly; stays still when reduce motion is on |
| `appearance.page_backdrop.module.home.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Home › Style | custom |  |  |  |
| `appearance.page_backdrop.module.books.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Books › Style | custom |  |  |  |
| `appearance.page_backdrop.module.manga.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Manga › Style | custom |  |  |  |
| `appearance.page_backdrop.module.video.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Video › Style | custom |  |  |  |
| `appearance.page_backdrop.module.music.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Music › Style | custom |  |  |  |
| `appearance.page_backdrop.module.browse.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Browse › Style | custom |  |  | *only on android, windows, macos* |
| `appearance.page_backdrop.module.dictionaries.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Lookup › Style | custom |  |  |  |
| `appearance.page_backdrop.module.srs.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Review › Style | custom |  |  |  |
| `appearance.page_backdrop.page.srs_review.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Review › Per-page backdrops › Review screen › Style | custom |  |  |  |
| `appearance.page_backdrop.module.games.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Game › Style | custom |  |  |  |
| `appearance.page_backdrop.module.web.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Browser › Style | custom |  |  |  |
| `appearance.page_backdrop.module.settings.preset` | Style | 样式 | Background and scaling › Page background › Per-module backdrops › Settings › Style | custom |  |  |  |
| `appearance.app_ui_scale` | UI size | 界面大小 | Background and scaling | number | 0.3 – 3.0 | `1.0` | Scales the whole interface (text, icons and controls together), 30% to 300%. |
| `appearance.tint_app_logo` | Logo follows theme color | 图标跟随主题色 | App icon | bool |  | `false` | Recolor the built-in mascot icon to match the accent color. When off, the original artwork is always shown. |
| `appearance.mascot_glow` | Mascot glow | 吉祥物光晕 | App icon | bool |  | `false` | A soft breathing glow around the mascot on the floating ball. It brightens and speeds up while background sync is running. |
| `appearance.follow_app_icon_accent` | Theme color follows custom icon | 主题色跟随图标 | App icon | bool |  | `false` | Take the accent color from your custom icon image. Turn off to return to the theme you picked. |
| `appearance.font_catalog.cli.fonts` | Font library | 字体库 | Font library | list |  |  |  |
| `appearance.font_catalog.cli.target.appUi` | Font library · appUi | 字体库 · appUi | Font library | text |  |  | 该用途使用的字体显示名（或 id），逗号分隔；顺序跟随目录顺序（用 items set --position 调）；空串 = 清空 |
| `appearance.font_catalog.cli.target.body` | Font library · body | 字体库 · body | Font library | text |  |  | 该用途使用的字体显示名（或 id），逗号分隔；顺序跟随目录顺序（用 items set --position 调）；空串 = 清空 |
| `appearance.font_catalog.cli.target.dictionary` | Font library · dictionary | 字体库 · dictionary | Font library | text |  |  | 该用途使用的字体显示名（或 id），逗号分隔；顺序跟随目录顺序（用 items set --position 调）；空串 = 清空 |
| `appearance.font_catalog.cli.target.videoSubtitle` | Font library · videoSubtitle | 字体库 · videoSubtitle | Font library | text |  |  | 该用途使用的字体显示名（或 id），逗号分隔；顺序跟随目录顺序（用 items set --position 调）；空串 = 清空 |
| `appearance.font_catalog.cli.target.gameLookup` | Font library · gameLookup | 字体库 · gameLookup | Font library | text |  |  | 该用途使用的字体显示名（或 id），逗号分隔；顺序跟随目录顺序（用 items set --position 调）；空串 = 清空 |
| `appearance.font_catalog.cli.target.floatingLyric` | Font library · floatingLyric | 字体库 · floatingLyric | Font library | text |  |  | 该用途使用的字体显示名（或 id），逗号分隔；顺序跟随目录顺序（用 items set --position 调）；空串 = 清空 |
| `appearance.font_catalog.cli.target.srsCard` | Font library · srsCard | 字体库 · srsCard | Font library | text |  |  | 该用途使用的字体显示名（或 id），逗号分隔；顺序跟随目录顺序（用 items set --position 调）；空串 = 清空 |
| `appearance.font_catalog.cli.download` | Downloading... | 正在下载… | Font library | action |  |  | 后台下载字体（URL 或推荐字体）；立即返回任务，fushi_cli task get <id> --wait 看进度，task cancel <id> 取消 |
| `appearance.font_catalog.cli.recommended` | Recommended fonts | 推荐字体 | Font library | action |  |  | 列出推荐字体表（name 可作 items add --arg recommended=…） |
| `appearance.font_catalog.cli.system_fonts` | Add system font | 添加系统字体 | Font library | action |  |  | 列出本机系统字体族（family 可作 items add --arg system=…） |
| `appearance.custom_themes.cli.themes` | Theme | 主题 | Theme | list |  |  |  |
| `appearance.app_icon.cli.icon` | Presets | 预设 | App icon | text | `default` | `default` | 预设图标 key（default）；自定义图片用 `config run appearance.app_icon.cli.set_custom` · *only on android, windows* |
| `appearance.app_icon.cli.set_custom` | Custom | 自定义 | App icon | action |  |  | This will create a home screen shortcut with your chosen image. Continue? · *only on android, windows* |

## Navigation and home (导航与首页)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `appearance.nav_module_order` | Navigation bar order | 导航栏顺序 | Feature modules | custom |  |  | Drag to reorder; the switch decides whether it appears in the bottom bar |
| `system.module_listening` | Listening | 听书 | Feature modules | bool |  | `true` |  |
| `system.module_card_creation` | Card creation | 制卡 | Feature modules | bool |  | `true` |  |
| `system.module_services` | Online services | 在线服务 | Feature modules | bool |  | `true` |  |
| `system.module_tracking` | Media tracking | 媒体记录 | Feature modules | bool |  | `false` |  |
| `system.module_ai` | AI | AI | Feature modules | bool |  | `true` |  |
| `system.module_sync` | Sync & backup | 同步与备份 | Feature modules | bool |  | `true` |  |
| `appearance.startup_default_dictionary_tab` | Startup page | 启动页 | Start page and bottom bar | choice | `default`, `home`, `books`, `manga`, `video`, `music`, `games`, `browse`, `lookup`, `web` | `default` | The page shown when the app opens; only enabled modules can be chosen. |
| `appearance.nav_bar_style` | Bottom bar style | 底栏样式 | Start page and bottom bar | choice | `flat`, `dial`, `modeStrip` | `modeStrip` | Shape of the bottom bar: flat, thumb dial or camera-style mode strip |
| `appearance.nav_bar_labels` | Show navigation bar labels | 底栏显示文字 | Start page and bottom bar | bool |  | `false` | Show page names below the icons |
| `appearance.reverse_navigation_bar` | Reverse navigation bar | 反转底栏方向 | Start page and bottom bar | bool |  | `false` | Swap the order of the bottom bar buttons left to right, for left-handed use |
| `appearance.jump_history.toolbar` | Show back / forward in the top bar | 顶栏显示返回 / 前进 | Jump history | bool |  | `true` | When off, jumps are still recorded; the jump history panel and progress marks keep working |
| `appearance.jump_history.auto_hide` | Auto-hide top bar jump buttons | 顶栏图标自动隐藏 | Jump history | choice | `0`, `30`, `60`, `300` | `0` | Hides the back / forward icons this long after the last jump |
| `appearance.jump_history.progress_marks` | Mark jump points on progress bars | 进度条标出跳转位置 | Jump history | bool |  | `true` | Draw back and forward points on the progress bar and page slider |

## Floating ball (悬浮球)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `floating_ball.in_app` | Show in app | 应用内显示 | Display | bool |  | `true` | A draggable ball on every Fushi page. Tap it to expand the buttons picked below for the current page |
| `floating_ball.system` | Show over other apps | 应用外显示 | Display | bool |  | `false` | Keep the ball on screen after switching to other apps. Needs the display-over-other-apps permission · *only on android, windows, macos* |
| `floating_ball.tap_action` | Tap the ball to | 点按悬浮球 | Display | choice | `expand`, `clipboard`, `screenOcr`, `ai` | `expand` | Outside the app, tapping the collapsed ball runs the chosen action right away; long-press it to open the buttons |
| `floating_ball.show_labels` | Show button labels | 显示按钮文字 | Display | bool |  | `true` | Show text beside expanded buttons. Turn off to show icons only |
| `floating_ball.auto_restore` | Auto-restore floating ball | 自动恢复悬浮球 | Display | choice | `both`, `inApp`, `off` | `inApp` | Whether the floating ball comes back automatically when you return to Fushi after closing it |
| `floating_ball.screen_ocr_card_image` | Add screenshot to cards | 截屏识字制卡带截图 | Screen OCR | bool |  | `true` | When making a card, put the text block around the tapped text into the card's image field |
| `floating_ball.screen_ocr_card_frame_on_mine` | Frame the screenshot when adding a card | 制卡时框选截图 | Screen OCR | bool |  | `false` | Before each card is added, choose how much of the screenshot goes on it, such as the poster and post time around the text |
| `floating_ball.screen_ocr_engine` | Screen OCR engine | 截屏识字引擎 | Screen OCR | choice | `followGlobal`, `localModel`, `googleLens` | `followGlobal` | Follows the OCR engine in Settings › Models › OCR by default. Built-in OCR is fastest on horizontal on-screen text, vertical text needs the local model, and Google Lens uploads the whole screenshot. If the followed local model isn't downloaded yet, built-in OCR is used. · *only on android, windows, macos* |
| `floating_ball.screen_ocr_keep_session` | Keep screen capture session | 保持截屏会话 | Screen OCR | bool |  | `false` | After allowing screen recording once, screen OCR stops showing the system confirmation every time · *only on android* |
| `floating_ball.app_audio_capture` | Capture other apps' audio | 缓存其他应用的声音 | Game voice | bool |  | `false` | Keeps the last 60 seconds of sound played by other apps in memory (Android 10+). Cards mined from out-of-app lookups get the voice line from just before the lookup as sentence audio. Some games block capture and record silence. · *user only* |
| `floating_ball.reader.back` | Back | 返回 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.modeToggle` | Lyrics mode | 歌词模式 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.navigation` | Navigation | 导航 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.bookmarks` | Bookmarks & saved sentences | 书签与收藏 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.jumpHistory` | Jump history | 跳转记录 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.gallery` | Browse illustrations | 浏览插图 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.statistics` | Reading statistics | 阅读统计 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.studyTimer` | Pause / resume reading timer | 暂停 / 继续阅读计时 | Book reader | bool |  | `true` |  |
| `floating_ball.reader.audiobook` | Audiobook | 有声书 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.fullscreen` | Toggle fullscreen | 全屏切换 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.toolbars` | Hide top and bottom bars | 隐藏顶栏和底栏 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.settings` | Reader settings | 阅读设置 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.audiobookPrev` | Previous sentence | 上一句 | Book reader | bool |  | `true` |  |
| `floating_ball.reader.audiobookPlayPause` | Play / Pause | 播放 / 暂停 | Book reader | bool |  | `true` |  |
| `floating_ball.reader.audiobookNext` | Next sentence | 下一句 | Book reader | bool |  | `true` |  |
| `floating_ball.reader.audiobookSeekBack` | Rewind 10 seconds | 快退 10 秒 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.audiobookSeekForward` | Forward 10 seconds | 快进 10 秒 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.audiobookFollow` | Follow audio | 跟随音频 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.lookup` | Look up | 查词 | Book reader | bool |  | `true` |  |
| `floating_ball.reader.popup_lookup` | App-external lookup | 应用外查词 | Book reader | bool |  | `false` | *only on android* |
| `floating_ball.reader.clipboard` | Look up clipboard | 剪贴板查词 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.screen_ocr` | Screen OCR | 截屏识字 | Book reader | bool |  | `false` | *only on android, ios* |
| `floating_ball.reader.camera_ocr` | Photo lookup | 拍照查词 | Book reader | bool |  | `false` | *only on android, ios* |
| `floating_ball.reader.sync` | Sync now | 立即同步 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.switch_profile` | Switch profile | 切换配置 | Book reader | bool |  | `false` |  |
| `floating_ball.reader.feedback` | Feedback | 反馈 | Book reader | bool |  | `true` |  |
| `floating_ball.reader.ai` | AI | AI | Book reader | bool |  | `true` |  |
| `floating_ball.manga.previous` | Previous page | 上一页 | Manga reader | bool |  | `true` |  |
| `floating_ball.manga.next` | Next page | 下一页 | Manga reader | bool |  | `true` |  |
| `floating_ball.manga.ocr_boxes` | Show recognized text regions | 显示识别范围 | Manga reader | bool |  | `true` |  |
| `floating_ball.manga.ocr_volume` | Recognize this volume | 识别本卷 | Manga reader | bool |  | `true` |  |
| `floating_ball.manga.ocr_rerun` | Re-run OCR on this volume… | 重新识别本卷… | Manga reader | bool |  | `true` |  |
| `floating_ball.manga.chapters` | Chapters | 章节 | Manga reader | bool |  | `true` |  |
| `floating_ball.manga.lookup` | Look up | 查词 | Manga reader | bool |  | `true` |  |
| `floating_ball.manga.popup_lookup` | App-external lookup | 应用外查词 | Manga reader | bool |  | `false` | *only on android* |
| `floating_ball.manga.clipboard` | Look up clipboard | 剪贴板查词 | Manga reader | bool |  | `false` |  |
| `floating_ball.manga.screen_ocr` | Screen OCR | 截屏识字 | Manga reader | bool |  | `false` | *only on android, ios* |
| `floating_ball.manga.camera_ocr` | Photo lookup | 拍照查词 | Manga reader | bool |  | `false` | *only on android, ios* |
| `floating_ball.manga.sync` | Sync now | 立即同步 | Manga reader | bool |  | `false` |  |
| `floating_ball.manga.switch_profile` | Switch profile | 切换配置 | Manga reader | bool |  | `false` |  |
| `floating_ball.manga.feedback` | Feedback | 反馈 | Manga reader | bool |  | `true` |  |
| `floating_ball.manga.ai` | AI | AI | Manga reader | bool |  | `true` |  |
| `floating_ball.video.play_pause` | Play/Pause | 播放/暂停 | Video player | bool |  | `true` |  |
| `floating_ball.video.prev_cue` | Previous subtitle | 上一句字幕 | Video player | bool |  | `true` |  |
| `floating_ball.video.next_cue` | Next subtitle | 下一句字幕 | Video player | bool |  | `true` |  |
| `floating_ball.video.favorite` | Favorite current sentence | 收藏当前句 | Video player | bool |  | `true` |  |
| `floating_ball.video.screenshot` | Screenshot | 截图 | Video player | bool |  | `true` |  |
| `floating_ball.video.lookup` | Look up | 查词 | Video player | bool |  | `true` |  |
| `floating_ball.video.popup_lookup` | App-external lookup | 应用外查词 | Video player | bool |  | `false` | *only on android* |
| `floating_ball.video.clipboard` | Look up clipboard | 剪贴板查词 | Video player | bool |  | `false` |  |
| `floating_ball.video.screen_ocr` | Screen OCR | 截屏识字 | Video player | bool |  | `false` | *only on android, ios* |
| `floating_ball.video.camera_ocr` | Photo lookup | 拍照查词 | Video player | bool |  | `false` | *only on android, ios* |
| `floating_ball.video.sync` | Sync now | 立即同步 | Video player | bool |  | `false` |  |
| `floating_ball.video.switch_profile` | Switch profile | 切换配置 | Video player | bool |  | `false` |  |
| `floating_ball.video.feedback` | Feedback | 反馈 | Video player | bool |  | `true` |  |
| `floating_ball.video.ai` | AI | AI | Video player | bool |  | `true` |  |
| `floating_ball.general.lookup` | Look up | 查词 | Other pages | bool |  | `true` |  |
| `floating_ball.general.popup_lookup` | App-external lookup | 应用外查词 | Other pages | bool |  | `false` | *only on android* |
| `floating_ball.general.clipboard` | Look up clipboard | 剪贴板查词 | Other pages | bool |  | `true` |  |
| `floating_ball.general.screen_ocr` | Screen OCR | 截屏识字 | Other pages | bool |  | `true` | *only on android, ios* |
| `floating_ball.general.camera_ocr` | Photo lookup | 拍照查词 | Other pages | bool |  | `true` | *only on android, ios* |
| `floating_ball.general.sync` | Sync now | 立即同步 | Other pages | bool |  | `false` |  |
| `floating_ball.general.switch_profile` | Switch profile | 切换配置 | Other pages | bool |  | `false` |  |
| `floating_ball.general.feedback` | Feedback | 反馈 | Other pages | bool |  | `true` |  |
| `floating_ball.general.ai` | AI | AI | Other pages | bool |  | `true` |  |
| `floating_ball.system.open_app` | Open Fushi | 打开 Fushi | Outside the app | bool |  | `true` |  |
| `floating_ball.system.lookup` | Look up | 查词 | Outside the app | bool |  | `true` |  |
| `floating_ball.system.popup_lookup` | App-external lookup | 应用外查词 | Outside the app | bool |  | `true` |  |
| `floating_ball.system.clipboard` | Look up clipboard | 剪贴板查词 | Outside the app | bool |  | `true` |  |
| `floating_ball.system.screen_ocr` | Screen OCR | 截屏识字 | Outside the app | bool |  | `true` |  |
| `floating_ball.system.camera_ocr` | Photo lookup | 拍照查词 | Outside the app | bool |  | `true` |  |
| `floating_ball.system.sync` | Sync now | 立即同步 | Outside the app | bool |  | `false` |  |
| `floating_ball.system.switch_profile` | Switch profile | 切换配置 | Outside the app | bool |  | `false` |  |
| `floating_ball.system.feedback` | Feedback | 反馈 | Outside the app | bool |  | `true` |  |
| `floating_ball.system.ai` | AI | AI | Outside the app | bool |  | `false` |  |

## Reading (阅读)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `reading_display.view_mode` | Reading mode | 阅读模式 | Mode & direction | choice | `paginated`, `continuous`, `vn` | `paginated` |  |
| `reading_display.follow_book_layout` | Follow the book's layout | 跟随原书排版 | Mode & direction | bool |  | `true` | Use the writing direction and page order the book itself declares (EPUB page-progression-direction / primary-writing-mode). Books that declare nothing use the settings below. |
| `reading_display.writing_mode` | Writing direction | 排版方向 | Mode & direction | choice | `horizontal-tb`, `vertical-rl` | `vertical-rl` |  |
| `reading_display.vert_text_orient` | Text orientation | 文字方向 | Mode & direction | choice | `mixed`, `upright` | `mixed` |  |
| `reading_display.furigana_mode` | Furigana display | 振假名显示 | Mode & direction | choice | `off`, `toggle`, `hidden`, `dimmed` | `off` | Only affects the furigana that comes with the book: show as usual, show on tap, hide or dim. |
| `reading_display.page_columns` | Page spread | 单双页 | Pages and spreads | choice | `auto`, `single`, `double` | `auto` | Auto: two pages on foldables and wide landscape windows. Two-page vertical text needs a recent WebView. |
| `reading_display.page_crease` | Page crease | 中缝折痕 | Pages and spreads | bool |  | `false` | Shade the gutter between two pages, like an open book (two columns per page) |
| `reading_display.spread_mode` | Spread mode | 跨页模式 | Pages and spreads | choice | `off`, `on`, `auto` | `off` | Pair adjacent full-page illustration chapters into one spread, such as facing pages. Auto follows the book's own spread hints, then image edge matching. |
| `reading_display.spread_direction` | Spread direction | 跨页方向 | Pages and spreads | choice | `rtl`, `ltr` | `rtl` |  |
| `reading_vn.reveal_speed` | Text reveal speed | 文字渐显速度 | Visual novel | number | 0.0 – 120.0 | `45.0` |  |
| `reading_vn.screen_mode` | Screen content | 每屏内容 | Visual novel | choice | `block`, `sentences` | `block` |  |
| `reading_vn.sentences_per_screen` | Sentences per screen | 每屏句数 | Visual novel | number | 1.0 – 12.0 | `1.0` |  |
| `reading_vn.preserve_dialogue` | Keep dialogue together | 保持对话完整 | Visual novel | bool |  | `false` |  |
| `reading_vn.click_advance` | Blank tap advances | 点击空白处推进 | Visual novel | bool |  | `false` |  |
| `reading_vn.merge_spoken_sentence` | Keep spoken sentence on one screen | 有声句保持在同一屏 | Visual novel | bool |  | `false` |  |
| `listening.page_end_audio` | Audio at end of page | 页末时音频 | Visual novel | choice | `audio`, `text` | `audio` | While following audio. Pause: playback stops after the last sentence on the screen and continues when you turn the page. |
| `reading_display.font_size` | Font size | 字体大小 | Typography | number | 8.0 – 128.0 | `20.0` |  |
| `reading_display.font_weight` | Font weight | 字体粗细 | Typography | number | 100.0 – 900.0 | `400.0` |  |
| `reading_display.line_height` | Line height | 行高 | Typography | number | 1.0 – 3.0 | `1.65` |  |
| `reading_display.text_indentation` | Paragraph indent | 段落缩进 | Typography | number | 0.0 – 10.0 | `0.0` |  |
| `reading_display.paragraph_spacing` | Paragraph spacing | 段落间距 | Typography | number | 0.0 – 3.0 | `0.0` |  |
| `reading_display.text_justify` | Text justification | 两端对齐 | Typography | bool |  | `false` | Align each line to both page edges. |
| `reading_display.margin_top` | Top margin | 上边距 | Margins | number | 0.0 – 50.0 | `0.0` |  |
| `reading_display.margin_bottom` | Bottom margin | 下边距 | Margins | number | 0.0 – 50.0 | `0.0` |  |
| `reading_display.margin_left` | Left margin | 左边距 | Margins | number | 0.0 – 50.0 | `2.0` |  |
| `reading_display.margin_right` | Right margin | 右边距 | Margins | number | 0.0 – 50.0 | `2.0` |  |
| `reading_controls.tap_zone_layout` | Tap zones to turn pages | 点击翻页区域 | Page turning & gestures | choice | `disabled`, `leftRight`, `allForward`, `topBottom` | `disabled` |  |
| `reading_controls.swipe_page_turn_sensitivity` | Swipe page-turn sensitivity | 滑动翻页灵敏度 | Page turning & gestures | number | 0.5 – 3.0 | `1.0` |  |
| `reading_controls.wheel_page_turn_interval` | Mouse wheel page-turn interval | 滚轮翻页间隔 | Page turning & gestures | number | 150.0 – 1000.0 | `450.0` |  |
| `reading_controls.volume_page_turning` | Volume button page turning | 音量键翻页 | Page turning & gestures | bool |  | `true` | *only on android* |
| `reading_controls.page_turn_animation` | Page turn animation | 翻页动画 | Page turning & gestures | choice | `none`, `slide`, `cover`, `fade`, `curl` | `curl` |  |
| `reading_controls.page_turn_animation_speed` | Animation speed | 动画速度 | Page turning & gestures | choice | `fast`, `normal`, `slow` | `normal` |  |
| `reading_controls.page_turn_follow_drag` | Follow finger while dragging | 拖动跟手 | Page turning & gestures | bool |  | `true` |  |
| `reading_controls.continuous_chapter_turn_resistance` | Chapter turn resistance | 切章阻尼 | Page turning & gestures | choice | `low`, `standard`, `high` | `standard` | How far you pull past the start or end of a chapter before scrolling turns to the next one |
| `reading_controls.continuous_seamless_chapters` | Seamless chapters | 章节无缝衔接 | Page turning & gestures | bool |  | `false` | Keep the previous and next chapters loaded so scrolling flows across chapter boundaries without reloading |
| `reading_controls.highlight_on_tap` | Look up words on tap | 单击查词 | Page turning & gestures | bool |  | `true` | When off, tapping text works like tapping blank space (turn pages, show the menu); long-press to select a word and look it up. |
| `reading_controls.invert_volume_buttons` | Invert volume buttons | 反转音量键方向 | Page turning & gestures | bool |  | `false` |  |
| `reading_controls.invert_swipe_direction` | Invert swipe page turn direction | 反转滑动翻页方向 | Page turning & gestures | bool |  | `true` |  |
| `reading_controls.reverse_arrow_page_turn` | Reverse keyboard left/right page-turn direction | 反转键盘左右键翻页方向 | Page turning & gestures | bool |  | `false` |  |
| `reading_controls.toolbar_style` | Toolbar style | 工具栏样式 | Toolbar | choice | `floating`, `docked` | `floating` | Floating toolbars hover over the page and hide with a tap; docked bars span the full width. |
| `reading_controls.tap_empty_hide_chrome` | Floating control bar | 悬浮控制栏 | Toolbar | bool |  | `true` | Tap an empty area of the text to show or hide the control bar. |
| `reading_controls.auto_hide_chrome_duration` | Auto-hide floating controls after | 悬浮控件自动隐藏延时 | Toolbar | number | 1.0 – 10.0 | `3.0` |  |
| `reading_controls.status_footer_persistent` | Keep readouts when controls hide | 收起控制栏时保留读数 | Toolbar | bool |  | `true` | Off: only a thin progress line stays at the bottom |
| `reading_controls.hide_toolbars` | Hide top and bottom bars | 隐藏顶栏和底栏 | Toolbar | bool |  | `false` |  |
| `reading_display.reverse_reader_bottom_bar` | Reverse reader bottom bar | 反转阅读器底栏 | Toolbar | bool |  | `false` | Swap the order of the bottom bar buttons left to right. |
| `reading_controls.controls_editor` | Reader button layout | 阅读器按钮布局 | Toolbar | text |  | `{"wide":{"version":1,"slots":{"topLeft":["back"],"topCenter":["title"],"topRight":["navigation","audiobook","settings"],"bottomLeft":[],"bottomCenter":[],"bottomRight":[],"overflow":["modeToggle","statistics","gallery","fullscreen","bookmarks","jumpHistory"]},"removed":["studyTimer","toolbars","audiobookPrev","audiobookPlayPause","audiobookNext","audiobookSeekBack","audiobookSeekForward","audiobookFollow"]},"compact":{"version":1,"slots":{"topLeft":["back"],"topCenter":["title"],"topRight":[],"bottomLeft":[],"bottomCenter":["navigation","audiobook","settings","statistics"],"bottomRight":[],"overflow":["modeToggle","gallery","fullscreen","bookmarks","jumpHistory"]},"removed":["studyTimer","toolbars","audiobookPrev","audiobookPlayPause","audiobookNext","audiobookSeekBack","audiobookSeekForward","audiobookFollow"]}}` | {"wide": <布局 JSON，含 slots>, "compact": <布局 JSON>}（config get 的输出可改后原样写回） |
| `reading_controls.reset_control_layout` | Restore default reader button layout | 恢复默认阅读器按钮布局 | Toolbar | action |  |  | *destructive* |
| `reading_controls.show_top_progress_bar` | Reading progress indicator | 顶部阅读进度 | Readouts and screen | bool |  | `true` |  |
| `reading_controls.show_reading_timer` | Show reading timer | 显示阅读计时器 | Readouts and screen | bool |  | `true` |  |
| `reading_controls.show_session_chars` | Show characters read this session | 显示本次字数 | Readouts and screen | bool |  | `false` |  |
| `reading_controls.show_chars_per_hour` | Show characters per hour | 显示每小时字数 | Readouts and screen | bool |  | `false` |  |
| `reading_controls.keep_screen_awake` | Keep screen awake | 阅读时防止息屏 | Readouts and screen | bool |  | `true` |  |
| `reading_display.prioritize_reader_styles` | Prioritize book styles | 优先书籍样式 | Advanced | bool |  | `true` | The book's own font, size and line spacing win over the typography settings above. |
| `reading_display.vert_kerning` | Font kerning (vertical) | 字偶间距（纵排） | Advanced | bool |  | `false` | Tighten the gaps between punctuation and kana in vertical text. |
| `reading_display.font_vpal` | VPAL (vertical alt) | VPAL 纵排替代 | Advanced | bool |  | `false` | Use the font's proportional vertical widths (OpenType vpal) for tighter punctuation. |
| `reading_display.blur_images` | Blur images (spoiler guard) | 图片模糊（防剧透） | Advanced | bool |  | `false` | Blur illustrations by default and reveal them on tap. |
| `reading_display.merge_image_pages` | Merge illustration pages into text | 将插图页并入正文 | Advanced | bool |  | `true` | Standalone single-image chapters render inline in the adjacent text chapter instead of on their own page |

## Listening (听书)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `listening.audiobook_background_play` | Keep playing after exit | 退出后继续播放 | Playback | bool |  | `false` | When off, audiobook playback stops when you leave the reader. Turn on to keep playing in the background. |
| `listening.media_notification` | Show media notification | 显示媒体通知 | Playback | bool |  | `true` | When off, a minimal notification (title and play/pause only) stays during playback so the system doesn't stop audio in the background. |
| `listening.volume_key_sentence_nav` | Volume key sentence navigation | 音量键句子导航 | Playback | bool |  | `true` | Use the volume keys to jump to the previous or next sentence. · *only on android* |
| `listening.audiobook_jump_threshold` | Return-to-position jump distance | 返回原位置的跳转距离 | Playback | choice | `15`, `30`, `60`, `120`, `300`, `600`, `900`, `1800` | `120` | Audio jumps at least this far (dragging the progress bar, tapping a sentence, chapter jumps) offer a return-to-position pill |
| `reading_controls.invert_audiobook_skip_direction` | Invert bottom-bar skip buttons | 反转底栏前进后退按钮 | Playback | bool |  | `false` | Swap the previous and next sentence buttons in the bottom bar. |
| `listening.page_split_follow` | Sentences split across pages | 跨页句子 | Playback | choice | `next_sentence`, `page_edge` | `page_edge` | Applies when Follow audio is on. Decides when to turn the page if a sentence is split across two pages. |
| `listening.scroll_follow` | Follow scrolling | 跟随滚动 | Playback | choice | `margin`, `line_align` | `line_align` | Applies when Follow audio is on. Line align: stays put while the whole sentence is on screen; otherwise scrolls the sentence's first line to the starting edge so no half line shows there. |
| `listening.tts_voices` | Read-aloud voices | 朗读声音 | Read-aloud voices | action |  |  | GPT-SoVITS, Microsoft, Google or the system voice |
| `listening.audiobook_material_library` | Audiobook material library | 有声书素材库 | Materials and transcription | action |  |  | Folders of subtitle and text files named by work id. Downloads are paired against them automatically. |
| `listening.audiobook_auto_transcribe` | Auto-transcribe downloaded audiobooks | 下载后自动转录有声书 | Materials and transcription | bool |  | `true` | Audiobooks downloaded without subtitles are transcribed on this device, aligned to the book text if it came with one, and added to the library. Takes a while; the speech model is downloaded automatically if missing. |
| `listening.audiobook_auto_transcribe_without_text` | Also transcribe audiobooks without book text | 没有正文也转录 | Materials and transcription | bool |  | `false` | When a download has no EPUB or text file, add the transcript as a subtitle book. Without book text the subtitles are less accurate. |
| `listening.audiobook_folder_import_transcribe` | Transcribe audiobooks found by folder import | 导入文件夹时为缺字幕的有声书转录 | Materials and transcription | bool |  | `false` | When a book in an imported folder has audiobook audio but no subtitles, transcribe it on this device and align it to the book. Local folders only. |
| `listening.floating_lyric` | Floating lyric overlay | 悬浮字幕 | Floating subtitle | bool |  | `false` | Float the currently playing subtitle line on top of other apps. |
| `listening.floating_lyric_visible_lines` | Sentences shown | 同时显示句数 | Floating subtitle | number | 0.0 – 15.0 | `3.0` | The current sentence stays in the middle, like lyrics mode. Auto fills the window height: drag the window taller to see more. |
| `listening.floating_lyric_font_size` | Floating subtitle font size | 悬浮字幕字号 | Floating subtitle | number | 8.0 – 64.0 | `20.0` |  |
| `listening.floating_lyric_click_lookup` | Tap floating subtitle to look up | 点击悬浮字幕查词 | Floating subtitle | bool |  | `true` | Keep this on with position lock if you still want word lookup. |
| `listening.floating_lyric_vertical` | Vertical text | 竖排 | Floating subtitle appearance | bool |  | `false` | Lay the subtitle out top-to-bottom with lines flowing right-to-left, like vertical lyrics. Widen the window to see more sentences. |
| `listening.floating_lyric_bold` | Bold text | 粗体文字 | Floating subtitle appearance | bool |  | `true` | Use semibold text so it stays readable over other apps. |
| `listening.floating_lyric_line_height` | Line height | 行高 | Floating subtitle appearance | number | 0.8 – 2.0 | `1.25` | Adjust the vertical spacing of wrapped lines. |
| `listening.floating_lyric_letter_spacing` | Letter spacing | 字间距 | Floating subtitle appearance | number | -2.0 – 12.0 | `0.0` | Adjust spacing between characters without changing lookup hit testing. |
| `listening.floating_lyric_text_alignment` | Text alignment | 文字对齐 | Floating subtitle appearance | choice | `0`, `1` | `0` |  |
| `listening.floating_lyric_text_padding` | Horizontal text padding | 文字左右边距 | Floating subtitle appearance | number | 0.0 – 60.0 | `16.0` | Keep text away from the window edges and resize grip. |
| `listening.floating_lyric_color_text` | Text color | 文字颜色 | Floating subtitle appearance | text |  | `theme` | theme（跟随主题）或 #RRGGBB / #AARRGGBB |
| `listening.floating_lyric_color_current` | Current sentence color | 当前句颜色 | Floating subtitle appearance | text |  | `theme` | theme（跟随主题）或 #RRGGBB / #AARRGGBB |
| `listening.floating_lyric_color_background` | Window background color | 窗口背景颜色 | Floating subtitle appearance | text |  | `theme` | theme（跟随主题）或 #RRGGBB / #AARRGGBB |
| `listening.floating_lyric_bg_opacity` | Floating subtitle background opacity | 悬浮字幕背景不透明度 | Floating subtitle appearance | number | 0.0 – 100.0 | `70.0` |  |
| `listening.floating_lyric_text_opacity` | Floating subtitle text opacity | 悬浮字幕文字透明度 | Floating subtitle appearance | number | 0.0 – 100.0 | `100.0` |  |
| `listening.floating_lyric_context_opacity` | Other sentences opacity | 其余句不透明度 | Floating subtitle appearance | number | 0.0 – 100.0 | `55.0` | How strongly sentences other than the current one are dimmed when several are shown. |
| `listening.floating_lyric_button_bg_opacity` | Floating subtitle button background opacity | 悬浮字幕按钮底色透明度 | Floating subtitle appearance | number | 0.0 – 100.0 | `100.0` |  |
| `listening.floating_lyric_outline_width` | Outline width | 描边宽度 | Floating subtitle appearance | number | 0.0 – 6.0 | `0.0` | Set to 0 to disable the outline; the subtle shadow remains. |
| `listening.floating_lyric_color_outline` | Outline color | 描边颜色 | Floating subtitle appearance | text |  | `theme` | theme（跟随主题）或 #RRGGBB / #AARRGGBB |
| `listening.floating_lyric_corner_radius` | Floating subtitle corner radius | 悬浮字幕圆角 | Floating subtitle appearance | number | 0.0 – 48.0 | `24.0` | 0 gives square corners; raise it to round the bar and buttons more (default 24) |
| `listening.floating_lyric_width` | Floating subtitle width | 悬浮字幕宽度 | Floating subtitle appearance | number | 0.0 – 1200.0 | `0.0` | 0 uses the platform default width; set a value to make the bar a fixed width |

## Manga (漫画)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `manga.reader_mode` | Reading mode | 阅读模式 | Viewing and page turning | choice | `auto`, `spread`, `paged_vertical`, `webtoon`, `webtoon_gaps` | `auto` |  |
| `manga.reading_direction` | Reading direction | 阅读方向 | Viewing and page turning | choice | `rtl`, `ltr` | `rtl` |  |
| `manga.page_animation` | Page turn animation | 翻页动画 | Viewing and page turning | choice | `none`, `slide`, `cover`, `fade`, `curl` | `slide` |  |
| `manga.page_animation_speed` | Animation speed | 动画速度 | Viewing and page turning | choice | `fast`, `normal`, `slow` | `normal` |  |
| `manga.page_turn_follow_drag` | Follow finger while dragging | 拖动跟手 | Viewing and page turning | bool |  | `true` | The page moves with your finger; release past a quarter of the width or flick to turn, otherwise it springs back |
| `manga.swipe_page_turn_sensitivity` | Swipe page-turn sensitivity | 滑动翻页灵敏度 | Viewing and page turning | number | 0.5 – 3.0 | `1.0` |  |
| `manga.tap_zone_paging` | Tap edges to turn pages | 点击边缘翻页 | Viewing and page turning | bool |  | `true` | Tap the left or right edge of the page to turn |
| `manga.tap_zone_layout` | Tap zone layout | 点击区域布局 | Viewing and page turning | choice | `left_right`, `l_shaped`, `kindle`, `top_bottom` | `left_right` | Where a tap turns the page |
| `manga.resume_target` | Reopen at | 重新打开时 | Viewing and page turning | choice | `furthest`, `last` | `furthest` | Online manga only: continue with the next chapter once the last one is finished, or return to the page you left. |
| `manga.reverse_arrow_page_turn` | Reverse arrow-key page turns | 反转键盘左右键翻页方向 | Viewing and page turning | bool |  | `false` | Swap what the Left and Right arrow keys do in the manga reader. Separate from the book reader's setting; the gamepad D-pad is not affected. |
| `manga.volume_key_paging` | Volume keys turn pages | 音量键翻页 | Viewing and page turning | bool |  | `true` | Use volume up and down to turn pages in the manga reader · *only on android* |
| `manga.reader_scale` | Image scaling | 图片缩放 | Display and zoom | choice | `fit_screen`, `stretch`, `fit_width`, `fit_height`, `original`, `smart` | `fit_screen` |  |
| `manga.default_zoom` | Default zoom | 默认缩放 | Display and zoom | number | 50.0 – 400.0 | `100.0` |  |
| `manga.zoom_sensitivity` | Zoom sensitivity | 缩放灵敏度 | Display and zoom | number | 25.0 – 400.0 | `100.0` |  |
| `manga.background` | Background | 背景色 | Display and zoom | choice | `black`, `white`, `gray`, `theme` | `black` |  |
| `manga.chrome_floating` | Floating toolbar | 悬浮工具栏 | Display and zoom | bool |  | `true` | Hide the toolbar over the page; tap the middle of the page or hover at the top edge to reveal it. Off keeps the toolbar pinned above the page. |
| `manga.controls_editor` | Toolbar layout | 工具栏布局 | Display and zoom | text |  | `{"wide":{"version":1,"slots":{"top":["ocrCancel","fullscreen","bookmarks","settings","ocrVolume","statistics","studyTimer","textStrip","backToStart","ocrRerun","hideChrome"],"toolbar":["chapters","pageGrid","readingMode","spreadPreference","direction","quickSettings","readAloud","ocrBoxes"],"overflow":[]}},"compact":{"version":1,"slots":{"top":["ocrCancel","fullscreen","bookmarks","settings","ocrVolume","statistics","studyTimer","textStrip","backToStart","ocrRerun","hideChrome"],"toolbar":["chapters","pageGrid","readingMode","spreadPreference","direction","quickSettings","readAloud","ocrBoxes"],"overflow":[]}}}` | {"wide": <布局 JSON，含 slots>, "compact": <布局 JSON>}（config get 的输出可改后原样写回） |
| `manga.spread_offset` | Spread offset | 跨页偏移 | Spreads and panels | choice | `1`, `0` | `1` | Which page the two-page pairing starts from |
| `manga.wide_page_solo` | Wide pages alone | 宽页独占一屏 | Spreads and panels | bool |  | `true` | Show a double-width spread page on its own |
| `manga.panel_navigation` | AI panel navigation | AI 分镜逐格导航 | Spreads and panels | bool |  | `false` | Focus detected panels before turning the page |
| `manga.mining_crop_to_panel` | Crop one-click cards to the panel | 一键制卡默认裁到所在分镜 | Spreads and panels | bool |  | `false` | Needs the panel model; without it the whole page is used. |
| `manga.online_catalog_base_url` | Online catalog URL | 在线目录地址 | Online catalog | text |  | `https://mokuro.moe` | Index address of the manga extension repository |
| `manga.cover_cache_max_age` | Cover cache retention | 封面缓存保留时长 | Online catalog | number | 30.0 – 360.0 | `180.0` | Online source covers are re-downloaded after this many days |

## Video (视频)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `video.playback.auto_play_next` | Auto-play next episode | 自动连播下一集 | Playback | bool |  | `true` |  |
| `video.playback.resume_mode` | Resume playback | 断点续播 | Playback | choice | `off`, `longVideos`, `all` | `all` | Reopen a video where you left off. Long videos are 10 minutes or more. Progress is still saved when this is off. |
| `video.playback.playlist_order` | Next episode order | 连播顺序 | Playback | choice | `sequential`, `shuffle` | `sequential` | Which episode auto-play moves on to. Shuffle picks a random episode from the series without repeats until all have played; for repeat-one use Loop file |
| `video.playback.theme_song_auto_skip` | Skip intros and credits automatically | 自动跳过片头片尾 | Playback | bool |  | `false` | When an OP or ED recognized from your music library starts, jump straight to its end |
| `video.playback.slim_progress_bar` | Slim progress bar at the bottom | 底部细进度条 | Playback | bool |  | `false` | When the controls fade out, keep a thin accent-coloured progress line along the very bottom of the video. In the mini window it is always shown, since the full seek bar is hidden there. |
| `video.playback.youtube_quality` | YouTube quality | YouTube 画质 | Playback | choice | `0`, `480`, `720`, `1080`, `1440`, `2160` | `0` | Auto = smooth first (≤1080p); pick 2160p for 4K |
| `video.quality.loop` | Loop file | 单文件循环 | Playback | bool |  | `false` |  |
| `video.playback.immersive_mode` | Immersive mode | 沉浸模式 | Immersive mode | choice | `full`, `shortcutAndLookup`, `lookupOnly`, `unlockOnly` | `shortcutAndLookup` | Controls what remains available after pressing the side lock button |
| `video.playback.immersive_tap_reveal` | Tap picture to show subtitles | 沉浸时点画面显示字幕 | Immersive mode | bool |  | `true` | When subtitles are blurred or hidden, tap the picture to show the current line; it hides again when the line changes |
| `video.player.immersive_controls_editor` | video.player.immersive_controls_editor | video.player.immersive_controls_editor | Immersive mode | text |  | `{"version":1,"slots":{"screenLeft":["immersiveLock"],"screenRight":[]},"removed":["previousCue","replayCue","nextCue","favoriteSentence","playPause","seekBackward","seekForward"]}` | <沉浸布局 JSON，含 version 与 slots>；空串 = 恢复默认 |
| `video.controls.reset_immersive_layout` | Reset immersive mode buttons | 恢复默认沉浸模式按钮 | Immersive mode | action |  |  |  |
| `video.playback.disc_auto_fullscreen` | Full screen for disc playback | 播放原盘时自动全屏 | Disc (Blu-ray / DVD) | bool |  | `true` | Desktop only. Leaving the disc restores the previous window size, position and maximized state. · *only on windows, macos* |
| `video.playback.disc_launch_animation` | Disc launch animation | 原盘启动动画 | Disc (Blu-ray / DVD) | bool |  | `true` | Play a disc loading animation when entering a disc |
| `video.playback.disc_open_menu_by_default` | Open disc menu by default | 原盘默认进入菜单 | Disc (Blu-ray / DVD) | bool |  | `true` | When off, the play button starts the main title directly. |
| `video.playback.picture_fit` | Picture scaling | 画面缩放 | Picture and subtitles › Picture and quality › Scaling and aspect ratio | choice | `cover`, `contain`, `fill` | `contain` | How the picture fills the player area |
| `video.playback.lock_window_aspect` | Lock window to video aspect | 锁定窗口为视频比例 | Picture and subtitles › Picture and quality › Scaling and aspect ratio | bool |  | `false` | Keep the video's aspect ratio when resizing the window, with no black bars · *only on windows, macos* |
| `video.playback.entry_orientation` | Orientation when opening videos | 进入视频时的方向 | Picture and subtitles › Picture and quality › Scaling and aspect ratio | choice | `landscape`, `video_aspect`, `sensor` | `landscape` | Switch any time with the rotate button in the player · *only on android, ios* |
| `video.playback.portrait_subtitle_list` | Subtitle list in portrait | 竖屏时显示字幕列表 | Picture and subtitles › Picture and quality › Scaling and aspect ratio | bool |  | `true` | Video on top, the current line and subtitle list below · *only on android, ios* |
| `video.playback.background_play` | Keep playing audio in background | 后台继续播放声音 | Picture and subtitles › Picture and quality › Scaling and aspect ratio | bool |  | `false` | Sound keeps playing after you leave the app or lock the screen; the picture comes back when you return · *only on android, ios* |
| `video.playback.remember_orientation` | Remember orientation per title | 记住每部作品的方向 | Picture and subtitles › Picture and quality › Scaling and aspect ratio | bool |  | `false` | Reopen a title in the orientation you last switched to · *only on android, ios* |
| `video.geometry.aspect` | Aspect ratio | 画面比例 | Picture and subtitles › Picture and quality › Scaling and aspect ratio | choice | `-1`, `16:9`, `4:3`, `2.35:1`, `1:1` | `-1` |  |
| `video.geometry.rotate` | Rotation | 旋转 | Picture and subtitles › Picture and quality › Scaling and aspect ratio | choice | `0`, `90`, `180`, `270` | `0` |  |
| `video.geometry.zoom` | Zoom | 缩放 | Picture and subtitles › Picture and quality › Scaling and aspect ratio | number | -2.0 – 2.0 | `0.0` |  |
| `video.geometry.panscan` | Pan & scan (crop borders) | 平移裁切（去黑边） | Picture and subtitles › Picture and quality › Scaling and aspect ratio | number | 0.0 – 1.0 | `0.0` |  |
| `video.quality.enhancement` | Quality enhancement | 画质增强 | Picture and subtitles › Picture and quality › Image quality | bool |  | `true` | Turn this on to sharpen the picture with mpv's built-in high-quality scaling. Works for anime as well as live-action shows and movies. To go further with shaders like Anime4K, open Image enhancement while a video is playing and pick a level there. |
| `video.quality.hwdec` | Hardware decoding | 硬件解码 | Picture and subtitles › Picture and quality › Image quality | choice | `no`, `auto-safe`, `auto-copy` | `auto-safe` | Decoding on the GPU saves power; switch back to software decoding if the picture glitches or stutters |
| `video.quality.sigmoid` | Sigmoid upscaling | S形上采样 | Picture and subtitles › Picture and quality › Image quality | bool |  | `false` | Sigmoid-curve upscaling reduces ringing but costs GPU. Off by default for performance; turn on if you want sharper upscaling. |
| `video.quality.deband` | Debanding | 去色带 | Picture and subtitles › Picture and quality › Image quality | bool |  | `false` |  |
| `video.quality.dither` | Dithering | 抖动 | Picture and subtitles › Picture and quality › Image quality | bool |  | `false` |  |
| `video.quality.interpolation` | Motion interpolation | 运动插帧 | Picture and subtitles › Picture and quality › Image quality | bool |  | `false` |  |
| `video.quality.deinterlace` | Deinterlace | 去隔行 | Picture and subtitles › Picture and quality › Image quality | bool |  | `false` |  |
| `video.quality.correct_downscale` | Linear downscaling | 线性降采样 | Picture and subtitles › Picture and quality › Image quality | bool |  | `false` |  |
| `video.quality.windows_black_flash_notice` | video.quality.windows_black_flash_notice | video.quality.windows_black_flash_notice | Picture and subtitles › Picture and quality › Image quality | custom |  |  | *only on windows* |
| `video.playback.hdr_output` | HDR / 10-bit output | HDR / 10-bit 输出 | Picture and subtitles › Picture and quality › HDR | choice | `auto`, `always`, `off` | `auto` | Auto: output HDR when the display is in HDR mode and the video is HDR. Off: always show SDR. · *only on windows* |
| `video.hdr.tone_mapping` | HDR tone mapping | HDR 色调映射 | Picture and subtitles › Picture and quality › HDR | choice | `auto`, `bt.2390`, `bt.2446a`, `spline`, `reinhard`, `mobius`, `hable`, `clip` | `auto` | Curve used when an HDR source has to be squeezed onto an SDR display. Auto lets mpv pick per source. |
| `video.hdr.compute_peak` | Dynamic peak detection | 动态峰值检测 | Picture and subtitles › Picture and quality › HDR | choice | `auto`, `yes`, `no` | `auto` | Measure each frame's real peak brightness instead of trusting the stream metadata. Better highlights, costs some GPU. |
| `video.color.brightness` | Brightness | 亮度 | Picture and subtitles › Picture and quality › Color | number | -100.0 – 100.0 | `0.0` |  |
| `video.color.contrast` | Contrast | 对比度 | Picture and subtitles › Picture and quality › Color | number | -100.0 – 100.0 | `0.0` |  |
| `video.color.saturation` | Saturation | 饱和度 | Picture and subtitles › Picture and quality › Color | number | -100.0 – 100.0 | `0.0` |  |
| `video.color.gamma` | Gamma | 伽马 | Picture and subtitles › Picture and quality › Color | number | -100.0 – 100.0 | `0.0` |  |
| `video.color.hue` | Hue | 色相 | Picture and subtitles › Picture and quality › Color | number | -100.0 – 100.0 | `0.0` |  |
| `video.subtitle.preview` | Subtitle preview | 字幕预览 | Picture and subtitles › Subtitles › Appearance | custom |  |  |  |
| `video.subtitle.font_size` | Font size | 字号 | Picture and subtitles › Subtitles › Appearance | number | 12.0 – 48.0 | `36.0` |  |
| `video.subtitle.font_weight` | Font weight | 字重 | Picture and subtitles › Subtitles › Appearance | number | 100.0 – 900.0 | `400.0` |  |
| `video.player.subtitle_text_color` | Text color | 文字颜色 | Picture and subtitles › Subtitles › Appearance | text |  | `#FFFFFFFF` | #RRGGBB 或 #AARRGGBB |
| `video.subtitle.shadow` | Shadow | 阴影 | Picture and subtitles › Subtitles › Appearance | number | 0.0 – 12.0 | `3.0` |  |
| `video.player.subtitle_shadow_color` | Shadow color | 阴影颜色 | Picture and subtitles › Subtitles › Appearance | text |  | `#E6000000` | #RRGGBB 或 #AARRGGBB |
| `video.subtitle.outline` | Outline width | 描边粗细 | Picture and subtitles › Subtitles › Appearance | number | 0.0 – 8.0 | `0.0` |  |
| `video.player.subtitle_outline_color` | Outline color | 描边颜色 | Picture and subtitles › Subtitles › Appearance | text |  | `#FF000000` | #RRGGBB 或 #AARRGGBB |
| `video.subtitle.bg_opacity` | Background opacity | 背景不透明度 | Picture and subtitles › Subtitles › Appearance | number | 0.0 – 1.0 | `0.0` |  |
| `video.player.subtitle_bg_color` | Background color | 背景颜色 | Picture and subtitles › Subtitles › Appearance | text |  | `#FF000000` | #RRGGBB 或 #AARRGGBB |
| `video.subtitle.respect_ass_style` | Respect subtitle's own style | 尊重字幕自带样式 | Picture and subtitles › Subtitles › Appearance | bool |  | `true` | Use the font, color, and outline built into .ass subtitles when available; turn off to force your appearance settings. |
| `video.subtitle.anchor` | Main subtitle anchor | 主字幕锚定 | Picture and subtitles › Subtitles › Position | choice | `bottom`, `top` | `bottom` |  |
| `video.subtitle.position` | Vertical position | 垂直位置 | Picture and subtitles › Subtitles › Position | number | 0.0 – 400.0 | `75.0` |  |
| `video.subtitle.position_secondary` | Secondary subtitle position | 副字幕垂直位置 | Picture and subtitles › Subtitles › Position | number | 0.0 – 400.0 | `75.0` |  |
| `video.subtitle.drag_adjust` | Drag to adjust position | 拖拽调整位置 | Picture and subtitles › Subtitles › Position | action |  |  | Drag a subtitle up or down to reposition it |
| `video.subtitle.preferred_languages` | Default subtitle languages | 主字幕默认语言 | Picture and subtitles › Subtitles › Track selection | text |  |  | With several subtitle tracks, pick the first one that matches, in order (comma-separated; & means all must match). Empty = first text track. |
| `video.subtitle.secondary_preferred_languages` | Default secondary subtitle languages | 副字幕默认语言 | Picture and subtitles › Subtitles › Track selection | text |  |  | Same format as above. Empty = no secondary subtitle by default. |
| `video.subtitle.obscure` | Obscure subtitles | 字幕遮蔽 | Picture and subtitles › Subtitles › Listening practice | choice | `none`, `blur`, `hide` | `none` | Choose how subtitles are obscured for listening practice: off, blurred (hover or tap to reveal), or hidden. |
| `video.subtitle.obscure_reveal` | Primary: reveal when paused or hovered | 主字幕暂停或悬停时显形 | Picture and subtitles › Subtitles › Listening practice | bool |  | `true` | While the primary subtitle is blurred or hidden, pausing, looking a word up, hovering (desktop) or tapping it reveals it temporarily. Turn this off to keep it obscured no matter what. |
| `video.secondary_subtitle.obscure` | Obscure secondary subtitle | 副字幕遮蔽 | Picture and subtitles › Subtitles › Listening practice | choice | `none`, `blur`, `hide` | `none` | Blur or hide the secondary (translation) subtitle |
| `video.secondary_subtitle.obscure_reveal` | Secondary: reveal when paused or hovered | 副字幕暂停或悬停时显形 | Picture and subtitles › Subtitles › Listening practice | bool |  | `true` | Same as the primary subtitle switch, but for the secondary (translation) subtitle. Turn it off to keep the translation obscured even while the primary subtitle is revealed. |
| `video.subtitle.mask_enabled` | Subtitle mask | 字幕遮布 | Picture and subtitles › Subtitles › Burned-in subtitles | bool |  | `false` | Cover subtitles burned into the picture (e.g. built-in Chinese subtitles); Fushi subtitles stay on top |
| `video.subtitle.mask_mode` | Positioning | 定位方式 | Picture and subtitles › Subtitles › Burned-in subtitles | choice | `manual`, `smart` | `manual` | Smart finds burned-in subtitles with on-device OCR and only covers them while they are on screen; the box becomes the search area |
| `video.subtitle.mask_style` | Mask look | 遮布外观 | Picture and subtitles › Subtitles › Burned-in subtitles | choice | `blur`, `solid` | `blur` |  |
| `video.subtitle.mask_strength` | Mask strength | 遮布强度 | Picture and subtitles › Subtitles › Burned-in subtitles | number | 0.1 – 1.0 | `0.85` |  |
| `video.subtitle.mask_adjust` | Adjust mask position | 调整遮布位置 | Picture and subtitles › Subtitles › Burned-in subtitles | action |  |  | Drag to move, drag corners to resize |
| `video.subtitle.pause_ocr_scope` | Recognize on-screen text when paused | 暂停时识别画面文字 | Picture and subtitles › Subtitles › Burned-in subtitles | choice | `all`, `graphicSubtitles`, `off` | `off` | OCR the paused frame so its text can be tapped for lookup. Text subtitle tracks don't affect it. |
| `services.subtitle_default_language` | Language for subtitle search | 搜索字幕的语言 | Picture and subtitles › Subtitles › Fetching and alignment | choice | , `ja`, `zh`, `en`, `ko` |  | Defaults to the video's own language (audio track / scraped metadata). Pick one to always prefer that language instead. |
| `video.subtitle.reference_sync` | Auto-align downloaded subtitles | 下载字幕自动对齐 | Picture and subtitles › Subtitles › Fetching and alignment | bool |  | `true` | Retime downloaded subtitles to the video's embedded subtitle tracks. Applied only when the evidence is strong; otherwise the file is left as-is. |
| `video.subtitle.backfill_after_scrape` | Auto-fetch subtitles after scraping | 刮削后自动补字幕 | Picture and subtitles › Subtitles › Fetching and alignment | bool |  | `true` | When a scrape finishes, videos that still have no subtitle get one from your configured online sources. Never replaces an existing subtitle. |
| `video.subtitle.auto_upload_to_host` | Auto-upload imported subtitles to host | 导入的字幕自动上传到服务端 | Picture and subtitles › Subtitles › Fetching and alignment | bool |  | `true` | When playing a video from a connected host, subtitles you import or retime are uploaded and set as that episode's default for every device. Turn off to keep them on this device only. |
| `video.audio.channels` | Channels | 声道 | Audio | choice | `auto-safe`, `stereo`, `mono` | `auto-safe` | Output channel layout; choose Auto if unsure |
| `video.audio.volume_max` | Volume limit | 音量上限 | Audio | choice | `100`, `150`, `200` | `100` | Above 100% the player boosts the audio in software; very high values can distort |
| `video.audio.pitch` | Preserve pitch when speeding | 变速保持音高 | Audio | bool |  | `true` |  |
| `video.audio.normalize_downmix` | Normalize downmix loudness | 下混响度归一化 | Audio | bool |  | `false` |  |
| `video.audio.passthrough` | Dolby / DTS passthrough | 杜比 / DTS 直通 | Audio | bool |  | `false` | Send AC-3, E-AC-3, TrueHD and DTS-HD untouched to your receiver or soundbar so it decodes them (Atmos included). Only turn on if that device supports these formats — otherwise there may be no sound. While passing through, set the volume on the receiver: Fushi's volume and mute can't act on these streams, so at any speed other than 1×, below full volume or when muted, Fushi decodes them itself for the time being (the receiver's Atmos / DTS indicator goes off). When off, Fushi always decodes them and 5.1 / 7.1 still play as surround. |
| `video.playback.double_tap` | Double-tap seek | 双击快进 | Controls and gestures | choice | `0`, `3`, `5`, `10`, `-1` | `0` | Double-tap the left or right of the video to seek |
| `video.playback.tap_toggles_playback` | Tap video to play/pause | 点击画面播放/暂停 | Controls and gestures | bool |  | `true` | Turn off so tapping the video only reveals the controls · *only on windows, macos* |
| `video.playback.double_tap_toggles_playback` | Double-tap video to play/pause | 双击画面播放/暂停 | Controls and gestures | bool |  | `true` | On touch screens, double-tapping the middle of the video (or anywhere when double-tap seek is off) toggles playback |
| `video.playback.long_press_speed` | Long-press speed | 长按倍速 | Controls and gestures | number | 1.0 – 4.0 | `2.0` | Temporarily use this speed while holding the video. |
| `video.playback.seek_seconds` | Seek seconds | 快进/快退步长（秒） | Controls and gestures | number | 1.0 – 30.0 | `3.0` |  |
| `video.playback.drag_seek_sensitivity` | Drag-to-seek sensitivity | 拖动调进度灵敏度 | Controls and gestures | choice | `low`, `medium`, `high` | `medium` | How much time a full-width swipe covers: Low about 45s, Medium about 90s, High about 180s. · *only on android, ios* |
| `video.playback.brightness_swipe_gesture` | Swipe to adjust brightness | 竖滑调节亮度 | Controls and gestures | bool |  | `true` | Swipe up/down on the left half of the video to change screen brightness. Turn off to use the system brightness slider instead · *only on android, ios* |
| `video.playback.volume_swipe_gesture` | Swipe to adjust volume | 竖滑调节音量 | Controls and gestures | bool |  | `true` | Swipe up/down on the right half of the video to change volume. Turn off to use the physical volume buttons instead · *only on android, ios* |
| `video.controls.reset_layout` | Reset player button layout | 恢复默认播放器按钮布局 | Controls and gestures | action |  |  |  |
| `video.danmaku.enabled` | Show danmaku | 显示弹幕 | Danmaku | bool |  | `false` | Render local or matched danmaku over the video without blocking controls. |
| `video.danmaku.online` | Online Dandanplay match | 在线匹配 Dandanplay | Danmaku | bool |  | `true` | When there is no local comment file, match the current video with Dandanplay. |
| `video.danmaku.max_active` | Active danmaku limit | 同时显示上限 | Danmaku | number | 10.0 – 200.0 | `80.0` | Caps comments rendered per frame to keep large files responsive. |
| `video.live_chat.auto_open` | Open chat replay automatically | 有聊天回放时自动打开聊天栏 | Danmaku | bool |  | `false` | When a YouTube stream archive has a chat replay, open the chat panel as playback starts |
| `video.live_chat.show_author` | Show names in chat replay | 聊天栏显示用户名 | Danmaku | bool |  | `true` | Show who sent each message above it |
| `video.playback.screenshot_destination` | Screenshot destination | 截图去向 | Screenshots and clips | choice | `ask`, `clipboard`, `directory` | `ask` | Where screenshots go: a save dialog, the clipboard, or straight into a folder |
| `video.playback.screenshot_directory` | Screenshot folder | 截图保存目录 | Screenshots and clips | action |  |  |  |
| `video.playback.clip_export_video_bitrate` | Clip export video bitrate | 片段导出视频码率 | Screenshots and clips | number | 0 – 100000 | `0` | 0 = follow the source (the stream is copied when possible); any other value re-encodes the video at that bitrate |
| `video.library.scrape_auto_backfill` | Auto-fill missing series info | 自动补齐缺失的作品资料 | Library and scraping | bool |  | `true` | Entering the video library scrapes entries that still have no confirmed identity. Turn off to stop all background metadata downloads. |
| `video.library.metadata_primary_provider` | Primary metadata source | 主资料源 | Library and scraping | choice | `anidb`, `mal`, `tmdb` | `anidb` | The other source is used as a fallback when the primary source has no exact match or is unavailable. |
| `video.library.metadata_locale` | Metadata language | 资料语言 | Library and scraping | text |  |  | Preferred language for TMDB fallback and supplementary details. MAL uses the titles and text supplied by MAL. |
| `video.library.video_metadata_max_covers` | Covers kept per work | 每部作品保留的封面数 | Library and scraping | number | 0.0 – 30.0 | `10.0` | 0 = unlimited. Best-rated images are kept in the order: metadata language, original language, English, textless. |
| `video.library.video_metadata_max_backdrops` | Backdrops kept per work | 每部作品保留的背景图数 | Library and scraping | number | 0.0 – 30.0 | `10.0` | 0 = unlimited. Best-rated images are kept in the order: metadata language, original language, English, textless. |
| `video.library.video_metadata_max_logos` | Logos kept per work | 每部作品保留的 Logo 数 | Library and scraping | number | 0.0 – 30.0 | `10.0` | 0 = unlimited. Best-rated images are kept in the order: metadata language, original language, English, textless. |
| `video.library.metadata_download_staff_images` | Download cast & staff photos | 下载演职员头像 | Library and scraping | bool |  | `false` | Save cast/staff profile photos locally while scraping (up to 10 per work). Off: photos load from TMDB on demand. |
| `video.library.metadata_identifier_words` | Identifier words | 识别词 | Library and scraping | action |  |  | Rewrite, block or offset titles before they are matched |
| `video.library.scrape_records_clear_all` | Clear all scrape records | 清理全部刮削记录 | Library and scraping | action |  |  | Remove all video scrape metadata, optionally together with the NFO and image files Fushi generated. · *destructive* |
| `video.player.mpv_lua_scripts_import` | Import Lua scripts | 导入 Lua 脚本 | Advanced | action |  |  | Every .lua file in the mpv_scripts folder loads when a video plays. Deleting a script takes effect the next time you open a video. |
| `video.player.mpv_lua_scripts_list` | video.player.mpv_lua_scripts_list | video.player.mpv_lua_scripts_list | Advanced | list |  |  |  |
| `video.player.mpv_lua_scripts_dir` | Copy scripts folder path | 复制脚本目录路径 | Advanced | action |  |  |  |
| `video.player.quality_entry` | video.player.quality_entry | video.player.quality_entry |  | custom |  |  |  |
| `video.player.speed` | Playback speed | 播放速度 |  | number |  |  |  |
| `video.playback.speed_step` | Speed step | 倍速步进 |  | number | 0.05 – 0.5 | `0.1` |  |
| `video.player.audio_track` | video.player.audio_track | video.player.audio_track |  | custom |  |  |  |
| `video.player.subtitle_track` | video.player.subtitle_track | video.player.subtitle_track |  | custom |  |  |  |
| `video.player.subtitle_sync` | video.player.subtitle_sync | video.player.subtitle_sync |  | custom |  |  |  |
| `video.subtitle.no_background` | No background | 无背景 |  | action |  |  | Make the subtitle background transparent. |
| `video.player.subtitle_style_reset` | Reset to default | 恢复默认 |  | action |  |  |  |
| `video.player.shaders` | video.player.shaders | video.player.shaders |  | list |  |  |  |
| `video.player.mpv_raw` | video.player.mpv_raw | video.player.mpv_raw |  | text |  |  | 多行 mpv.conf 文本（key=value，每行一条） |
| `video.player.mpv_reset` | Reset all | 全部恢复默认 |  | action |  |  |  |
| `video.danmaku.font_scale` | Font size | 字号 |  | number | 0.5 – 2.0 | `1.0` | Scale the danmaku text size. |
| `video.danmaku.opacity` | Opacity | 不透明度 |  | number | 0.1 – 1.0 | `1.0` | Overall danmaku transparency. |
| `video.danmaku.speed` | Speed | 速度 |  | number | 0.5 – 2.0 | `1.0` | Higher is faster; scrolling danmaku cross the screen sooner. |
| `video.danmaku.area` | Display area | 显示区域 |  | number | 0.25 – 1.0 | `1.0` | Fraction of the screen height danmaku may occupy, from the top. |
| `video.player.danmaku_block_rules` | video.player.danmaku_block_rules | video.player.danmaku_block_rules |  | text |  |  | 多行文本，每行一条；/pattern/ 为正则，其余为子串 |
| `video.player.controls_editor` | video.player.controls_editor | video.player.controls_editor |  | text |  | `{"layout":{"version":3,"slots":{"bottomLeft":["playPause","positionIndicator"],"bottomCenter":[],"bottomRight":["volume","subtitleTrack","liveChat","speed","fullscreen"],"screenLeft":["immersiveLock"],"screenRight":["subtitleList"],"topLeft":["back"],"topCenter":["title"],"topRight":["episodeList","chapterList","screenshot","settings"]},"removed":["favoriteSentence","seekBackward","seekForward","frameBackward","frameForward","previousCue","nextCue","replayCue","clipExport","audioTrack","previousEpisode","nextEpisode","previousChapter","nextChapter","danmaku","ocrFrame","statistics","studyTimer","customAction1","customAction2","customAction3","customAction4"]},"customActions":""}` | {"layout": <布局 JSON，含 version 与 slots>, "customActions": "动作key,动作key,,"}（config get 的输出可改后原样写回） |

## Music (音乐)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `music.gapless` | Gapless playback | 无缝播放 | Playback | bool |  | `true` | Preload the next track so albums play without gaps |
| `music.resume_mode` | Resume playback | 断点续播 | Playback | choice | `off`, `longTracks`, `all` | `longTracks` | Reopen a track where you left off. Long tracks are 8 minutes or more. Apple Music tracks always start from the beginning. |
| `music.crossfade` | Crossfade | 交叉淡入 | Playback | number | 0.0 – 12.0 | `0.0` | Fade between tracks; no longer bit-perfect, and turned off automatically with exclusive output. |
| `music.crossfade_continuous` | Crossfade gapless tracks too | 连续曲目也淡入 | Playback | bool |  | `false` |  |
| `music.plugin_quality` | Online plugin quality | 在线插件默认音质 | Playback | choice | `standard`, `high`, `lossless`, `hires` | `lossless` | Can also be switched per track in the player |
| `music.replaygain` | ReplayGain | ReplayGain 响度均衡 | Loudness | bool |  | `true` | Album gain when playing an album in order, track gain otherwise |
| `music.replaygain_preamp` | ReplayGain pre-amp | ReplayGain 预放大 | Loudness | number | -15.0 – 15.0 | `0.0` | Raise or lower overall volume on top of ReplayGain |
| `music.loudness_scan` | Measure loudness of untagged tracks | 为无 ReplayGain 标签的曲目测量响度 | Loudness | bool |  | `true` | EBU R128 scan in the background. Results are stored in the library; your files are not modified. |
| `music.loudness_scan_now` | Measure loudness now | 立即测量响度 | Loudness | action |  |  | Measure every track in the library that has not been measured yet |
| `music.exclusive` | Exclusive (bit-perfect) output | 独占（bit-perfect）输出 | Audio output | bool |  | `false` | Bypass the system mixer so the DAC gets the source samples unchanged. Other apps are silent while music plays. |
| `music.audio_device` | Output device | 输出设备 | Audio output | action |  |  |  |
| `music.dsd_rate` | DSD to PCM sample rate | DSD 转 PCM 采样率 | Audio output | choice | `176400`, `352800` | `176400` | Sample rate used when converting to PCM if the DAC has no native DSD support |
| `music.acoustid_api_key` | AcoustID API key | AcoustID API key | Library identification | secret |  |  | Built in; enter your own AcoustID application key to override it. Only the fingerprint and duration are sent. · *user only* |
| `music.vgmdb` | VGMdb lookup | VGMdb 补充 | Library identification | bool |  | `false` | Community mirror without an official API; queried slowly, by catalog number only |
| `music.identify_library` | Identify library | 识别整个曲库 | Library identification | action |  |  | MusicBrainz, at most one request per second |
| `music.lyrics_online` | Online lyrics (LRCLIB) | 在线歌词（LRCLIB） | Lyrics | bool |  | `true` | When no local lyrics exist, match title, artist, album and duration on LRCLIB |
| `music.lyrics_lookup_pause` | Pause while looking up words | 查词时暂停 | Lyrics | bool |  | `true` | Pause playback while looking up a word on the lyrics page; resume when the popup closes |
| `music.lyrics_blur_inactive` | Blur surrounding lines | 模糊非当前行 | Lyrics | bool |  | `true` | Softly blur lyric lines other than the current one. Turn off to keep the previous and next lines sharp |
| `music.lyrics_show_translation` | Show translation | 显示翻译 | Lyrics | bool |  | `true` | Show the translated line under each lyric. Turn off to see the original only |
| `music.lyrics_show_romanization` | Show romanization | 显示罗马音 | Lyrics | bool |  | `true` | Show the romanized reading under each lyric |
| `music.lyrics_show_ruby` | Show furigana | 显示注音 | Lyrics | bool |  | `true` | Show readings that come with the lyrics source. Readings are never generated |
| `music.desktop_lyrics` | Desktop lyrics | 桌面歌词 | Lyrics | bool |  | `false` | Show the current lyric line in a floating always-on-top window while music plays |
| `music.lyrics_media_session` | Lyrics on the lock screen | 锁屏显示歌词 | Lyrics | bool |  | `true` | Show the current line as the subtitle of the media notification and lock screen |
| `music.karaoke_ass_render` | ASS karaoke subtitles | ASS 卡拉 OK 字幕 | Lyrics | choice | `auto`, `original`, `structured` | `auto` | Automatic: subtitles with effects render as authored; plain karaoke timing uses synced lyrics. |
| `music.lyrics_mv_backdrop` | Show the MV behind lyrics | 有 MV 时背景放 MV | Lyrics page background | bool |  | `true` | When the track has a local MV (bound, found next to it or on a nearby Blu-ray), the lyrics page and lyric animations play it muted behind the lyrics, aligned to the library audio. Turn off to always use the animated background. |
| `music.lyrics_backdrop_animate` | Background motion | 背景动效 | Lyrics page background | choice | `true`, `false` | `true` |  |
| `music.lyrics_backdrop_style` | Fluid style | 流体样式 | Lyrics page background | choice | `pixi`, `meshGradient`, `classic` | `pixi` | Switch the fluid background algorithm of the lyrics page |
| `music.lyrics_backdrop_saturation` | Background saturation | 背景饱和度 | Lyrics page background | number | 50.0 – 200.0 | `100.0` | Saturation of the lyrics page's fluid background; adjust it if the lyrics are hard to read on a background that is too bright or too dark |
| `music.visualizer_mode` | Animated lyrics style | 歌词动画样式 | Lyrics page background | choice | `luminous`, `mindscape`, `fume`, `partita`, `cappella`, `claddagh`, `monet`, `diorama`, `pendolo`, `sonnet`, `tempera`, `lumiere`, `nebbia`, `metaphor`, `hanabi`, `machi`, `tilt`, `still` | `luminous` |  |
| `music.visualizer_random` | Random style for each song | 每首歌随机样式 | Lyrics page background | bool |  | `false` | Switches to a different animation style when the song changes |
| `music.visualizer_ai_theme_auto` | Generate AI theme automatically | 自动生成 AI 主题 | Lyrics page background | bool |  | `false` | When the lyric animation opens on a song that has none yet. Needs an AI provider for this feature. |
| `music.visualizer_intensity` | Animation intensity | 动画强度 | Lyrics page background | choice | `calm`, `normal`, `chaotic` | `normal` | How lively lyric animations move; an AI theme can override it per song |
| `music.visualizer_background` | Animation background | 动画背景 | Lyrics page background | choice | `fluid`, `solid`, `common`, `monet`, `nomand`, `latent`, `url`, `sora` | `fluid` | Background drawn under lyric animation styles that use the shared background |
| `music.visualizer_font_scale` | Animated lyrics text size | 歌词动画字号 | Lyrics page background | number | 60.0 – 200.0 | `100.0` |  |
| `music.visualizer_subtitle_hide` | Hide animated lyrics subtitles | 隐藏歌词动画副字幕 | Lyrics page background | bool |  | `false` | Hides translations and the next-line preview |
| `music.visualizer_subtitle_content` | Animated lyrics subtitle content | 歌词动画副字幕内容 | Lyrics page background | choice | `translation`, `romanization`, `both`, `none` | `translation` | What the line under the lyrics shows |
| `music.visualizer_subtitle_font_scale` | Animated lyrics subtitle size | 歌词动画副字幕字号 | Lyrics page background | number | 60.0 – 200.0 | `100.0` |  |
| `music.visualizer_subtitle_font` | Animated lyrics subtitle font | 歌词动画副字幕字体 | Lyrics page background | choice | `inherit`, `sans`, `serif`, `mono` | `inherit` |  |
| `music.visualizer_models` | Audio analysis models | 音频分析模型 | Lyrics page background | action |  |  | Beat and drum detection for lyric animations; optional download |
| `music.effects.enabled` | Enable audio effects | 启用音效 | Audio effects | bool |  | `false` |  |
| `music.effects.preset` | Preset | 预设 | Audio effects | choice | `custom`, `flat`, `pop`, `rock`, `classical`, `jazz`, `vocal`, `electronic`, `bassBoost`, `trebleBoost`, `headphones`, `smallSpeakers` | `flat` |  |
| `music.effects.preamp` | Preamp | 前级 | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.band_31` | 31 Hz | 31 Hz | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.band_62` | 62 Hz | 62 Hz | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.band_125` | 125 Hz | 125 Hz | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.band_250` | 250 Hz | 250 Hz | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.band_500` | 500 Hz | 500 Hz | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.band_1000` | 1 kHz | 1 kHz | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.band_2000` | 2 kHz | 2 kHz | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.band_4000` | 4 kHz | 4 kHz | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.band_8000` | 8 kHz | 8 kHz | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.band_16000` | 16 kHz | 16 kHz | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.bass` | Bass | 低音 | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.bass_hz` | Bass turnover | 低音转折频率 | Audio effects | choice | `60`, `80`, `100`, `150`, `200`, `300` | `100` |  |
| `music.effects.treble` | Treble | 高音 | Audio effects | number | -12.0 – 12.0 | `0.0` |  |
| `music.effects.treble_hz` | Treble turnover | 高音转折频率 | Audio effects | choice | `3000`, `4000`, `6000`, `8000`, `10000`, `12000` | `8000` |  |
| `music.effects.balance` | Balance | 声道平衡 | Audio effects | number | -1.0 – 1.0 | `0.0` |  |
| `music.effects.width` | Stereo width | 立体声宽度 | Audio effects | number | 0.0 – 2.0 | `1.0` |  |
| `music.effects.mono` | Mono | 单声道 | Audio effects | bool |  | `false` |  |
| `music.effects.swap` | Swap left and right | 左右声道互换 | Audio effects | bool |  | `false` |  |
| `music.effects.limiter` | Anti-clipping limiter | 防削波限幅器 | Audio effects | bool |  | `false` |  |
| `music.effects.reset` | Reset all | 全部复位 | Audio effects | action |  |  |  |

## Game (游戏)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `game.ingame_lookup` | In-game dictionary lookup | 游戏内查词 | In-game lookup card | bool |  | `true` | Show the dictionary card inside the game window itself (KiriKiri engine, Windows only) · *only on windows* |
| `game.ingame_lookup_exe_hash` | Copy game executable SHA-256 | 复制游戏 exe 的 SHA-256 | In-game lookup card | action |  |  |  |
| `game.gal_card_lookup_independent_size` | Independent card size | 查词卡独立尺寸 | In-game lookup card | bool |  | `false` | Size the in-game lookup card separately from the desktop overlay card · *only on windows* |
| `game.gal_card_lookup_max_width` | In-game card max width | 游戏内查词卡最大宽度 | In-game lookup card | number | 250.0 – 2000.0 | `480.0` |  |
| `game.gal_card_lookup_max_height` | In-game card max height | 游戏内查词卡最大高度 | In-game lookup card | number | 200.0 – 1600.0 | `480.0` |  |
| `game.gal_hook_click_lookup` | Tap a word to look it up | 单击文字查词 | Caption overlay · interaction | bool |  | `true` | Off means clicks on the caption never trigger a lookup — useful with click-through on, when you would rather not hit a word by accident. · *only on windows* |
| `game.gal_hook_lookup_trigger` | Lookup trigger | 查词触发方式 | Caption overlay · interaction | choice | `0`, `1`, `2` | `0` | Which mouse button looks up the word under the pointer. Independent of the switch above: you can turn tap-lookup off and still look up with a side button. · *only on windows* |
| `game.gal_hook_passthrough_blocks_mouse` | Caption still catches clicks while clicking through | 穿透时台词仍拦截点击 | Caption overlay · interaction | bool |  | `true` | On: text lines still take clicks so you can tap a word. Off: the whole overlay is transparent to the mouse — you can click whatever is underneath, but tapping words no longer works. · *only on windows* |
| `game.gal_hook_toolbar_auto_hide` | Auto-hide the toolbar | 自动隐藏功能栏 | Caption overlay · interaction | bool |  | `true` | Hide the toolbar until the pointer reaches the caption box. · *only on windows* |
| `game.gal_hook_toolbar_labels` | Show button labels | 工具条显示文字 | Caption overlay · interaction | bool |  | `true` | Show a short caption under each overlay toolbar button; falls back to icons with hover tips when the overlay is too narrow · *only on windows* |
| `game.fold_progressive_lines` | Merge split dialogue lines | 合并分段吐出的台词 | Caption overlay · interaction | bool |  | `true` | Fold multiple snapshots of the same line into one. · *only on windows* |
| `game.gal_hook_text_font_size` | Font size | 字号 | Caption overlay · text | number | 12.0 – 72.0 | `30.0` | Dragging the overlay's corner only resizes the window; the font size is set here. · *only on windows* |
| `game.gal_hook_text_letter_spacing` | Letter spacing | 字间距 | Caption overlay · text | number | -2.0 – 12.0 | `0.0` | Adjust spacing between characters without changing lookup hit testing. · *only on windows* |
| `game.gal_hook_text_line_height` | Line height | 行高 | Caption overlay · text | number | 0.8 – 2.0 | `1.0` | Adjust the vertical spacing of wrapped lines. · *only on windows* |
| `game.gal_hook_text_bold` | Bold text | 粗体文字 | Caption overlay · text | bool |  | `true` | Use semibold text for better readability over game graphics. · *only on windows* |
| `game.gal_hook_text_alignment` | Text alignment | 文字对齐 | Caption overlay · text | choice | `center`, `left` | `center` | *only on windows* |
| `game.gal_hook_text_vertical_alignment` | Vertical alignment | 垂直对齐 | Caption overlay · text | choice | `center`, `top` | `center` | *only on windows* |
| `game.gal_hook_text_color` | Text color | 文字颜色 | Caption overlay · window | text |  | `theme` | theme（跟随主题）或 #RRGGBB / #AARRGGBB · *only on windows* |
| `game.gal_hook_text_background_color` | Window background color | 窗口背景颜色 | Caption overlay · window | text |  | `theme` | theme（跟随主题）或 #RRGGBB / #AARRGGBB · *only on windows* |
| `game.gal_hook_text_background_opacity` | Window background opacity | 窗口背景透明度 | Caption overlay · window | number | 0.0 – 1.0 | `0.0` | Set to 0% for a desktop-lyrics style transparent window. · *only on windows* |
| `game.gal_hook_text_outline_color` | Outline color | 描边颜色 | Caption overlay · window | text |  | `theme` | theme（跟随主题）或 #RRGGBB / #AARRGGBB · *only on windows* |
| `game.gal_hook_text_outline_width` | Outline width | 描边宽度 | Caption overlay · window | number | 0.0 – 6.0 | `1.6` | Set to 0 to disable the outline; the subtle shadow remains. · *only on windows* |
| `game.gal_hook_text_padding` | Horizontal text padding | 文字左右边距 | Caption overlay · window | number | 0.0 – 80.0 | `20.0` | Keep text away from the window edges and resize grip. · *only on windows* |
| `game.gal_hook_text_corner_radius` | Window corner radius | 窗口圆角 | Caption overlay · window | number | 0.0 – 40.0 | `14.0` | Adjust the background corner radius. · *only on windows* |
| `game.gal_line_tts_auto` | Auto-read lines | 自动朗读台词 | Line read-aloud (TTS) | bool |  | `false` | Read new lines aloud with TTS, e.g. to voice the narration or a protagonist without voice acting. Also toggled from the overlay toolbar. · *only on windows* |
| `game.gal_line_tts_scope` | What to read | 朗读范围 | Line read-aloud (TTS) | choice | `unvoicedOnly`, `all` | `unvoicedOnly` | Lines without game voice: lines whose original voice Fushi captured are skipped, so TTS never talks over a character. Games whose voice can't be captured are treated as unvoiced; use rules for those. · *only on windows* |
| `game.gal_line_tts_volume` | TTS volume | TTS 音量 | Line read-aloud (TTS) | number | 0.0 – 1.0 | `1.0` | *only on windows* |
| `game.gal_line_tts_speed` | TTS speed | TTS 倍速 | Line read-aloud (TTS) | number | 0.25 – 3.0 | `1.0` | *only on windows* |

## Browser (浏览器)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `system.web_browser_tab_style` | Tab style | 标签页样式 | Browsing | choice | `sidebar`, `topStrip` | `sidebar` | Only affects wide windows (landscape, tablet, desktop) |
| `system.web_browser_collapse_on_scroll` | Hide toolbar while scrolling | 滚动时收起工具栏 | Browsing | bool |  | `true` | On phones, scrolling down shrinks the toolbar to a small address bar; scroll up or tap it to expand |
| `system.web_browser_pull_to_refresh` | Pull down to refresh | 下拉刷新 | Browsing | bool |  | `true` | On phones, pull down at the top of a page to reload it. Turn off if you trigger it by accident · *only on android, ios* |
| `system.web_browser_search_engine` | Search engine | 搜索引擎 | Browsing | choice | `google`, `bing`, `duckDuckGo` | `google` |  |
| `system.web_browser_force_dark` | Dark mode for web pages | 网页深色模式 | Browsing | bool |  | `false` | Show pages in dark colors when the app is dark |
| `system.web_browser_desktop_mode_default` | Open desktop sites by default | 默认打开桌面版网页 | Browsing | bool |  | `false` |  |
| `system.web_browser_fullscreen_takeover` | Fushi handles video full screen | 网页全屏由 Fushi 接管 | Browsing | bool |  | `true` | Full screen stays inside the browser so Fushi subtitles and lookup keep working (iPhone no longer switches to the system player). Takes effect after reloading the page. |
| `system.web_browser_fullscreen_auto_rotate` | Rotate to landscape in full screen | 全屏时横视频自动转横屏 | Browsing | bool |  | `true` | When off, holding the phone upright shows the video on top and the subtitle list below. · *only on android, ios* |
| `system.web_browser_restore_tabs` | Restore tabs from last time | 恢复上次的标签页 | Browsing | bool |  | `true` | Incognito tabs are never restored |
| `system.web_adblock_enabled` | Block ads and trackers on web pages | 拦截网页广告与跟踪器 | Web ad blocking | bool |  | `false` | Applies to in-app web browsing such as web manga, web novels and source login pages. Filter lists are downloaded and refreshed automatically. |
| `system.web_adblock_list.easylist` | EasyList | EasyList | Web ad blocking | bool |  | `false` | easylist.to |
| `system.web_adblock_list.easyprivacy` | EasyPrivacy | EasyPrivacy | Web ad blocking | bool |  | `false` | easylist.to |
| `system.web_adblock_list.adguard_chinese` | AdGuard Chinese | AdGuard Chinese | Web ad blocking | bool |  | `false` | filters.adtidy.org |
| `system.web_adblock_list.adguard_japanese` | AdGuard Japanese | AdGuard Japanese | Web ad blocking | bool |  | `false` | filters.adtidy.org |
| `system.web_adblock_update_now` | Update filter lists now | 立即更新过滤列表 | Web ad blocking | action |  |  |  |
| `system.web_adblock_allowlist` | Sites not to block | 不拦截的网站 | Web ad blocking | text |  |  | Domains separated by commas or spaces; subdomains are included |

## Lookup (查词)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `lookup.custom_css` | Dictionary styling | 词典样式 | Dictionaries | action |  |  | Adjust how entries look with custom CSS |
| `lookup.dictionary_unified_style` | Unify dictionary styles | 统一词典样式 | Dictionaries | bool |  | `false` | Recolor imported dictionaries' tags, highlights and borders with the current accent color (Material). Turn off to keep each dictionary's original colors. |
| `lookup.chinese_script_variants` | Match simplified and traditional Chinese | 简繁互查 | Dictionaries | bool |  | `false` | When looking up Chinese, also find entries written in the other script (这个 ↔ 這個) |
| `lookup.auto_search` | Auto search | 自动搜索 | Lookup page | bool |  | `true` | Search as you type, no need to press Enter |
| `lookup.auto_search_debounce_delay` | Auto search debounce delay | 自动搜索防抖延迟 | Lookup page | number | 0 –  | `100` | How many milliseconds after you stop typing before searching |
| `lookup.page_auto_show_keyboard` | Focus search when opening Lookup | 进入查词页时自动聚焦搜索框 | Lookup page | bool |  | `true` | Focus the search box when opening the lookup page or clearing the query (shows the keyboard on phones) |
| `lookup.page_pull_to_clear` | Pull down at the top to clear the search | 结果顶部下拉清空查询 | Lookup page | bool |  | `true` | Pulling down past the top of the results clears the query and returns to search history |
| `lookup.maximum_terms` | Maximum dictionary headwords in result | 结果中的词头数量上限 | Lookup page | number | 0 –  | `10` | Maximum headwords listed per lookup; lower is faster |
| `lookup.scan_length` | Scan window length | 扫描窗口长度 | Lookup page | number | 8 – 32 | `16` | How many characters from the cursor lookup and word splitting try as the longest candidate (8–32, default 16). Larger values match longer phrases but make each lookup slower. |
| `lookup.scan_non_japanese` | Scan non-Japanese text | 扫描非日文文本 | Selection and hover | bool |  | `true` | When off, selection stops at non-Japanese characters |
| `lookup.hover_auto_lookup` | Look up on hover | 悬停即查词 | Selection and hover | bool |  | `false` | Look up words automatically when the mouse hovers over text, without clicking or holding a modifier key. · *only on windows, macos* |
| `lookup.hover_lookup_modifier` | Hover lookup key | 悬停查词按键 | Selection and hover | choice | `shift`, `ctrl`, `alt` | `shift` | Hold this key and move the mouse over text to look it up (readers, subtitles, web pages) · *only on windows, macos* |
| `lookup.resume_on_lookup_leave` | Resume when leaving lookup | 离开查词即继续播放 | Selection and hover | bool |  | `true` | Close the lookup popup and resume playback when the mouse leaves the subtitles and the popup · *only on windows, macos* |
| `lookup.collapse_dictionaries` | Collapse dictionaries | 折叠词典显示 | Entry display | bool |  | `true` | Show only each dictionary's title by default; tap to expand its definitions |
| `lookup.popup_auto_expand_dictionaries` | Auto-expand rows | 自动展开行数 | Entry display | number | 0.0 – 6.0 | `1.0` | Keep the first N rows of dictionaries expanded while collapsed (0 = collapse all) |
| `lookup.popup_dictionary_columns` | Max dictionary columns | 词典最多列数 | Entry display | number | 1.0 – 4.0 | `3.0` | Auto-fills up to this many dictionary columns per row; narrower screens use fewer |
| `lookup.show_expression_tags` | Show expression tags | 显示表达标签 | Entry display | bool |  | `false` | Show part-of-speech, commonness and other dictionary tags next to the headword |
| `lookup.deduplicate_pitch_accents` | Deduplicate pitch accents | 音调去重 | Entry display | bool |  | `true` | Show identical pitch accents from several dictionaries only once |
| `lookup.harmonic_frequency` | Aggregate word frequencies | 词频聚合 | Entry display | bool |  | `true` | Combine ranks from several frequency dictionaries into one harmonic mean |
| `lookup.compact_glossaries` | Compact glossaries | 紧凑释义 | Entry display | bool |  | `false` | Show definition items on one line instead of one per line. |
| `lookup.dictionary_font_size` | Dictionary font size | 词典字号 | Entry display | number | 0 –  | `16.0` | Ctrl + scroll wheel zooms the popup content |
| `lookup.popup_ui_scale` | Popup UI scale | 查词弹窗缩放 | Entry display | number | 0.5 – 2.0 | `1.0` | Scales popup content and buttons on top of the app UI size; the popup window size is unchanged |
| `lookup.audio_sources` | Manage audio sources | 管理音频来源 | Pronunciation and playback | action |  |  | Where word pronunciations come from and in what order |
| `lookup.auto_read_on_lookup` | Auto read word on lookup | 查词时自动朗读 | Pronunciation and playback | bool |  | `true` | Play the first available pronunciation after a lookup |
| `lookup.audio_volume` | Lookup audio volume | 查词音量 | Pronunciation and playback | number | 0.0 – 100.0 | `100.0` | Volume of word pronunciations, separate from media volume |
| `lookup.pause_on_lookup` | Pause on lookup | 查词时暂停 | Pronunciation and playback | bool |  | `true` | Pause audiobooks / videos during a lookup and resume when the popup closes |
| `lookup.restart_sentence_after_lookup` | Restart sentence after lookup | 查词后从句首重播 | Pronunciation and playback | bool |  | `false` | After the popup closes, replay from the start of the sentence containing the word |
| `lookup.popup_max_width` | Popup max width | 查词窗口最大宽度 | Popup › Lookup popup › Size | number | 250.0 – 2000.0 | `480.0` |  |
| `lookup.popup_max_height` | Popup max height | 查词窗口最大高度 | Popup › Lookup popup › Size | number | 200.0 – 1600.0 | `480.0` |  |
| `lookup.popup_size_preview` | lookup.popup_size_preview | lookup.popup_size_preview | Popup › Lookup popup › Size | custom |  |  |  |
| `lookup.extension_popup_independent_size` | Separate size for browser extension | 浏览器扩展独立尺寸 | Popup › Lookup popup › Size | bool |  | `false` | Give the browser-extension lookup popup its own max size instead of following the in-app popup |
| `lookup.extension_popup_max_width` | Extension popup max width | 扩展弹窗最大宽度 | Popup › Lookup popup › Size | number | 250.0 – 2000.0 | `480.0` |  |
| `lookup.extension_popup_max_height` | Extension popup max height | 扩展弹窗最大高度 | Popup › Lookup popup › Size | number | 200.0 – 1600.0 | `480.0` |  |
| `lookup.popup_bottom_docked.books` | Dock in novels | 小说中底部停靠 | Popup › Lookup popup › Position | bool |  | `false` | Pin the lookup popup as a full-width panel at the bottom of the screen instead of following the looked-up word. |
| `lookup.popup_bottom_docked.manga` | Dock in manga | 漫画中底部停靠 | Popup › Lookup popup › Position | bool |  | `false` |  |
| `lookup.popup_bottom_docked.video` | Dock in videos | 视频中底部停靠 | Popup › Lookup popup › Position | bool |  | `false` |  |
| `lookup.popup_bottom_docked.games` | Dock in games | 游戏中底部停靠 | Popup › Lookup popup › Position | bool |  | `false` |  |
| `lookup.popup_bottom_docked` | Dock elsewhere (dictionary search, floating popups) | 其他场景中底部停靠（查词页、悬浮窗等） | Popup › Lookup popup › Position | bool |  | `false` |  |
| `lookup.popup_wheel_speed` | Popup scroll speed | 弹窗滚轮速度 | Popup › Lookup popup › Scrolling | number | 0.5 – 5.0 | `1.0` | Mouse-wheel scroll speed for the dictionary popup (also applies to the browser extension). |
| `lookup.popup_instant_scroll` | Instant popup scroll | 查词弹窗瞬时滚动 | Popup › Lookup popup › Scrolling | bool |  | `false` | Jump the lookup popup by fixed distances without animated scrolling for e-ink screens. |
| `lookup.popup_instant_scroll_wheel_step` | Instant scroll wheel step | 瞬时滚动滚轮步长 | Popup › Lookup popup › Scrolling | number | 0.1 – 1.0 | `0.5` | How far one mouse-wheel notch jumps the popup, as a share of its height (also scaled by popup scroll speed). |
| `lookup.popup_instant_scroll_touch_step` | Instant scroll touch step | 瞬时滚动触摸步长 | Popup › Lookup popup › Scrolling | number | 0.1 – 1.0 | `0.25` | How far a finger must swipe before the popup jumps one step, as a share of its height. |
| `reading_controls.enable_swipe_to_close` | Swipe to close popup | 滑动关闭弹窗 | Popup › Lookup popup › Closing | bool |  | `true` (android, ios, macos) · `false` (windows) | Swipe horizontally on the popup to close it |
| `reading_controls.dismiss_swipe_sensitivity` | Swipe dismiss sensitivity | 滑动关闭灵敏度 | Popup › Lookup popup › Closing | number | 0.1 – 1.0 | `0.6` |  |
| `reading_controls.dismiss_popup_on_scroll` | Close popup when scrolling | 滚动时关闭查词弹窗 | Popup › Lookup popup › Closing | bool |  | `true` | In scroll mode, keep scrolling the page (horizontal or vertical text) to close the lookup popup |
| `lookup.after_mining_popup.books` | After creating a card in novels | 小说中制卡后 | Popup › Lookup popup › Closing | choice | `keepOpen`, `close`, `closeAndResume` | `keepOpen` | What the lookup popup does once the card is saved. Playback resumes only if the lookup paused it. |
| `lookup.after_mining_popup.manga` | After creating a card in manga | 漫画中制卡后 | Popup › Lookup popup › Closing | choice | `keepOpen`, `close` | `keepOpen` | What the lookup popup does once the card is saved. |
| `lookup.after_mining_popup.video` | After creating a card in videos | 视频中制卡后 | Popup › Lookup popup › Closing | choice | `keepOpen`, `close`, `closeAndResume` | `closeAndResume` | What the lookup popup does once the card is saved. Playback resumes only if the lookup paused it. |
| `lookup.after_mining_popup.music` | After creating a card in music | 音乐中制卡后 | Popup › Lookup popup › Closing | choice | `keepOpen`, `close`, `closeAndResume` | `keepOpen` | What the lookup popup does once the card is saved. Playback resumes only if the lookup paused it. |
| `lookup.after_mining_popup.games` | After creating a card in games | 游戏中制卡后 | Popup › Lookup popup › Closing | choice | `keepOpen`, `close` | `keepOpen` | What the lookup popup does once the card is saved. |
| `lookup.after_mining_popup.lookup` | After creating a card in lookup and elsewhere | 查词页及其他地方制卡后 | Popup › Lookup popup › Closing | choice | `keepOpen`, `close` | `keepOpen` | What the lookup popup does once the card is saved. |
| `lookup.global_context_capture` | Capture selection context | 抓取选中文本上下文 | Lookup outside the app | bool |  | `false` | Read surrounding text from the foreground app to show the current sentence (Windows / macOS / Linux) · *only on windows, macos* |
| `lookup.accessibility_permission` | Grant Accessibility permission for app-external lookup | 为应用外查词授权辅助功能 | Lookup outside the app | action |  |  | Without permission, the shortcut only looks up the current clipboard text. |
| `lookup.overlay_lookup_independent_size` | Separate size for pop-out lookup | 弹出查词窗独立尺寸 | Lookup outside the app | bool |  | `false` | Give the app-external pop-out lookup window its own max size instead of following the in-app popup |
| `lookup.overlay_lookup_max_width` | Pop-out lookup max width | 弹出查词窗最大宽度 | Lookup outside the app | number | 250.0 – 2000.0 | `480.0` |  |
| `lookup.overlay_lookup_max_height` | Pop-out lookup max height | 弹出查词窗最大高度 | Lookup outside the app | number | 200.0 – 1600.0 | `480.0` |  |
| `lookup.block_capture` | Block screen capture | 防截屏 / 防录屏 | Lookup outside the app | bool |  | `false` | Exclude the lookup overlay from screenshots, recordings and live streams. |
| `lookup.texthooker` | Texthooker (receive text) | 文本钩子（接收文本） | Text hooks | bool |  | `false` | Connect to Textractor/mpv/agent and look up incoming text |
| `lookup.texthooker_urls` | Text endpoint URLs | 文本端点地址 | Text hooks | text |  | `ws://localhost:6677, ws://localhost:9001, ws://localhost:2333` | WebSocket addresses to receive text from, separated by commas or spaces. |
| `lookup.ime_language.cli.value` | Lookup input language | 查词输入法语言 |  | text | `none`, `ja`, `zh-Hans`, `zh-Hant`, `ko`, `en` | `none` | none / ja / zh-Hans / zh-Hant / ko / en（none = 未设置） |
| `lookup.ime_language.cli.check` | Lookup input language · check | 查词输入法语言 · check |  | action |  |  | 查询当前设定的输入法语言在系统里是否有可用输入法 |
| `lookup.browser_extension.cli.status` | Extension version | 扩展版本 | Extension | action |  |  | *only on windows, macos* |
| `lookup.browser_extension.cli.prepare` | Prepare extension files | 准备扩展文件 | Extension | action |  |  | Starts the lookup server and unpacks the extension locally; the folder path is copied to the clipboard. · *only on windows, macos* |
| `lookup.browser_extension.cli.verify` | Check connection | 检测连接 | Extension | action |  |  | Verify the extension is loaded and connected · *only on windows, macos* |
| `lookup.browser_extension.cli.open_test_page` | Open the test page | 打开试用网页 | Extension | action |  |  | Opens a page served by Fushi in your browser to check the toolbar popup and Shift lookup. · *only on windows, macos* |
| `lookup.browser_extension.cli.open_extensions_page` | Open the browser extensions page: | 打开浏览器扩展管理页： | Extension | action |  |  | *only on windows, macos* |
| `lookup.custom_css.cli.visual_rules` | Dictionary styling | 词典样式 | Dictionary styling | list |  |  |  |

## Card creation (制卡)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `interconnect.mine_to_server` | Mine to Fushi Interconnect server | 制卡到 Fushi 互联服务端 |  | bool |  | `false` | Send mined cards to the paired Fushi device (its Anki or Fushi review) instead of this device. Requires an interconnect pairing. If the device is offline, cards wait here and are sent once it's back. |
| `interconnect.mine_to_server_target` | Save to | 保存到 |  | action |  |  |  |
| `card_creation.anki.rows` | card_creation.anki.rows | card_creation.anki.rows | Anki | custom |  |  |  |
| `card_creation.anki.configured_rows` | card_creation.anki.configured_rows | card_creation.anki.configured_rows | Anki | custom |  |  |  |
| `card_creation.anki.delivery_rows` | card_creation.anki.delivery_rows | card_creation.anki.delivery_rows | Sending & pending cards | custom |  |  |  |
| `card_creation.content.rows` | card_creation.content.rows | card_creation.content.rows | Card content | custom |  |  |  |
| `card_creation.notices.rows` | card_creation.notices.rows | card_creation.notices.rows | Mining notifications | custom |  |  |  |
| `card_creation.tags.rows` | card_creation.tags.rows | card_creation.tags.rows | Default tags | custom |  |  |  |
| `models.tts_fallback_voice` | Fallback voice | 兜底声音 | Pronunciation fallback | action |  |  | Voice used to generate word audio when none is found |
| `models.tts_fallback_speed` | Fallback voice speed | 兜底发音倍速 | Pronunciation fallback | number | 0.25 – 3.0 | `1.0` | Playback speed of TTS word pronunciations (pitch preserved), independent of audiobook speed. |
| `card_creation.anki.cli.fetch` | Refresh decks & note types | 刷新牌组与笔记类型 | Anki › Anki | action |  |  | After creating or renaming a deck or note type in Anki, tap here to refresh. |
| `card_creation.anki.cli.create_lapis` | Create and use Lapis | 创建并选用 Lapis | Anki › Anki | action |  |  | Adds the Lapis note type and a Lapis deck to Anki, then selects them as the mining target. |
| `card_creation.anki.cli.batch_mining` | Batch mining | 批量制卡 | Anki › Anki | bool |  | `false` | Save cards on this device first and send them to Anki together later, instead of one at a time. |
| `card_creation.anki.cli.queue_undelivered_mines` | Hold cards when Anki is unreachable | 连不上 Anki 时暂存卡片 | Anki › Anki | bool |  | `false` | When Anki can't be reached, save the card to Pending cards and send it later instead of reporting a failure |
| `card_creation.anki.cli.pending_mine_landing` | Receive cards from other devices | 接收其他设备的卡片 | Anki › Anki | action |  |  | Cards mined on devices without Anki are passed to this device through sync (such as Google Drive or WebDAV) and added to Anki here. Only one device receives them at a time. |
| `card_creation.anki.cli.pending_mines` | Pending cards | 待发卡片 | Anki › Anki | action |  |  | Cards saved while Anki was unreachable or while batch mining was on |
| `card_creation.anki.cli.srs_mining_target` | Mining target | 挖词目标 | Anki › Anki | choice | `anki`, `srs` | `anki` | Where a card goes when you mine a word |
| `card_creation.anki.cli.srs_mining_background` | Background card creation | 后台制卡 | Anki › Anki | bool |  | `false` | Creating a card returns right away; cards are written to Fushi review one by one in the background, and a failure is reported in a notice |
| `card_creation.anki.cli.connect_host` | Host | 主机 | Anki › AnkiConnect | text |  | `localhost` | *user only* |
| `card_creation.anki.cli.connect_port` | Port | 端口 | Anki › AnkiConnect | number | 1 – 65535 | `8765` |  |
| `card_creation.anki.cli.connect_api_key` | API Key | API 密钥 | Anki › AnkiConnect | secret |  |  | Required for remote AnkiConnect; must match the key configured in the add-on · *user only* |
| `card_creation.anki.cli.connect_port_auto_fix` | Switch to a free port | 换一个空闲端口 | Anki › AnkiConnect | action |  |  | Picks a free port and writes it to both Fushi and the AnkiConnect add-on config. Restart Anki to apply. · *only on windows, macos* |
| `card_creation.anki.cli.connect_addon_install` | Install AnkiConnect | 安装 AnkiConnect | Anki › AnkiConnect | action |  |  | Downloads AnkiConnect from AnkiWeb and hands it to the running Anki. Anki will ask you to confirm, then advise a restart. · *only on windows* |
| `card_creation.anki.cli.desktop_auto_launch` | Launch Anki when Fushi starts | 启动 Fushi 时自动启动 Anki | Anki › AnkiConnect | bool |  | `false` | If AnkiConnect on this computer isn't responding when Fushi starts, open Anki desktop automatically. |
| `card_creation.anki.cli.desktop_executable` | Anki program | Anki 程序路径 | Anki › AnkiConnect | text |  |  | Not set. The system's default Anki will be used. |
| `card_creation.anki.cli.desktop_executable_detect` | Detect from running Anki | 从运行中的 Anki 检测 | Anki › AnkiConnect | action |  |  | *only on windows* |
| `card_creation.anki.cli.desktop_launch` | Launch Anki now | 立即启动 Anki | Anki › AnkiConnect | action |  |  |  |
| `card_creation.anki.cli.deck` | Deck | 牌组 | Anki › Deck | text |  |  | 牌组名（先用 fetch 刷新牌组列表） |
| `card_creation.anki.cli.note_type` | Note type | 笔记类型 | Anki › Deck | text |  |  | 笔记类型名（先用 fetch 刷新列表）；换笔记类型会重置字段映射 |
| `card_creation.anki.cli.reposition_preview` | Reorder new cards by frequency · Preview | 按词频重排新卡 · 预览 | Anki › Deck | action |  |  | Rewrites the learning order of a deck's new cards so common words come first. Review cards are never touched. |
| `card_creation.anki.cli.reposition` | Reorder new cards by frequency | 按词频重排新卡 | Anki › Deck | action |  |  | Rewrites the learning order of a deck's new cards so common words come first. Review cards are never touched. · *destructive* |
| `card_creation.anki.cli.reposition_undo` | Undo last reorder | 撤销上次重排 | Anki › Deck | action |  |  | Restores the positions saved before the last reorder (). Cards studied since then are left alone. · *destructive* |
| `card_creation.anki.cli.reposition_auto` | Auto-reposition after mining | 制卡后自动重排 | Anki › Deck | bool |  | `false` | Reposition new cards by frequency about 30 seconds after the last card is mined. |
| `card_creation.anki.cli.allow_duplicates` | Allow duplicates | 允许重复 | Anki › Deck | bool |  | `false` | Skip duplicate check when adding cards |
| `card_creation.anki.cli.duplicate_scope` | Duplicate check scope | 查重范围 | Anki › Deck | choice | `deck`, `deckRoot`, `collection` | `deck` | Which decks are searched when checking whether a card already exists. AnkiConnect only; AnkiDroid always searches the whole collection. |
| `card_creation.anki.cli.overwrite_scope` | Overwrite range | 覆写范围 | Anki › Deck | choice | `latest`, `all` | `latest` | Which already-made cards the green ✓ can overwrite |
| `card_creation.anki.cli.compact_glossaries` | Compact glossaries | 紧凑释义 | Anki › Deck | bool |  | `false` | Use compact format for glossary entries |
| `card_creation.anki.cli.tag_char_position` | Write mining position to MiscInfo | 制卡位置写入 MiscInfo | Anki › Deck | bool |  | `false` | Records how many characters into the book each card was mined in the MiscInfo field (Lapis), or in a field named MiscInfo / Source on other note types; nothing is written when there is none. Not added as a tag. |
| `card_creation.anki.cli.notice_success` | Show mining confirmations | 制卡成功提示 | Anki › Deck | bool |  | `true` | Show a notification when a card is added, being created, or saved to pending cards. Failures and missing-audio warnings are always shown. |
| `card_creation.anki.cli.notice_duplicate` | Show duplicate-card notices | 重复制卡提示 | Anki › Deck | bool |  | `true` | Show a notification when a card is skipped because it is already in Anki. |
| `card_creation.anki.cli.backup_import` | Import Anki backup for duplicate check | 导入 Anki 备份用于查重 | Anki › Deck | action |  |  | 0 words imported. Export a .colpkg or .apkg backup from AnkiMobile and import it here so lookups recognize cards already in Anki. Re-import now and then to stay current. |
| `card_creation.anki.cli.global_tags` | Tags for all profiles | 全局标签 | Anki › Default tags | text |  |  | Added to every card, whichever profile is active. |
| `card_creation.anki.cli.tags` | Tags | 标签 | Anki › Default tags | text |  |  | Space-separated tags added to every card |
| `card_creation.anki.cli.tag_include_hibiki` | Add "fushi" tag | 添加「fushi」标签 | Anki › Default tags | bool |  | `true` | Mark every card mined by Fushi |
| `card_creation.anki.cli.tag_include_category` | Add source category tag | 添加来源分类标签 | Anki › Default tags | bool |  | `true` | Books get "book", videos get "video", games get "game", music gets "music", manga gets "manga" |
| `card_creation.anki.cli.tag_nest_title_under_category` | Nest title tags under the category tag | 作品名标签挂在分类标签下 | Anki › Default tags | bool |  | `false` | Book, show and game name tags become hierarchical tags such as video::<title>, so the Anki tag tree groups them under their category |
| `card_creation.anki.cli.tag_book_name` | Auto-add work title to tags | 自动添加作品名到标签 | Anki › Default tags | bool |  | `true` |  |
| `card_creation.anki.cli.lapis_font_scale` | Card font scale | 卡片字号缩放 | Anki › Lapis card style | choice | `80`, `90`, `100`, `110`, `125`, `150` | `100` | Scales every Lapis font size; takes effect via "Apply style to Anki". |
| `card_creation.anki.cli.lapis_custom_css` | Visual editor · CSS | 可视化编辑 · CSS | Anki › Lapis card style | text |  |  | 自定义 CSS 文本（多行建议走 --stdin）；写入后用 lapis_apply 才会推到 Anki |
| `card_creation.anki.cli.lapis_custom_blocks` | Visual editor · blocks | 可视化编辑 · blocks | Anki › Lapis card style | text |  | `[]` | JSON 数组，每项 {"id":"b1","anchor":"…","fields":["字段"],"rule":{…}}；写入后用 lapis_apply 才会推到 Anki |
| `card_creation.anki.cli.lapis_visual_editor` | Visual editor | 可视化编辑 | Anki › Lapis card style | action |  |  | Preview the Lapis card, then change each area's style, position and field mapping without writing CSS. |
| `card_creation.anki.cli.lapis_apply` | Apply style to Anki | 应用样式到 Anki | Anki › Lapis card style | action |  |  |  |
| `card_creation.anki.cli.lapis_backup` | Back up Lapis template | 备份 Lapis 模板 | Anki › Lapis card style | action |  |  |  |
| `card_creation.anki.cli.lapis_backup_list` | Restore from backup · list | 从备份恢复 · list | Anki › Lapis card style | action |  |  |  |
| `card_creation.anki.cli.lapis_restore` | Restore from backup | 从备份恢复 | Anki › Lapis card style | action |  |  | *destructive* |
| `card_creation.anki.cli.lapis_restore_factory` | Restore factory Lapis | 恢复出厂 Lapis | Anki › Lapis card style | action |  |  | Overwrite the Lapis note type in Anki with the version bundled in Fushi and clear every customisation here. · *destructive* |
| `card_creation.anki.cli.mining_image_quality` | Image / GIF quality | 图片 / GIF 清晰度 | Anki › Card media | number | 0.0 – 3.0 | `1.0` | Higher is sharper but makes larger cards. Maximum keeps screenshots at the source resolution; animated GIFs stay capped so cards remain usable. |
| `card_creation.anki.cli.mining_audio_quality` | Audio quality | 音频质量 | Anki › Card media | number | 0.0 – 2.0 | `0.0` | Higher bitrate is clearer but makes larger cards. |
| `card_creation.anki.cli.mining_audio_head_pad` | Audio padding before sentence | 句子音频开头余量 | Anki › Card media | number | 0.0 – 1000.0 | `120.0` | Extra audio kept before the subtitle starts, so the first syllable is not clipped. Never runs into the previous line. |
| `card_creation.anki.cli.mining_audio_tail_pad` | Audio padding after sentence | 句子音频结尾余量 | Anki › Card media | number | 0.0 – 1000.0 | `200.0` | Extra audio kept after the subtitle ends, so trailing sounds are not cut short. Never runs into the next line. |
| `card_creation.anki.cli.mining_audio_follow_playback_speed` | Match sentence audio to playback speed | 句子音频跟随播放倍速 | Anki › Card media | bool |  | `true` | When the audiobook is playing faster or slower than 1×, the sentence audio on the card is time-stretched to the same speed with pitch preserved. Applies to audiobook mining; TTS word audio on cards follows the fallback voice speed. |
| `card_creation.anki.cli.mining_audio_follow_playback_volume` | Match sentence audio to playback volume | 句子音频跟随播放音量 | Anki › Card media | bool |  | `true` | Sentence audio on song, audiobook, audio manga and video cards gets the gain you hear while playing: the song's ReplayGain plus the current volume slider. Turn off to always cut at the source file's original level. Muted playback is ignored. |
| `card_creation.anki.cli.video_mining_audio_source` | Sentence audio source | 句子音频来源 | Anki › Card media | choice | `current`, `front_center`, `track:0`, `track:1`, `track:2`, `track:3`, `track:4`, `track:5` | `current` | Where video cards take sentence audio from. If the choice isn't available for a video, the playing track is used and you're told. |
| `card_creation.anki.cli.video_mining_image_mode` | Video card image | 视频卡片图片 | Anki › Card media | choice | `gif`, `videoClip`, `currentFrame`, `subtitleStart` | `videoClip` |  |
| `card_creation.anki.cli.video_mining_clip_format` | Video clip format | 视频片段格式 | Anki › Card media | choice | `webmVp9`, `webmAv1`, `mp4H264` | `webmVp9` (android, windows, macos) · `mp4H264` (ios) | WebM plays inside the card, but AnkiMobile on iPhone cannot play it — choose MP4 if you review on iPhone. If WebM cannot be encoded on this device, Fushi falls back to MP4. |
| `card_creation.anki.cli.video_mining_animated_format` | Video card animation format | 视频制卡动图格式 | Anki › Card media | choice | `avif`, `webp`, `gif` | `avif` |  |
| `card_creation.anki.cli.mining_animated_play_once` | Play animated images once | 动图只播放一次 | Anki › Card media | bool |  | `false` | Animated card images (GIF / WebP / AVIF) play through once in Anki instead of looping, like video clips. Applies to newly mined cards. |
| `card_creation.anki.cli.video_mining_still_format` | Video card screenshot format | 视频卡片截图格式 | Anki › Card media | choice | `jpg`, `png` | `jpg` | Encoding used when the card image is a still screenshot. JPG is much smaller; PNG is lossless but several times larger. Animated covers are unaffected — they follow the animation format setting. |
| `card_creation.anki.cli.video_online_mining_mode` | Online video mining | 在线视频制卡 | Anki › Card media | choice | `background`, `deferred` | `background` |  |
| `card_creation.anki.cli.gal_mining_image_mode` | Galgame card image | Galgame 制卡配图 | Anki › Card media | choice | `gif`, `currentFrame`, `videoClip` | `gif` | *only on windows* |
| `card_creation.anki.cli.gal_mining_clip_format` | Game clip format | 游戏片段格式 | Anki › Card media | choice | `webmVp9`, `webmAv1`, `mp4H264` | `webmVp9` (android, windows, macos) · `mp4H264` (ios) | WebM plays inside the card, but AnkiMobile on iPhone cannot play it — choose MP4 if you review on iPhone. If WebM cannot be encoded on this device, Fushi falls back to MP4. · *only on windows* |
| `card_creation.anki.cli.gal_mining_animated_format` | Game card animation format | 游戏制卡动图格式 | Anki › Card media | choice | `avif`, `webp`, `gif` | `avif` | *only on windows* |
| `card_creation.anki.cli.gal_mining_still_format` | Game card screenshot format | 游戏卡片截图格式 | Anki › Card media | choice | `jpg`, `png` | `jpg` | *only on windows* |
| `card_creation.anki.cli.gal_mining_audio_mode` | Game card sentence audio | 游戏卡片句子音频 | Anki › Card media | choice | `auto`, `maxLength`, `fixedLength`, `off` | `auto` | For games without voice acting only background music can be captured. Limit its length or skip it. The game's own voice files are never trimmed. · *only on windows* |
| `card_creation.anki.cli.gal_mining_audio_seconds` | Game card audio length | 游戏卡片音频时长 | Anki › Card media | number | 1.0 – 60.0 | `8.0` | Used by Max length and Fixed length. Fixed length pads shorter audio with silence. · *only on windows* |
| `card_creation.anki.cli.dedup_auto` | Automatic processing | 自动处理 | Anki › Anki media storage optimization | bool |  | `false` | Off by default. When on, Fushi scans at startup (at most once a week) and shows you the list first — nothing is deleted until you confirm. |
| `card_creation.anki.cli.dedup_auto_delete` | Delete automatically without asking | 自动直接删除（不再询问） | Anki › Anki media storage optimization | bool |  | `false` | Skips the confirmation dialog. Only byte-identical extra copies are ever removed and nothing is re-encoded, but deletion cannot be undone. |
| `card_creation.anki.cli.dedup_scan` | Scan for duplicates (no changes) | 扫描重复项（不做改动） | Anki › Anki media storage optimization | action |  |  |  |
| `card_creation.anki.cli.dedup_run` | Deduplicate now | 立即去重 | Anki › Anki media storage optimization | action |  |  | Scans first and lists exactly what would be deleted; nothing is removed until you confirm. · *destructive* |
| `card_creation.anki.cli.field_mappings` | Field mappings | 字段映射 | Anki › Field mappings | list |  |  |  |
| `card_creation.anki.cli.video_template_apply` | Video playback adaptation | 视频播放适配 | Anki › Field mappings | action |  |  | Select a video clip in media settings to create new video cards. |
| `card_creation.anki.cli.video_template_restore` | Video playback adaptation · restore | 视频播放适配 · restore | Anki › Field mappings | action |  |  | *destructive* |

## AI

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `ai.agent_open` | AI assistant | AI 助手 | AI assistant | action |  |  | Ask in one sentence and the assistant does it in the app; every change can be undone |
| `ai.agent_history` | AI action log | AI 操作记录 | AI assistant | action |  |  | Everything the AI assistant changed; undo any of it |
| `ai.mcp_servers` | MCP servers | MCP 服务器 | AI assistant | action |  |  | Let the assistant use tools from MCP servers you add |
| `ai.mcp_access` | External AI access (MCP) | 外部 AI 访问（MCP） | External access | bool |  | `false` | Let MCP clients on this device (Claude Desktop, etc.) call Fushi operations. Listens on this device only; operations that can't be undone ask you first. · *only on windows, macos* · *user only* |
| `ai.mcp_token` | Pairing token | 配对令牌 | External access | action |  |  | Generate a token for your MCP client. Generating a new one revokes the old one. |
| `ai.web_knowledge.wikipedia_zh` | Wikipedia (中文) | 维基百科（中文） | Web knowledge | bool |  | `true` |  |
| `ai.web_knowledge.wikipedia_ja` | Wikipedia (日本語) | Wikipedia（日本語） | Web knowledge | bool |  | `true` |  |
| `ai.web_knowledge.wikipedia_en` | Wikipedia (English) | Wikipedia（English） | Web knowledge | bool |  | `true` |  |
| `ai.web_knowledge.moegirl` | Moegirlpedia (萌娘百科) | 萌娘百科 | Web knowledge | bool |  | `true` |  |
| `ai.web_knowledge.ann` | Anime News Network | Anime News Network | Web knowledge | bool |  | `true` |  |
| `ai.web_knowledge.tvmaze` | TVmaze | TVmaze | Web knowledge | bool |  | `true` |  |
| `ai.web_knowledge.custom` | Custom MediaWiki sites | 自定义 MediaWiki 站点 | Web knowledge | list |  |  |  |
| `ai.web_search.kind` | Search backend | 搜索后端 | Web search | choice | , `searxng`, `brave` |  |  |
| `ai.web_search.searxng_endpoint` | SearXNG address | SearXNG 地址 | Web search | text |  |  | Instance root URL. The instance must enable the json format (search.formats in settings.yml). · *user only* |
| `ai.web_search.brave_api_key` | Brave API key | Brave API 密钥 | Web search | secret |  |  | Brave Search API subscription token. · *user only* |
| `ai.web_search.page_fetch` | Send fetched pages to AI | 把抓到的网页交给 AI | Web search | bool |  | `false` | Fetch the top 3 search result pages and send their text to your AI provider (billed by tokens). Web search does nothing while this is off. Some AI providers have built-in web search (some charge for it); with those you can leave this section unconfigured. · *user only* |
| `ai.web_search.agent` | Let the AI assistant search the web | 允许 AI 助手自主联网搜索 | Web search | bool |  | `true` | The first time the assistant wants to search, it asks you once. After you agree, its search words and the addresses of pages it reads go to the search backend above without asking again. Turning this off stops it; turning it back on asks again. · *user only* |
| `ai.video_download_quality` | Default quality | 默认画质 | AI video download | choice | , `ask`, `best`, `2160p`, `1440p`, `1080p`, `720p`, `480p`, `any` |  | Used when the AI download assistant picks a release; "Best available" takes the highest resolution found, "Ask each time" asks on every request. · *only on android, windows, macos* |
| `ai.video_download_source` | Preferred source | 片源偏好 | AI video download | choice | `any`, `best`, `bluray`, `web` | `any` | Versions from this source are tried first; others are still used when it is missing. Blu-ray includes BDRip and Remux. · *only on android, windows, macos* |
| `ai.video_download_bitrate` | Bitrate | 码率偏好 | AI video download | choice | `any`, `high`, `low` | `any` | Estimated from the size per episode; ranks versions that already match the quality and source. · *only on android, windows, macos* |
| `ai.video_download_skip_extras` | Skip extras | 跳过特典 | AI video download | bool |  | `false` | PV, CM, NCOP/NCED, menus and similar. Applies to every download into a video source: extras inside a torrent are not downloaded, and extras-only releases are never picked. · *only on android, windows, macos* |
| `ai.video_download_subtitle_language` | Subtitle language | 字幕语言 | AI video download | choice | , `ask`, `original`, `ja`, `zh`, `en`, `ko`, `es`, `pt`, `fr`, `de`, `it`, `ru`, `ar`, `hi`, `th`, `vi`, `id`, `ms`, `tr`, `nl`, `pl`, `uk`, `sv`, `none` |  | Subtitles are always fetched; this decides which language. "Follow the work" uses the work's own language. · *only on android, windows, macos* |
| `ai.library_curate_auto` | Curate the library automatically | 自动整理整个库 | Library organize | bool |  | `true` | After imports and scans: sort items into collections, identify unscraped videos and link related works across media. Sends titles, authors or brands, years, volume or episode counts and video folder names to the AI providers you assigned (may be billed); a step without an assigned provider sends nothing. Every change can be undone. Turn it on on one device only. |
| `ai.library_agent_review_auto` | Review the library with the AI assistant after imports | 导入后让 AI 助手复查整个库 | Library organize | bool |  | `true` | After the fixed curation steps, the AI assistant checks the new items together with their series and works, fixes wrong collections and relations, and leaves unsure cases for you. The first time, and again after many changes or a month, it reviews the whole library. Sends titles, authors or brands, years and video folder names to the assistant's AI provider; a whole-library review uses many requests (may be billed). Every change can be undone from the AI action history. |
| `ai.library_reorganize` | Reorganize the whole library with the AI assistant | 让 AI 助手重新整理整个库 | Library organize | action |  |  | Reads the whole library, fixes collections and relations in batches and reports back. Every batch can be undone from the conversation. |
| `ai.library_curate_run` | Curate the whole library now | 立即整理整个库 | Library organize | action |  |  |  |
| `ai.library_organize_auto` | Organize with AI after import | 导入后自动 AI 整理 | Library organize | bool |  | `false` | For new items that rules can't group, the title, author and folder name are sent to your chosen AI provider (may incur charges). Turning this on on one device is enough. |
| `ai.library_organize_history` | Organize history | 整理记录 | Library organize | action |  |  |  |

## On-device models (本机模型)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `models.video_subtitle.segmenter` | Segmentation | 分段方式 | Japanese video subtitles | choice | `auto`, `moss`, `window` | `auto` | MOSS segments by speaker on NVIDIA desktops; elsewhere a sliding window is used |
| `models.video_subtitle.moss_backend` | MOSS backend | MOSS 后端 | Japanese video subtitles | choice | `auto`, `cuda`, `vulkan`, `cpu` | `auto` | Auto uses CUDA on supported NVIDIA cards (Windows) or Vulkan (Linux) |
| `models.video_subtitle.moss_files` | MOSS runtime and model | MOSS 运行库与模型 | Japanese video subtitles | custom |  |  |  |
| `models.tts_voices` | Read-aloud voices | 朗读声音 | Speech synthesis (TTS) | action |  |  | GPT-SoVITS, Microsoft, Google or the system voice |
| `models.tts_local_gpt_sovits` | Local GPT-SoVITS | 本机 GPT-SoVITS | Speech synthesis (TTS) | action |  |  | Download the official package and run it here, no command line needed |
| `models.tts_local_irodori` | Local Irodori-TTS | 本机 Irodori-TTS | Speech synthesis (TTS) | action |  |  | Download the official Irodori-TTS server and run it here, no command line needed |
| `models.tts_pronunciation` | Pronunciation dictionary | 发音词典 | Speech synthesis (TTS) › Text processing | action |  |  | Change how words are read, e.g. 今日 → きょう |
| `models.tts_pre_synthesis` | Replace before synthesis | 合成前替换 | Speech synthesis (TTS) › Text processing | action |  |  | Rewrite text before it goes to TTS, e.g. 〜 → ー |
| `models.tts_post_recognition` | Replace after recognition | 识别后替换 | Speech synthesis (TTS) › Text processing | action |  |  | When speech recognition proofreads a made audiobook, change what it heard back to the original spelling, e.g. きょう → 今日 |

## Online services (在线服务)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `services.subtitle_preferences` | AJATT subtitle library | AJATT 字幕库 | Subtitle sources | bool |  | `true` | Off means the AJATT archive is skipped when searching subtitles. |
| `services.metadata.anidb_hash_enabled` | Identify files with AniDB ED2K | 通过 AniDB ED2K 识别文件 | Metadata sources › AniDB | bool |  | `true` | Requires an AniDB account, its UDP API key and a registered client. Uploads only file size and hash; the UDP login is encrypted. |
| `services.metadata.anidb_username` | AniDB username | AniDB 用户名 | Metadata sources › AniDB | text |  |  |  |
| `services.metadata.anidb_password` | AniDB password | AniDB 密码 | Metadata sources › AniDB | secret |  |  | *user only* |
| `services.metadata.anidb_udp_api_key` | AniDB UDP API key | AniDB UDP API Key | Metadata sources › AniDB | secret |  |  | Set it yourself on AniDB under Profile → Settings → Account → UDP API Key, then enter it here. Fushi uses it to encrypt the login; the key itself is never sent. · *user only* |
| `services.metadata.anidb_client` | AniDB client name | AniDB 客户端名称 | Metadata sources › AniDB | text |  |  | Fushi includes a registered app client. Leave this blank normally; set a custom registered client only if needed. |
| `services.metadata.anidb_client_version` | AniDB client version | AniDB 客户端版本 | Metadata sources › AniDB | text |  |  | Only custom clients need their own registered version here. Fushi maintains the default app identity; your personal AniDB login is still required. |
| `services.metadata.anidb_login_test` | Test AniDB login | 测试 AniDB 登录 | Metadata sources › AniDB | action |  |  | Sends one UDP login with the saved account and client, then logs out. No file is hashed. |
| `services.metadata.anidb_http_api` | AniDB HTTP metadata API | AniDB HTTP 资料接口 | Metadata sources › AniDB | status |  |  |  |
| `services.metadata.tmdb_api_key` | Custom TMDB API key | 自定义 TMDB API Key | Metadata sources › TMDB | secret |  |  | Optional. Leave empty to use the built-in key. Fill in your own only if scraping stops working or you want to use your own quota. · *user only* |
| `services.metadata.rakuten_application_id` | Application ID | 应用 ID（applicationId） | Metadata sources › 楽天ブックス | secret |  |  | Register an app at Rakuten Web Service to get both values. Stored on this device only; never backed up or synced. · *user only* |
| `services.metadata.rakuten_access_key` | Access key | 访问密钥（accessKey） | Metadata sources › 楽天ブックス | secret |  |  | Register an app at Rakuten Web Service to get both values. Stored on this device only; never backed up or synced. · *user only* |
| `services.media_server.jellyfin` | Jellyfin · Emby · Media server (Jellyfin / Emby) | Jellyfin · Emby · 媒体服务器（Jellyfin / Emby） | Media servers | list |  |  |  |
| `services.media_server.plex` | Plex · Media servers | Plex · 媒体服务器 | Media servers | list |  |  |  |
| `services.audiobookshelf.show_in_home` | Show in Home Continue | 在首页「继续」中显示 | Media servers › Audiobookshelf servers | bool |  | `false` | Mix in-progress Audiobookshelf items into the Continue row on Home. Off: find them in the Audiobookshelf tab only. |
| `services.music_servers.bitrate` | Server streaming quality | 服务器播放音质 | Media servers › Server libraries | choice | `0`, `320`, `192`, `128` | `0` | Original plays the file as stored (lossless stays lossless); a cap asks the server to transcode |
| `services.danmaku.server_url` | Danmaku server URL | 弹幕服务器地址 | Danmaku › Dandanplay | text |  |  |  |
| `services.discovery_sources.cli.sources` | Discovery sources | 发现来源 | Resource indexers › Discovery sources | list |  |  | *only on android, windows, macos* |
| `services.opds_servers.cli.servers` | OPDS catalogs | OPDS 书目服务器 | Media servers › OPDS catalogs | list |  |  |  |
| `services.opds_servers.cli.test` | Test connection | 测试连接 | Media servers › OPDS catalogs | action |  |  |  |
| `services.alist_sites.cli.sites` | AList / OpenList sites | AList / OpenList 站点 | Media servers › AList / OpenList sites | list |  |  |  |
| `services.alist_sites.cli.test` | Test connection | 测试连接 | Media servers › AList / OpenList sites | action |  |  |  |
| `services.audiobookshelf_servers.cli.servers` | Audiobookshelf servers | Audiobookshelf 服务器 | Media servers › Audiobookshelf servers | list |  |  |  |
| `services.audiobookshelf_servers.cli.sign_in` | Sign in | 登录 | Media servers › Audiobookshelf servers | action |  |  | With an API key, username and password are not needed |
| `services.audiobookshelf_servers.cli.sign_out` | Sign out | 退出登录 | Media servers › Audiobookshelf servers | action |  |  | *destructive* |
| `services.audiobookshelf_servers.cli.test` | Test connection | 测试连接 | Media servers › Audiobookshelf servers | action |  |  |  |
| `services.jimaku.cli.enabled` | Jimaku · Enabled | Jimaku · 已启用 | Jimaku | bool |  | `true` | Off means Jimaku is skipped even when an API key is saved. |
| `services.jimaku.cli.api_key` | Jimaku API key | Jimaku API 密钥 | Jimaku | secret |  |  | Get a free API key at jimaku.cc/account · *user only* |
| `services.opensubtitles.cli.enabled` | OpenSubtitles · Enabled | OpenSubtitles · 已启用 | OpenSubtitles | text | `true`, `false` | `true` | true / false |
| `services.opensubtitles.cli.endpoint` | API endpoint | API 端点 | OpenSubtitles | text |  | `https://api.opensubtitles.com/api/v1` | API 端点 URL（https；loopback 或开了 insecure_http 才可 http） · *user only* |
| `services.opensubtitles.cli.api_key` | OpenSubtitles · API key | OpenSubtitles · API 密钥 | OpenSubtitles | secret |  |  | *user only* |
| `services.opensubtitles.cli.username` | Username (optional) | 用户名（可选） | OpenSubtitles | text |  |  | 登录用户名；空串 = 不登录 |
| `services.opensubtitles.cli.password` | Password (optional) | 密码（可选） | OpenSubtitles | secret |  |  | *user only* |
| `services.opensubtitles.cli.user_agent` | User-Agent | User-Agent | OpenSubtitles | text |  | `FushiPlayer v1` | User-Agent（不能为空） |
| `services.opensubtitles.cli.insecure_http` | OpenSubtitles · Allow insecure HTTP | OpenSubtitles · 允许不安全的 HTTP | OpenSubtitles | text | `true`, `false` | `false` | true / false（Use only for a trusted local network endpoint.） |
| `services.subdl.cli.enabled` | SubDL · Enabled | SubDL · 已启用 | SubDL | bool |  | `true` | Off means SubDL is skipped even when an API key is saved. |
| `services.subdl.cli.api_key` | SubDL · API key | SubDL · API 密钥 | SubDL | secret |  |  | Get a free API key at subdl.com/panel/api · *user only* |
| `services.bt_sites.cli.sites` | BT sites | BT 站 | BT sites | list |  |  | *only on android, windows, macos* |
| `services.torznab.cli.indexers` | Torznab indexers | Torznab 索引器 | Torznab indexers | list |  |  | *only on android, windows, macos* |

## Local services (本机服务)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `local_services.fushi_api_server` | Fushi API server | Fushi API 服务器 | Fushi API server | bool |  | `false` | Lets the browser extension, Yomitan (yomitan-api) and AnkiConnect tools connect to Fushi |
| `local_services.fushi_api_reach` | Who can connect | 当前谁能连接 | Fushi API server | status |  |  |  |
| `local_services.fushi_api_access` | Allow connections from | 允许连接 | Fushi API server | choice | `localOnly`, `lan`, `allowList` | `lan` | This device is always allowed. Other devices also need the API key. |
| `local_services.fushi_api_allowed_networks` | Allowed networks | 允许的网段 | Fushi API server | status |  |  |  |
| `local_services.fushi_api_port` | Port | 端口 | Fushi API server | status |  |  |  |
| `local_services.fushi_api_key` | Fushi API key | Fushi API 密钥 | Fushi API server | secret |  |  | Every tool that connects to Fushi (Yomitan, AnkiConnect clients, Fushi on another device) enters this key, on this computer too. The browser extension is configured automatically. · *user only* |
| `local_services.srs_ankiconnect` | AnkiConnect for Fushi review | AnkiConnect（Fushi 复习） | Connected tools | status |  |  |  |

## Configuration presets (配置方案)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `profiles.current` | Profile | 配置 | Profile | custom |  |  |  |

## Sync & backup (同步与备份)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `sync.cloud_enabled` | Enable cloud sync | 启用云同步 | Cloud sync | bool |  | `true` | Back up and sync through the cloud service below. Turning it off keeps your account signed in, so you can turn it back on anytime. |
| `sync.mode` | sync.mode | sync.mode | Cloud sync | custom |  |  |  |
| `sync.account_status` | sync.account_status | sync.account_status | Cloud sync | custom |  |  |  |
| `sync.webdav_config` | sync.webdav_config | sync.webdav_config | Cloud sync › Server settings | custom |  |  |  |
| `sync.ftp_config` | sync.ftp_config | sync.ftp_config | Cloud sync › Server settings | custom |  |  |  |
| `sync.sftp_config` | sync.sftp_config | sync.sftp_config | Cloud sync › Server settings | custom |  |  |  |
| `sync.interconnect_config_note` | Fushi Interconnect | Fushi 互联 | Cloud sync | status |  |  | Connection & server settings are in the Fushi Interconnect category |
| `sync.statistics` | Sync statistics | 同步统计 | What to sync | bool |  | `true` | Reading and watching time, character counts, lookup and mining counts |
| `sync.settings` | Sync settings | 同步设置 | What to sync | bool |  | `false` | Sync portable preferences across devices; device paths, window layout and external tool connections stay on each device. |
| `sync.web_history` | Sync browsing history | 同步浏览历史 | What to sync | bool |  | `false` | Off by default. When on, the in-app browser's history syncs with cloud backup and paired devices. Bookmarks follow favorites. |
| `sync.content` | Upload book files | 上传书籍文件 | What to sync | bool |  | `false` | Large files will use storage space and data |
| `sync.manga_content` | Upload manga files | 上传漫画文件 | What to sync | bool |  | `false` | Manga volumes are large and use more storage and data |
| `sync.video_files` | Upload video files | 上传视频文件 | What to sync | bool |  | `false` | Video files can be very large. |
| `sync.audiobook_files` | Upload audiobook files | 上传有声书文件 | What to sync | bool |  | `false` | Audio and subtitles can be large. |
| `sync.show_remote_entries` | Show remote entries | 显示远端条目 | Remote entries | bool |  | `true` | Show books and videos that exist on the Fushi Interconnect server or the cloud as placeholder cards you can download or stream. |
| `sync.auto_sync` | Auto sync | 自动同步 | When to sync | bool |  | `false` | Cloud sync only. Fushi Interconnect has its own auto sync switch on the Interconnect page |
| `sync.server_mode_note` | This device is a sync server | 本机作为同步服务端 | When to sync | status |  |  | Connected clients start the sync — no manual sync needed here. |
| `sync.sync_now` | sync.sync_now | sync.sync_now | When to sync | custom |  |  |  |
| `sync.compare` | Compare data | 对比数据 | When to sync | action |  |  | Compare this device with the cloud item by item, then decide which side wins |
| `sync.asset_legacy_notice` | Dictionary and audio sync is now manual | 词典与本地音频改为手动传输 | Dictionaries, audio & fonts transfer | custom |  |  |  |
| `sync.dictionary_transfer` | Dictionaries | 词典 | Dictionaries, audio & fonts transfer | custom |  |  |  |
| `sync.local_audio_transfer` | Local audio databases | 本地音频数据库 | Dictionaries, audio & fonts transfer | custom |  |  |  |
| `sync.fonts_transfer` | Fonts and font settings | 字体与字体设置 | Dictionaries, audio & fonts transfer | custom |  |  |  |
| `sync.backup_export` | sync.backup_export | sync.backup_export | Local backup | custom |  |  |  |
| `sync.backup_import` | sync.backup_import | sync.backup_import | Local backup | custom |  |  |  |
| `sync.backup_merge_settings` | Include settings when merging a backup | 合并导入时包含设置 | Local backup | bool |  | `false` | Merge the backup's portable preferences too, keeping whichever side changed each setting more recently. Device paths, window layout, platform-only options and external tool connections are never imported. |
| `sync.hoshi_import` | Third-party import | 第三方导入 | Local backup | action |  |  | Import books, reading positions and statistics from another reader's library backup, such as a Hoshi Reader .hoshi file |

## Fushi Interconnect (Fushi 互联)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `interconnect.enabled` | Enable interconnect | 启用互联 |  | bool |  | `false` | Connect to your other devices over the LAN. Works alongside a cloud backup backend — they don't conflict. |
| `sync.fushi_server_config` | sync.fushi_server_config | sync.fushi_server_config | Devices › Pairing & devices | custom |  |  |  |
| `sync.lan_devices` | sync.lan_devices | sync.lan_devices | Devices › Pairing & devices | custom |  |  |  |
| `sync.server_mode` | sync.server_mode | sync.server_mode | Devices › Host service › Service | custom |  |  |  |
| `interconnect.transcode_host` | Transcode video for peers | 为对端转码视频 | Devices › Host service › Paired devices can… | bool |  | `true` | When a paired device plays a video from this host over a slow network, re-encode it to a lower bitrate on the fly. Needs ffmpeg; costs CPU on this device. |
| `interconnect.ai_relay_host` | Use this device's AI providers | 使用本机的 AI 提供商 | Devices › Host service › Paired devices can… | bool |  | `true` | Paired devices can add this device as an AI provider. Requests run with the providers set up here; API keys never leave this device, and usage counts against them. |
| `ai.agent_for_peers` | Use this device's AI assistant | 使用本机的 AI 助手 | Devices › Host service › Paired devices can… | bool |  | `false` | Can change this device's library and settings; every change can be undone in the AI action log. Off by default. · *user only* |
| `interconnect.game_stream_remote_launch` | Launch games remotely | 远程启动游戏 | Devices › Host service › Paired devices can… | bool |  | `false` | Paired devices can start games from this PC's library and stream them |
| `interconnect.profile_transfer_host` | Read and write this device's profiles | 读写本机配置方案 | Devices › Host service › Paired devices can… | bool |  | `false` | Off by default. Requires HTTPS and a paired-device token. Incoming configurations are always added as new ones. |
| `interconnect.leaderboard_link_host` | Sign in to my account automatically | 自动登录我的账户 | Devices › Host service › Paired devices can… | bool |  | `true` | Only applies to paired devices marked as "my device". |
| `interconnect.source_share_host` | Share sources with my devices | 把来源共享给我的设备 | Devices › Host service › Paired devices can… | bool |  | `true` | Paired devices marked as yours get the servers and plugins you choose below, including their passwords and API keys, over the encrypted connection. |
| `interconnect.source_share_items.list` | interconnect.source_share_items.list | interconnect.source_share_items.list | Devices › Host service › Paired devices can… › Choose what to share | custom |  |  |  |
| `interconnect.remote_update_host` | Update this device remotely | 远程更新本机 | Devices › Host service › Paired devices can… | bool |  | `false` | Paired devices can see this app's version and start an update here, on the local network or remotely. On Android you still confirm the install on this device. |
| `interconnect.download_tasks` | Interconnect downloads | 互联下载 | Interconnect features | action |  |  | Pause, resume or cancel downloads from paired devices |
| `interconnect.game_stream` | Join game stream | 加入游戏串流 | Interconnect features | action |  |  | Stream a paired PC's game screen to this device |
| `interconnect.share_statistics` | Share statistics | 共享统计 | Two-way sharing | bool |  | `true` | Reading and watching time, character counts, lookup and mining counters |
| `interconnect.share_favorites` | Share favorites | 共享收藏夹 | Two-way sharing | bool |  | `true` | Favorite words and sentences, including un-favoriting |
| `interconnect.auto_sync` | Auto sync | 自动同步 | Two-way sharing | bool |  | `true` | Merge progress, statistics, favorites and collections when the app opens, goes to the background, and periodically while it runs. |
| `sync.srs_auto_sync` | Auto-sync review data | 自动同步复习数据 | Two-way sharing | bool |  | `true` | When off, review data only syncs when you tap Sync now in the deck list or open the Review tab. |
| `interconnect.upload_content` | Upload book files | 上传书籍文件 | Upload to peer | bool |  | `false` | Sync this device's books and reading content up to the interconnect peer. |
| `interconnect.upload_manga_content` | Upload manga files | 上传漫画文件 | Upload to peer | bool |  | `false` | Sync this device's manga up to the interconnect peer. |
| `interconnect.upload_audiobook_files` | Upload audiobook files | 上传有声书文件 | Upload to peer | bool |  | `false` | Sync this device's audiobook audio and subtitle packages up to the interconnect peer (large). |
| `interconnect.upload_video_files` | Upload video files | 上传视频文件 | Upload to peer | bool |  | `false` | Sync this device's local video files up to the interconnect peer (large). |
| `interconnect.dictionary_transfer` | Dictionaries | 词典 | Upload to peer | custom |  |  |  |
| `interconnect.local_audio_transfer` | Local audio databases | 本地音频数据库 | Upload to peer | custom |  |  |  |
| `interconnect.fonts_transfer` | Fonts and font settings | 字体与字体设置 | Upload to peer | custom |  |  |  |
| `interconnect.backup_backend` | interconnect.backup_backend | interconnect.backup_backend | Use the host's capabilities | custom |  |  |  |
| `interconnect.service_config_sync` | Sync service configuration from host | 同步主机服务配置 | Use the host's capabilities | bool |  | `true` | Receive the host's external service settings and API keys over the encrypted channel. Requires TLS. |
| `interconnect.source_share_sync` | Receive shared sources | 接收共享来源 | Use the host's capabilities | bool |  | `true` | Servers (OPDS, AList, Kavita, OpenSubsonic, Jellyfin, Plex) the host chose to share join this device automatically, sign-in included. Only from hosts that marked this device as one of their own. |
| `interconnect.source_share_plugins` | Also receive plugins | 也接收插件 | Use the host's capabilities | bool |  | `false` | Lets the host install the plugins it shares on this device. Plugins are third-party code: only turn this on if the host is yours. |
| `interconnect.leaderboard_follow_login` | Sign in with a paired device's account | 跟随已配对设备自动登录 | Use the host's capabilities | bool |  | `true` | When this device has no Fushi account, sign in with a paired device's account automatically. |
| `interconnect.profile_upload` | Upload configuration to host | 上传配置到对端 | Use the host's capabilities | custom |  |  |  |
| `interconnect.profile_download` | Download configuration from host | 从对端下载配置 | Use the host's capabilities | custom |  |  |  |
| `interconnect.host_update` | Host version | 主机版本 | Use the host's capabilities | custom |  |  |  |

## Storage (存储)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `sync.data_storage_location` | sync.data_storage_location | sync.data_storage_location | Data storage location | custom |  |  | *only on windows, macos* |
| `storage.db_check` | Check database | 检查数据库 | Database maintenance | action |  |  | Check integrity, repair known damaged data and compact. A full backup is made first. · *destructive* |
| `storage.library_recovery` | Recover library | 恢复书库 | Database maintenance | action |  |  | Restore books from the snapshot taken before an overwrite import, or re-register book folders left on disk |
| `storage.srs_retained_copy` | Delete old-version retained copy | 删除旧版本保留副本 | Database maintenance | action |  |  | The review library from before the upgrade, kept so you can go back to the old version. It still holds the original text of anything purged since the upgrade. · *destructive* |
| `storage.srs_retained_copy_unreadable` | Old-version retained copy is damaged | 旧版本保留副本已损坏 | Database maintenance | status |  |  | The review library from before the upgrade is no longer a readable file, so it can no longer be used to go back to the old version. Your current review data is not affected. |
| `storage.cli.categories` | Disk usage | 磁盘占用 |  | list |  |  |  |
| `storage.cli.entries` | Disk usage · entries | 磁盘占用 · entries |  | list |  |  |  |
| `storage.cli.bundled` | Bundled components | 随包组件 |  | list |  |  |  |
| `storage.cli.anime4k_delete` | Delete Anime4K shaders | 删除 Anime4K 着色器 |  | action |  |  | Can be downloaded again anytime in video settings · *destructive* |

## Home-screen widgets (主屏幕小组件)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `widgets.howto` | How to add | 如何添加 | Add a widget | status |  |  | Long-press your home screen, choose Widgets, then pick Fushi. · *only on android* |
| `widgets.hide_titles` | Hide titles | 隐藏标题 | Privacy | bool |  | `false` | Hide book and video titles on widgets by default. Each widget can override this. · *only on android* |
| `widgets.hide_definitions` | Hide definitions | 隐藏释义 | Privacy | bool |  | `false` | Hide word definitions on the vocabulary widget by default. · *only on android* |
| `widgets.hide_profile` | Hide profile name | 隐藏配置名 | Privacy | bool |  | `false` | Do not show the profile name on widgets. · *only on android* |
| `widgets.review_provider` | Review app | 复习应用 | Review widget | status |  |  | The review widget follows Card creation: Fushi SRS or AnkiDroid. · *only on android* |

## System and about (系统与关于)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `system.update_channel` | Update channel | 更新通道 | App updates | choice | `stable`, `beta`, `debug` | `stable` | Stable is the most reliable; beta gets new features sooner but is more likely to have problems |
| `system.update_download_source` | Preferred download source | 首选下载源 | App updates | choice | `auto`, `r2`, `github`, `proxy:https://ghfast.top/`, `proxy:https://gh-proxy.com/`, `proxy:https://ghproxy.net/`, `proxy:https://ghproxy.cc/`, `proxy:https://gh.llkk.cc/` | `auto` | The selected source is tried first; unavailable sources still fall back automatically. |
| `system.check_update_now` | Check for updates | 检查更新 | App updates | action |  |  |  |
| `system.update_never_remind` | Don't remind me about updates | 不再提醒自动更新 | App updates | bool |  | `false` | Don't pop up a reminder when a new version is found; you can still check for updates manually |
| `system.update_auto_install` | Auto-install updates | 自动安装更新 | App updates | bool |  | `false` | Download and install new versions automatically when found |
| `system.updates.videoEpisode` | Notify about new anime episodes | 番剧新集提醒 | Notifications | bool |  | `true` | Alert when a subscribed series finishes downloading a new episode, or a show in your video library gets new episodes. |
| `system.updates.mangaChapter` | Notify about new manga chapters | 漫画新章提醒 | Notifications | bool |  | `true` | Check followed online manga for new chapters in the background. |
| `system.updates.mangaExtension` | Notify about manga extension updates | 漫画扩展更新提醒 | Notifications | bool |  | `true` | Alert when an installed extension has a newer version in its repository. |
| `system.updates.animeExtension` | Notify about video extension updates | 视频扩展更新提醒 | Notifications | bool |  | `true` | Alert when an installed video extension has a newer version in its repository. |
| `system.updates.appRelease` | Notify about app releases | 应用新版提醒 | Notifications | bool |  | `true` | Alert when a newer Fushi release is available. |
| `system.updates.system_notifications` | System notifications | 系统通知 | Notifications | bool |  | `false` | Also send a system notification. Turning this off keeps the in-app badge. |
| `system.updates.feedback_replies` | Notify me of feedback replies | 反馈有新回复时通知我 | Notifications | bool |  | `true` | Check in the background for new replies to feedback sent from this device |
| `system.updates.video_library_auto_update` | Auto-add new episodes to the video library | 自动补齐媒体库新集 | Background tasks | bool |  | `true` | Every few hours, checks online-source titles and media server shows and adds newly released episodes. |
| `system.updates.extension_auto_update` | Auto-update extensions in the background | 后台自动更新扩展 | Background tasks | bool |  | `false` | Installs new versions of manga and video extensions at startup (only those whose signature is unchanged). · *only on android, windows, macos* |
| `system.network_proxy_mode` | Proxy mode | 代理模式 | Network | choice | `auto`, `direct`, `manual` | `auto` | Follow the system, set one manually, or use no proxy |
| `system.network_proxy` | Network proxy | 网络代理 | Network | text |  |  | HTTP proxy server used by all public internet requests · *user only* |
| `system.network_proxy_username` | Proxy username (optional) | 代理用户名（可选） | Network | secret |  |  | Credentials apply to HTTP requests only; the built-in torrent engine cannot use them · *user only* |
| `system.network_proxy_password` | Proxy password (optional) | 代理密码（可选） | Network | secret |  |  | *user only* |
| `system.network_github_mirrors` | Use GitHub download mirrors | 使用 GitHub 加速镜像 | Network | bool |  | `true` | When a direct GitHub download fails (updates, dictionaries, fonts, shaders, extension repositories), retry through third-party mirrors such as ghproxy. Turn off to use only direct connections and jsDelivr. |
| `system.network_proxy_p2p` | P2P (torrent) proxy | P2P（torrent）代理 | Network | choice | `direct`, `proxy`, `mixed` | `direct` | Direct by default. A proxy may slow things down and many proxies forbid BitTorrent; mixed mode only fixes connectivity and still exposes your real IP. |
| `system.usage_stats_enabled` | Share usage statistics | 发送使用统计 | Privacy | bool |  | `true` | Once a day, sends an anonymous install ID, version and platform to fushi.moe to count active users. No account, library or reading content. |
| `system.updates.crash_report_auto_send` | Automatically send crash logs | 自动发送闪退日志 | Privacy | bool |  | `false` | After a crash, send the log to the developers on next launch without asking |
| `diagnostics.debug_log_enabled` | Enable debug log | 启用调试日志 | Diagnostics | bool |  | `false` | Record more detailed logs; turn on only while troubleshooting |
| `diagnostics.study_diag_export` | Export study diagnostics log | 导出统计诊断日志 | Diagnostics | action |  |  | Page credits, segment open/close, audiobook resume and jump trace, for troubleshooting reading-speed anomalies. Saved as a text file. |
| `diagnostics.video_diag_log_enabled` | Video & lookup diagnostics log | 视频 / 查词诊断日志 | Diagnostics | bool |  | `false` | Records frame timings, libmpv playback stats and per-stage lookup timings. Off by default; turn it on, reproduce the stutter or slow lookup, then export. |
| `diagnostics.video_diag_export` | Export video diagnostics log | 导出视频诊断日志 | Diagnostics | action |  |  | Timeline plus libmpv's own verbose log |
| `system.app_version` | system.app_version | system.app_version | About | custom |  |  |  |
| `system.website` | Visit the official website | 访问官网 | About | action |  |  |  |
| `system.github` | View repository on GitHub | 在 GitHub 查看仓库 | About | action |  |  |  |
| `system.github_sponsors` | Support Fushi on GitHub Sponsors | 通过 GitHub Sponsors 赞助 Fushi | About | action |  |  | *only on android, windows, macos* |
| `system.ko_fi` | Support Fushi on Ko-fi | 在 Ko-fi 上赞助 Fushi | About | action |  |  | *only on android, windows, macos* |
| `system.tmdb_attribution` | TMDB | TMDB | About | custom |  |  | This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB. |
| `system.mangabaka_attribution` | MangaBaka | MangaBaka | About | action |  |  | Manga and light novel series data and covers come from MangaBaka, used under CC BY-NC-SA 4.0. |
| `system.update.download` | Download | 下载 | App updates | action |  |  |  |
| `system.update.cancel` | Cancel | 取消 | App updates | action |  |  |  |
| `system.update.install` | Installing… | 正在安装… | App updates | action |  |  | *destructive* |

## Jellyfin · Emby

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `services.media_server.jellyfin.show_in_library` | Show in video library | 在视频库中混排显示 |  | bool |  | `false` | Mix media server items into Home, Series and All videos. Off: browse them only in the Media servers section. |
| `services.media_server.jellyfin.auto_list_videos` | Auto-list items on entering Video | 进入视频页时自动列出条目 |  | bool |  | `true` | Off: entering the video page sends no request to the media server; pull to refresh in the video library to list items manually. Recommended for very large servers, where automatic enumeration looks like scraping and can trip abuse detection. |

## Manage audio sources (管理音频来源)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `lookup.audio_sources.items` | Manage audio sources | 管理音频来源 |  | list |  |  |  |
| `lookup.audio_sources.reset` | Manage audio sources | 管理音频来源 |  | action |  |  | *destructive* |
| `lookup.audio_sources.local_sources` | Manage audio sources | 管理音频来源 |  | action |  |  |  |

## Compare data (对比数据)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `sync.compare_apply` | Compare data | 对比数据 |  | action |  |  | *destructive* |

## Quality enhancement (画质增强)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `video.player.shader_tier` | Quality enhancement | 画质增强 |  | text | `off`, `low`, `medium`, `high`, `ultra` | `low` | 一键选档：缺的 Anime4K 着色器先下载，再启用（custom = 手工勾选，只读） |
| `video.player.mpv_shader_dir` | Choose mpv folder | 选择 mpv 目录 |  | text |  |  | 本机 mpv 配置 / 着色器目录（绝对路径；空串 = 自动找） |
| `video.player.shader_discover` | Import from local mpv | 从本机 mpv 导入 |  | action |  |  | Search local mpv automatically, or choose an mpv folder when none is found. |

## Plex

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `services.media_server.plex.sign_in` | Sign in with Plex | 使用 Plex 账号登录 |  | action |  |  | Waiting for you to approve Fushi in the browser… |

## Anki sync (no Anki needed) (Anki 同步（无需安装 Anki）)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `card_creation.anki.sync_client.enabled` | Sync cards straight to Anki | 直接同步到 Anki |  | bool |  | `false` | Fushi keeps its own copy of your collection and syncs it with your Anki sync server, so this device needs neither Anki nor AnkiConnect. · *user only* |
| `card_creation.anki.sync_client.enable` | I understand, enable | 我明白，仍然启用 |  | action |  |  | *destructive* |
| `card_creation.anki.sync_client.status` | Anki sync (no Anki needed) | Anki 同步（无需安装 Anki） |  | action |  |  |  |
| `card_creation.anki.sync_client.sign_in` | Sign in and download collection | 登录并下载牌组集合 |  | action |  |  |  |
| `card_creation.anki.sync_client.sign_out` | Sign out | 退出登录 |  | action |  |  |  |
| `card_creation.anki.sync_client.sign_out_discard` | Discard and sign out | 放弃并退出 |  | action |  |  | *destructive* |
| `card_creation.anki.sync_client.sync_now` | Sync now | 立即同步 |  | action |  |  |  |

## Downloads (下载)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `downloads.cli.execution_host` | Download on device | 下载执行设备 |  | text |  | `local` | local = 本机；或已配对 host 的地址（候选见 `config run downloads.cli.execution_host_candidates`） · *only on android, windows, macos* |
| `downloads.cli.execution_host_candidates` | Download on device · candidates | 下载执行设备 · candidates |  | action |  |  | *only on android, windows, macos* |
| `downloads.cli.backend` | Download settings | 下载设置 |  | choice | `embedded`, `qbittorrent`, `fushi_host` | `embedded` (android, windows, macos) · `qbittorrent` (ios) | *only on android, windows, macos* |
| `downloads.cli.engine_host` | Download device | 下载设备 |  | text |  |  | 借哪台已配对设备的 BT 引擎（下载后端 = fushi_host 时生效）；填已配对 host 的地址，候选见 `config run downloads.cli.execution_host_candidates` |
| `downloads.cli.save_root` | Download folder | 下载目录 |  | text |  |  | 下载目录绝对路径（只影响之后新增的任务）；恢复默认用 config run downloads.cli.save_root_reset · *only on android, windows, macos* |
| `downloads.cli.save_root_reset` | Restore default | 恢复默认 |  | action |  |  | *only on android, windows, macos* |
| `downloads.cli.save_root_issue` | The configured download folder is unavailable, so the default folder is being used. | 配置的下载目录当前不可用，已回退到默认目录。 |  | status |  |  | *only on android, windows, macos* |
| `downloads.cli.download_limit_kbps` | Download limit (KB/s) | 下载限速 (KB/s) |  | number | 0 –  | `0` | 0 = unlimited · *only on android, windows, macos* |
| `downloads.cli.limit_lan` | Apply limits to LAN peers | 限速也作用于局域网 |  | bool |  | `false` | Off by default: transfers with peers on your local network ignore the limits above. · *only on android, windows, macos* |
| `downloads.cli.upload_enabled` | Enable upload / seeding | 启用上传 / 做种 |  | bool |  | `false` | Off by default. Seed back to the swarm after downloading. · *only on android, windows, macos* |
| `downloads.cli.upload_limit_kbps` | Upload limit (KB/s) | 上传限速 (KB/s) |  | number | 0 –  | `0` | 0 = unlimited |
| `downloads.cli.seed_time_limit_minutes` | Seed time limit (minutes) | 做种时长上限（分钟） |  | number | 0 –  | `0` | Stop uploading after seeding this long. 0 = unlimited. |
| `downloads.cli.seed_ratio_limit` | Seed ratio limit | 做种分享率上限 |  | number | 0 –  | `0.0` | Stop uploading once uploaded/downloaded reaches this — counted over the torrent's whole lifetime, including uploads while it is still downloading (downloading continues). 0 = unlimited. |
| `downloads.cli.qb_url` | qBittorrent WebUI URL | qBittorrent WebUI 地址 | External qBittorrent | text |  |  | e.g. http://127.0.0.1:8080. Leave empty to disable anime downloading. · *user only* |
| `downloads.cli.qb_username` | WebUI username | WebUI 用户名 | External qBittorrent | text |  |  |  |
| `downloads.cli.qb_password` | WebUI password | WebUI 密码 | External qBittorrent | secret |  |  | *user only* |
| `downloads.cli.test_connection` | Test connection | 测试连接 | External qBittorrent | action |  |  |  |
| `downloads.cli.tracker_auto_add` | Automatically add subscription trackers to new downloads | 自动把订阅 Tracker 加到新下载 | Tracker subscription | bool |  | `true` | The list is cached for 6 hours. A subscription failure will not block the download. · *only on android, windows, macos* |
| `downloads.cli.tracker_url` | Subscription URL | 订阅地址 | Tracker subscription | text |  | `https://cf.trackerslist.com/best.txt` | *only on android, windows, macos* |
| `downloads.cli.tracker_refresh` | Fetch trackers | 获取 Tracker | Tracker subscription | action |  |  | *only on android, windows, macos* |
| `downloads.cli.category` | qBittorrent category | qBittorrent 分类 | Engine and seeding | text |  | `fushi` | Downloads pushed by Fushi get this category; completion tracking only watches it. · *only on android, windows, macos* |
| `downloads.cli.max_connections` | Max connections | 最大连接数 | Engine and seeding | number | 0 –  | `0` | 0 = engine default · *only on android, windows, macos* |
| `downloads.cli.memory_limit_mb` | Memory limit (MB) | 内存占用上限（MB） | Engine and seeding | number | 0 –  | `0` | Cap engine memory. 0 = auto (based on device RAM). · *only on android, windows, macos* |
| `downloads.cli.listen_port` | Listen port | 监听端口 | Engine and seeding | number | 0 – 65535 | `0` | 0 = default (6881) · *only on android, windows, macos* |
| `downloads.cli.dht` | DHT | DHT | Engine and seeding | bool |  | `true` | *only on android, windows, macos* |
| `downloads.cli.lsd` | Local peer discovery (LSD) | 本地节点发现 (LSD) | Engine and seeding | bool |  | `true` | *only on android, windows, macos* |
| `downloads.cli.upnp` | UPnP port mapping | UPnP 端口映射 | Engine and seeding | bool |  | `true` | *only on android, windows, macos* |
| `downloads.cli.natpmp` | NAT-PMP port mapping | NAT-PMP 端口映射 | Engine and seeding | bool |  | `true` | *only on android, windows, macos* |
| `downloads.cli.anonymous` | Anonymous mode | 匿名模式 | Engine and seeding | bool |  | `false` | *only on android, windows, macos* |
| `downloads.cli.encryption` | Peer encryption | 节点加密 | Engine and seeding | choice | `prefer`, `forced`, `disabled` | `prefer` | *only on android, windows, macos* |
| `downloads.cli.max_active_downloads` | Max active downloads | 最大活跃下载数 | Engine and seeding | number | 0 –  | `0` | 0 = default · *only on android, windows, macos* |
| `downloads.cli.max_active_seeds` | Max active seeds | 最大活跃做种数 | Engine and seeding | number | 0 –  | `0` | 0 = default · *only on android, windows, macos* |
| `downloads.cli.max_upload_slots` | Max upload slots | 最大上传槽位 | Engine and seeding | number | 0 –  | `0` | 0 = default · *only on android, windows, macos* |
| `downloads.cli.antileech` | Enable anti-leech | 启用反吸血 | Engine and seeding | bool |  | `true` | *only on android, windows, macos* |
| `downloads.cli.ban_progress_cheat` | Ban progress cheat | 封禁进度作弊 | Engine and seeding | bool |  | `false` | *only on android, windows, macos* |
| `downloads.cli.ban_relative_cheat` | Ban relative progress cheat | 封禁相对进度作弊 | Engine and seeding | bool |  | `false` | *only on android, windows, macos* |
| `downloads.cli.max_ip_ports` | Max ports per IP | 同 IP 最大端口数 | Engine and seeding | number | 0 –  | `0` | 0 = off · *only on android, windows, macos* |
| `downloads.cli.ban_time_minutes` | Ban duration (min) | 封禁时长（分钟） | Engine and seeding | number | 0 –  | `0` | 0 = permanent · *only on android, windows, macos* |
| `downloads.routing.cli.path_mappings` | qBittorrent path mappings | qBittorrent 路径映射 | Completed downloads | list |  |  | *only on android, windows, macos* |
| `downloads.routing.cli.target_source` | Default folder | 默认文件夹 | Completed downloads | text |  | `none` | none = 不指定；或本机视频来源 id（候选见 `config run downloads.routing.cli.target_source_candidates`） · *only on android, windows, macos* |
| `downloads.routing.cli.target_source_candidates` | Default folder · candidates | 默认文件夹 · candidates | Completed downloads | action |  |  | *only on android, windows, macos* |

## Media tracking (媒体记录)

| Key | Name | 名称 | Where | Type | Values | Default | Notes |
|---|---|---|---|---|---|---|---|
| `media_tracking.cli.status` | Tracking status | 追踪状态 |  | action |  |  | Sync |
| `media_tracking.cli.connect` | Connect and verify | 连接并验证 |  | action |  |  | Create a personal access token with write permission |
| `media_tracking.cli.sync_now` | Sync now | 立即同步 |  | action |  |  |  |
| `media_tracking.cli.search` | Search a tracking site | 搜索追踪站点 |  | action |  |  |  |
| `media_tracking.cli.local_targets` | Local item | 本地条目 |  | action |  |  |  |
| `media_tracking.cli.mappings` | Item mappings | 条目映射 |  | list |  |  |  |
