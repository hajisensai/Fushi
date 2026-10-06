#!/usr/bin/env python3
"""生成 Fushi 语义图标层（M3E：Material Symbols Rounded 可变字体子集）。

产物（都入库，运行期 / 测试不依赖本脚本）：
  fushi/assets/icon_fonts/FushiSymbolsRounded.ttf        FILL=0 线框（可变 wght / GRAD / opsz）
  fushi/assets/icon_fonts/FushiSymbolsRoundedFilled.ttf  FILL=1 实心（同上，FILL 轴已钉死）
  fushi/lib/src/utils/fushi_icons.g.dart            语义名 → IconData + Apple（SF 风格）映射

为什么拆成两份字体而不是只用一份可变字体的 FILL 轴：选中态在大量 API 里只能传
`IconData`（`NavigationDestination.selectedIcon`、`AdaptiveNavItem.selectedIcon`、
`FushiIconButton(icon:)` ……），`IconData` 携带不了字体轴；把 FILL=1 实例化成另一个
字族后，「实心版」就是一个普通的 const `IconData`，任何调用点都能用，且 release 构建的
图标树摇（`--tree-shake-icons`）照样只留用到的码位。

用法（仓库根或任意目录都行）：
  1. 下载上游可变字体与码位表（google/material-design-icons，见 SOURCE_COMMIT）：
       variablefont/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf
       variablefont/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].codepoints
  2. python fushi/tool/icons/gen_fushi_symbols.py --font <ttf> --codepoints <file> \
         --flutter-sdk <flutter 根目录>
  3. cd fushi && dart format lib/src/utils/fushi_icons.g.dart

加一个语义图标：在 SYMBOLS 里加一行（语义名、Symbols 名、它取代的旧 Material
线框 / 实心 Icons 名、中文说明），重跑本脚本。Apple 设计系统的字形默认从旧 Material
图标在 `fushi_apple_icon_map.dart` 里的映射继承（迁移后 Apple 像素不变），需要时用
APPLE_OVERRIDES 指定。
"""

from __future__ import annotations

import argparse
import os
import re
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

SOURCE_COMMIT = "737e3324305806514d7909874fa1818ae1808232"
FAMILY = "FushiSymbols"
FAMILY_FILLED = "FushiSymbolsFilled"

# (语义名, Material Symbols 名, 旧线框 Icons 名, 旧实心 Icons 名, 中文说明)
# 旧 Icons 名用于继承 Apple 字形；没有旧对应的写 None。
SYMBOLS: list[tuple[str, str, str | None, str | None, str]] = [
    # ── 顶层导航 / 媒体类型 ──────────────────────────────────────────
    ("home", "home", "home_outlined", "home", "首页"),
    ("books", "menu_book", "menu_book_outlined", "menu_book", "书 / 书架"),
    ("manga", "photo_library", "photo_library_outlined", "photo_library", "漫画"),
    ("video", "movie", "movie_outlined", "movie", "视频"),
    ("browse", "explore", "explore_outlined", "explore", "浏览（来源 / 扩展 / 发现）"),
    ("lookup", "search", "search", "search", "查词 / 搜索"),
    ("games", "sports_esports", "sports_esports_outlined", "sports_esports", "游戏"),
    ("browserExtension", "extension", "extension_outlined", "extension", "浏览器扩展 / 插件"),
    ("settings", "tune", "tune_outlined", "tune", "设置（导航与入口）"),
    ("settingsGear", "settings", "settings_outlined", "settings", "齿轮设置（子页内的配置项）"),
    ("audiobook", "headphones", "headphones_outlined", "headphones", "有声书 / 听力"),
    ("dictionary", "dictionary", "library_books_outlined", "library_books", "词典"),
    ("subtitles", "subtitles", "subtitles_outlined", "subtitles", "字幕"),
    ("collection", "collections_bookmark", "collections_bookmark_outlined", "collections_bookmark", "合集"),
    ("tag", "sell", "sell_outlined", "sell", "标签"),
    ("statistics", "insights", "insights_outlined", "insights", "统计"),
    ("ankiCard", "style", "style_outlined", "style", "制卡 / Anki"),
    ("ocr", "document_scanner", "document_scanner_outlined", "document_scanner", "OCR / 识别"),
    ("lyrics", "lyrics", "lyrics_outlined", "lyrics", "歌词模式"),
    ("game", "videogame_asset", "videogame_asset_outlined", "videogame_asset", "游戏条目"),
    ("tv", "live_tv", "live_tv_outlined", "live_tv", "电视 / 番剧"),
    # ── 工具栏通用动作 ───────────────────────────────────────────────
    ("back", "arrow_back", "arrow_back", "arrow_back", "返回"),
    ("forward", "arrow_forward", "arrow_forward", "arrow_forward", "前进"),
    ("close", "close", "close", "close", "关闭"),
    ("more", "more_vert", "more_vert", "more_vert", "更多（竖）"),
    ("moreHoriz", "more_horiz", "more_horiz", "more_horiz", "更多（横）"),
    ("menu", "menu", "menu", "menu", "菜单"),
    ("add", "add", "add", "add", "新增"),
    ("addCircle", "add_circle", "add_circle_outline", "add_circle", "新增（圆）"),
    ("edit", "edit", "edit_outlined", "edit", "编辑"),
    ("rename", "drive_file_rename_outline", "drive_file_rename_outline", "drive_file_rename_outline", "重命名"),
    ("delete", "delete", "delete_outline", "delete", "删除"),
    ("deleteSweep", "delete_sweep", "delete_sweep_outlined", "delete_sweep", "批量清理"),
    ("refresh", "refresh", "refresh", "refresh", "刷新"),
    ("restart", "restart_alt", "restart_alt", "restart_alt", "重置 / 恢复默认"),
    ("undo", "undo", "undo", "undo", "撤销"),
    ("redo", "redo", "redo", "redo", "重做"),
    ("save", "save", "save_outlined", "save", "保存"),
    ("search", "search", "search", "search", "搜索"),
    ("manageSearch", "manage_search", "manage_search", "manage_search", "高级搜索 / 检索设置"),
    ("filter", "filter_alt", "filter_alt_outlined", "filter_alt", "筛选"),
    ("filterList", "filter_list", "filter_list", "filter_list", "筛选列表"),
    ("sort", "sort", "sort", "sort", "排序"),
    ("share", "share", "share_outlined", "share", "分享"),
    ("openInNew", "open_in_new", "open_in_new", "open_in_new", "外部打开"),
    ("download", "download", "download_outlined", "download", "下载"),
    ("upload", "upload", "upload_outlined", "upload", "上传"),
    ("importFile", "upload_file", "upload_file_outlined", "upload_file", "导入文件"),
    ("sync", "sync", "sync", "sync", "同步"),
    ("cloudSync", "cloud_sync", "cloud_sync_outlined", "cloud_sync", "云同步"),
    ("copy", "content_copy", "content_copy_outlined", "content_copy", "复制"),
    ("link", "link", "link", "link", "链接"),
    ("linkOff", "link_off", "link_off", "link_off", "取消链接"),
    ("pin", "push_pin", "push_pin_outlined", "push_pin", "置顶 / 固定"),
    ("bookmark", "bookmark", "bookmark_outline", "bookmark", "书签"),
    ("bookmarkAdd", "bookmark_add", "bookmark_add_outlined", "bookmark_add", "加书签"),
    ("favorite", "favorite", "favorite_border", "favorite", "收藏"),
    ("star", "star", "star_border", "star", "星标 / 评分"),
    ("history", "history", "history", "history", "历史"),
    ("schedule", "schedule", "schedule", "schedule", "时间 / 计划"),
    ("calendar", "calendar_month", "calendar_month_outlined", "calendar_month", "日历"),
    ("timer", "timer", "timer_outlined", "timer", "计时"),
    ("speed", "speed", "speed", "speed", "速度"),
    ("libraryAdd", "library_add", "library_add_outlined", "library_add", "加入库"),
    ("dragHandle", "drag_handle", "drag_handle", "drag_handle", "拖动手柄"),
    ("selectAll", "select_all", "select_all", "select_all", "全选"),
    ("checklist", "checklist", "checklist", "checklist", "多选 / 清单"),
    ("swap", "swap_horiz", "swap_horiz", "swap_horiz", "切换 / 交换"),
    ("zoomIn", "zoom_in", "zoom_in", "zoom_in", "放大"),
    ("zoomOut", "zoom_out", "zoom_out", "zoom_out", "缩小"),
    ("fullscreen", "fullscreen", "fullscreen", "fullscreen", "全屏"),
    ("fullscreenExit", "fullscreen_exit", "fullscreen_exit", "fullscreen_exit", "退出全屏"),
    ("gridView", "grid_view", "grid_view_outlined", "grid_view", "网格视图"),
    ("listView", "view_list", "view_list_outlined", "view_list", "列表视图"),
    ("visibility", "visibility", "visibility_outlined", "visibility", "显示"),
    ("visibilityOff", "visibility_off", "visibility_off_outlined", "visibility_off", "隐藏"),
    ("lock", "lock", "lock_outline", "lock", "锁定"),
    ("lockOpen", "lock_open", "lock_open_outlined", "lock_open", "解锁"),
    # ── 方向 / 展开 ──────────────────────────────────────────────────
    ("chevronRight", "chevron_right", "chevron_right", "chevron_right", "进入（右箭头）"),
    ("chevronLeft", "chevron_left", "chevron_left", "chevron_left", "左箭头"),
    ("expandMore", "expand_more", "expand_more", "expand_more", "展开"),
    ("expandLess", "expand_less", "expand_less", "expand_less", "收起"),
    ("dropDown", "arrow_drop_down", "arrow_drop_down", "arrow_drop_down", "下拉"),
    # ── 状态 ─────────────────────────────────────────────────────────
    ("check", "check", "check", "check", "完成 / 勾"),
    ("success", "check_circle", "check_circle_outline", "check_circle", "成功"),
    ("info", "info", "info_outline", "info", "信息"),
    ("warning", "warning", "warning_amber_outlined", "warning", "警告"),
    ("error", "error", "error_outline", "error", "错误"),
    ("help", "help", "help_outline", "help", "帮助"),
    ("block", "block", "block", "block", "禁止 / 屏蔽"),
    ("pending", "hourglass_top", "hourglass_top", "hourglass_top", "等待中"),
    ("downloading", "downloading", "downloading", "downloading", "下载中"),
    ("downloadDone", "download_done", "download_done", "download_done", "已下载"),
    ("cloud", "cloud", "cloud_outlined", "cloud", "云端"),
    ("cloudOff", "cloud_off", "cloud_off_outlined", "cloud_off", "离线 / 云端不可用"),
    ("cloudDownload", "cloud_download", "cloud_download_outlined", "cloud_download", "云端下载"),
    ("cloudUpload", "cloud_upload", "cloud_upload_outlined", "cloud_upload", "云端上传"),
    ("searchOff", "search_off", "search_off", "search_off", "无搜索结果"),
    ("brokenImage", "broken_image", "broken_image_outlined", "broken_image", "图片损坏"),
    ("flag", "flag", "flag_outlined", "flag", "标记"),
    ("verified", "verified", "verified_outlined", "verified", "已验证"),
    ("notifications", "notifications", "notifications_outlined", "notifications", "通知"),
    # ── 设置分组 ─────────────────────────────────────────────────────
    ("appearance", "palette", "palette_outlined", "palette", "外观 / 配色"),
    ("language", "translate", "translate", "translate", "语言 / 翻译"),
    ("globe", "public", "public", "public", "网络 / 公开"),
    ("textFields", "text_fields", "text_fields", "text_fields", "文字"),
    ("fontSize", "format_size", "format_size", "format_size", "字号"),
    ("font", "font_download", "font_download_outlined", "font_download", "字体"),
    ("keyboard", "keyboard", "keyboard_outlined", "keyboard", "键盘 / 快捷键"),
    ("mouse", "mouse", "mouse_outlined", "mouse", "鼠标"),
    ("touch", "touch_app", "touch_app_outlined", "touch_app", "触控 / 手势"),
    ("devices", "devices", "devices_outlined", "devices", "设备 / 互联"),
    ("server", "dns", "dns_outlined", "dns", "服务器"),
    ("hub", "hub", "hub_outlined", "hub", "互联中枢"),
    ("wifi", "wifi", "wifi", "wifi", "局域网"),
    ("person", "person", "person_outline", "person", "个人 / 档案"),
    ("account", "account_circle", "account_circle_outlined", "account_circle", "账号"),
    ("login", "login", "login", "login", "登录"),
    ("logout", "logout", "logout", "logout", "登出"),
    ("key", "key", "key_outlined", "key", "密钥"),
    ("shield", "shield", "shield_outlined", "shield", "安全 / 隐私"),
    ("storage", "inventory_2", "inventory_2_outlined", "inventory_2", "存储 / 数据"),
    ("backup", "backup", "backup_outlined", "backup", "备份"),
    ("restoreBackup", "settings_backup_restore", "settings_backup_restore", "settings_backup_restore", "还原备份"),
    ("folder", "folder", "folder_outlined", "folder", "文件夹"),
    ("folderOpen", "folder_open", "folder_open_outlined", "folder_open", "打开文件夹"),
    ("file", "description", "description_outlined", "description", "文件 / 文档"),
    ("image", "image", "image_outlined", "image", "图片"),
    ("imageSearch", "image_search", "image_search_outlined", "image_search", "以图搜索"),
    ("darkMode", "dark_mode", "dark_mode_outlined", "dark_mode", "深色"),
    ("lightMode", "light_mode", "light_mode_outlined", "light_mode", "浅色"),
    ("brightnessAuto", "brightness_6", "brightness_6_outlined", "brightness_6", "跟随系统明暗"),
    ("ai", "auto_awesome", "auto_awesome_outlined", "auto_awesome", "AI / 智能"),
    ("barChart", "bar_chart", "bar_chart", "bar_chart", "柱状图"),
    ("widgets", "widgets", "widgets_outlined", "widgets", "组件 / 模块"),
    ("dashboardCustomize", "dashboard_customize", "dashboard_customize_outlined", "dashboard_customize", "自定义面板"),
    ("quote", "format_quote", "format_quote", "format_quote", "引文 / 例句"),
    ("voice", "record_voice_over", "record_voice_over_outlined", "record_voice_over", "朗读 / 人声"),
    ("travelExplore", "travel_explore", "travel_explore", "travel_explore", "在线发现"),
    ("readingMode", "auto_stories", "auto_stories_outlined", "auto_stories", "阅读 / 翻页"),
    ("aiAssistant", "smart_toy", "smart_toy_outlined", "smart_toy", "AI 助手 / AI 设置"),
    ("floatingBall", "blur_circular", "blur_circular_outlined", "blur_circular", "悬浮球"),
    ("modelTraining", "model_training", "model_training_outlined", "model_training", "模型 / 训练"),
    ("profiles", "manage_accounts", "manage_accounts_outlined", "manage_accounts", "档案管理"),
    ("sdStorage", "sd_storage", "sd_storage_outlined", "sd_storage", "存储位置"),
    ("system", "settings_suggest", "settings_suggest_outlined", "settings_suggest", "系统 / 通用"),
    ("tracking", "auto_awesome_motion", "auto_awesome_motion_outlined", "auto_awesome_motion", "进度追踪"),
    ("fingerprint", "fingerprint", "fingerprint", "fingerprint", "身份 / 指纹"),
    ("moveFile", "drive_file_move", "drive_file_move_outline", "drive_file_move", "移动文件"),
    # ── 播放 ─────────────────────────────────────────────────────────
    ("play", "play_arrow", "play_arrow_outlined", "play_arrow", "播放"),
    ("pause", "pause", "pause_outlined", "pause", "暂停"),
    ("playCircle", "play_circle", "play_circle_outline", "play_circle", "播放（圆）"),
    ("stop", "stop", "stop", "stop", "停止"),
    ("skipNext", "skip_next", "skip_next_outlined", "skip_next", "下一项"),
    ("skipPrevious", "skip_previous", "skip_previous_outlined", "skip_previous", "上一项"),
    ("fastForward", "fast_forward", "fast_forward_outlined", "fast_forward", "快进"),
    ("fastRewind", "fast_rewind", "fast_rewind_outlined", "fast_rewind", "快退"),
    ("replay", "replay", "replay", "replay", "重播"),
    ("repeat", "repeat", "repeat", "repeat", "循环"),
    ("volumeUp", "volume_up", "volume_up_outlined", "volume_up", "音量"),
    ("volumeOff", "volume_off", "volume_off_outlined", "volume_off", "静音"),
    ("audio", "graphic_eq", "graphic_eq", "graphic_eq", "音频 / 波形"),
    ("music", "music_note", "music_note_outlined", "music_note", "音乐"),
    ("mic", "mic", "mic_none", "mic", "麦克风"),
    ("pictureInPicture", "picture_in_picture_alt", "picture_in_picture_alt_outlined", "picture_in_picture_alt", "画中画"),
    ("cast", "cast", "cast", "cast", "投屏"),
    ("pauseCircle", "pause_circle", "pause_circle_outline", "pause_circle", "暂停（圆）"),
    ("stepBackward", "arrow_left", "arrow_left", "arrow_left", "逐帧后退（小三角）"),
    ("stepForward", "arrow_right", "arrow_right", "arrow_right", "逐帧前进（小三角）"),
    ("slowMotion", "slow_motion_video", "slow_motion_video", "slow_motion_video", "减速 / 慢放"),
    ("replay5", "replay_5", "replay_5", "replay_5", "回放上一句 / 后退 5"),
    ("firstPage", "first_page", "first_page", "first_page", "上一章 / 到开头"),
    ("lastPage", "last_page", "last_page", "last_page", "下一章 / 到末尾"),
    ("playlist", "playlist_play", "playlist_play", "playlist_play", "播放列表 / 分集列表"),
    ("numberedList", "format_list_numbered", "format_list_numbered", "format_list_numbered", "编号列表 / 章节列表"),
    ("title", "title", "title", "title", "标题"),
    ("volumeDown", "volume_down", "volume_down", "volume_down", "音量减"),
    ("camera", "photo_camera", "photo_camera_outlined", "photo_camera", "截图 / 拍照"),
    ("compare", "compare", "compare", "compare", "对比"),
    ("blur", "blur_on", "blur_on", "blur_on", "模糊遮蔽"),
    ("blurLinear", "blur_linear", "blur_linear", "blur_linear", "线性模糊（副字幕遮蔽）"),
    ("subtitlesOff", "subtitles_off", "subtitles_off_outlined", "subtitles_off", "隐藏字幕"),
    ("captionsOff", "closed_caption_disabled", "closed_caption_disabled_outlined", "closed_caption_disabled", "隐藏副字幕"),
    ("moreTime", "more_time", "more_time", "more_time", "延后 / 加时"),
    ("alignLeft", "align_horizontal_left", "align_horizontal_left", "align_horizontal_left", "向前对齐"),
    ("alignRight", "align_horizontal_right", "align_horizontal_right", "align_horizontal_right", "向后对齐"),
    ("highQuality", "high_quality", "high_quality_outlined", "high_quality", "画质"),
    ("animation", "animation", "animation_outlined", "animation", "动画 / 插帧"),
    ("myLocation", "my_location", "my_location", "my_location", "定位到当前"),
    ("signalLow", "signal_cellular_alt_1_bar", "signal_cellular_alt_1_bar", "signal_cellular_alt_1_bar", "强度：低（一格）"),
    ("signalMedium", "signal_cellular_alt_2_bar", "signal_cellular_alt_2_bar", "signal_cellular_alt_2_bar", "强度：中（两格）"),
    ("signalHigh", "signal_cellular_alt", "signal_cellular_alt", "signal_cellular_alt", "强度：高（三格）"),
    # ── 社交 / 统计 ──────────────────────────────────────────────────
    ("personAdd", "person_add", "person_add_alt_1_outlined", "person_add_alt_1", "加好友 / 添加账号"),
    ("personRemove", "person_remove", "person_remove_outlined", "person_remove", "删好友"),
    ("personCheck", "how_to_reg", "how_to_reg_outlined", "how_to_reg", "已互关 / 已登记"),
    ("group", "group", "group_outlined", "group", "群组 / 好友"),
    ("phone", "smartphone", "smartphone", "smartphone", "手机 / 当前设备"),
    ("deviceRemove", "phonelink_erase", "phonelink_erase_outlined", "phonelink_erase", "移除设备"),
    ("emailUnread", "mark_email_unread", "mark_email_unread_outlined", "mark_email_unread", "邮件验证"),
    ("streak", "local_fire_department", "local_fire_department_outlined", "local_fire_department", "连续天数（火焰）"),
    ("trendingUp", "trending_up", "trending_up", "trending_up", "上升趋势"),
    ("lineChart", "show_chart", "show_chart", "show_chart", "折线图"),
    ("functions", "functions", "functions", "functions", "合计 / 求和"),
    ("globeOff", "public_off", "public_off_outlined", "public_off", "不可公开访问 / 离线"),
    # ── 阅读器 / 排版 / 列表（2026-10-06 收紧白名单）─────────────────
    ("apps", "apps", "apps_outlined", "apps", "应用 / 全部"),
    ("arrowDown", "arrow_downward", "arrow_downward_outlined", "arrow_downward", "下移"),
    ("arrowUp", "arrow_upward", "arrow_upward_outlined", "arrow_upward", "上移"),
    ("bookmarks", "bookmarks", "bookmarks_outlined", "bookmarks", "书签列表"),
    ("borderBottom", "border_bottom", "border_bottom_outlined", "border_bottom", "下边距"),
    ("borderLeft", "border_left", "border_left_outlined", "border_left", "左边距"),
    ("borderRight", "border_right", "border_right_outlined", "border_right", "右边距"),
    ("borderTop", "border_top", "border_top_outlined", "border_top", "上边距"),
    ("cancel", "cancel", "cancel_outlined", "cancel", "取消 / 清除（圆叉）"),
    ("readerMode", "chrome_reader_mode", "chrome_reader_mode_outlined", "chrome_reader_mode", "阅读模式"),
    ("code", "code", "code_outlined", "code", "代码 / CSS"),
    ("collections", "collections", "collections_outlined", "collections", "图集 / 插图"),
    ("paste", "content_paste", "content_paste_outlined", "content_paste", "粘贴"),
    ("copyAll", "copy_all", "copy_all_outlined", "copy_all", "全部复制"),
    ("dataUsage", "data_usage", "data_usage_outlined", "data_usage", "用量 / 进度环"),
    ("dragIndicator", "drag_indicator", "drag_indicator_outlined", "drag_indicator", "拖动把手（点阵）"),
    ("trophy", "emoji_events", "emoji_events_outlined", "emoji_events", "成就 / 奖杯"),
    ("exitToApp", "exit_to_app", "exit_to_app_outlined", "exit_to_app", "退出到应用"),
    ("filterOff", "filter_alt_off", "filter_alt_off_outlined", "filter_alt_off", "清除筛选"),
    ("alignJustify", "format_align_justify", "format_align_justify_outlined", "format_align_justify", "两端对齐"),
    ("bold", "format_bold", "format_bold_outlined", "format_bold", "粗体"),
    ("indent", "format_indent_increase", "format_indent_increase_outlined", "format_indent_increase", "缩进"),
    ("lineSpacing", "format_line_spacing", "format_line_spacing_outlined", "format_line_spacing", "行距"),
    ("bulletList", "format_list_bulleted", "format_list_bulleted_outlined", "format_list_bulleted", "项目列表 / 目录"),
    ("formatShapes", "format_shapes", "format_shapes_outlined", "format_shapes", "排版形状"),
    ("forum", "forum", "forum_outlined", "forum", "讨论 / 评论"),
    ("forward10", "forward_10", "forward_10_outlined", "forward_10", "前进 10"),
    ("replay10", "replay_10", "replay_10_outlined", "replay_10", "后退 10"),
    ("commandKey", "keyboard_command_key", "keyboard_command_key_outlined", "keyboard_command_key", "Command 键"),
    ("doubleChevronLeft", "keyboard_double_arrow_left", "keyboard_double_arrow_left_outlined", "keyboard_double_arrow_left", "到最前"),
    ("doubleChevronRight", "keyboard_double_arrow_right", "keyboard_double_arrow_right_outlined", "keyboard_double_arrow_right", "到最后"),
    ("laptop", "laptop", "laptop_outlined", "laptop", "电脑"),
    ("lightbulb", "lightbulb", "lightbulb_outlined", "lightbulb", "提示"),
    ("merge", "merge_type", "merge_type_outlined", "merge_type", "合并"),
    ("notificationsActive", "notifications_active", "notifications_active_outlined", "notifications_active", "通知开启"),
    ("notificationsOff", "notifications_off", "notifications_off_outlined", "notifications_off", "通知关闭"),
    ("radioUnchecked", "radio_button_unchecked", "radio_button_unchecked_outlined", "radio_button_unchecked", "未选中（圆）"),
    ("remove", "remove", "remove_outlined", "remove", "减少 / 移除（减号）"),
    ("removeCircle", "remove_circle", "remove_circle_outlined", "remove_circle", "移除（圆）"),
    ("sortByAlpha", "sort_by_alpha", "sort_by_alpha_outlined", "sort_by_alpha", "按字母排序"),
    ("spaceBar", "space_bar", "space_bar_outlined", "space_bar", "空格 / 间距"),
    ("subscriptions", "subscriptions", "subscriptions_outlined", "subscriptions", "订阅"),
    ("swapCircle", "swap_horizontal_circle", "swap_horizontal_circle_outlined", "swap_horizontal_circle", "切换（圆）"),
    ("swapVert", "swap_vert", "swap_vert_outlined", "swap_vert", "上下交换"),
    ("swipe", "swipe", "swipe_outlined", "swipe", "滑动手势"),
    ("syncProblem", "sync_problem", "sync_problem_outlined", "sync_problem", "同步异常"),
    ("textDecrease", "text_decrease", "text_decrease_outlined", "text_decrease", "字号减"),
    ("textIncrease", "text_increase", "text_increase_outlined", "text_increase", "字号加"),
    ("textVertical", "text_rotate_vertical", "text_rotate_vertical_outlined", "text_rotate_vertical", "竖排"),
    ("textHorizontal", "text_rotation_none", "text_rotation_none_outlined", "text_rotation_none", "横排"),
    ("timerOff", "timer_off", "timer_off_outlined", "timer_off", "关闭计时"),
    ("toc", "toc", "toc_outlined", "toc", "目录"),
    ("alignBottom", "vertical_align_bottom", "vertical_align_bottom_outlined", "vertical_align_bottom", "底部对齐"),
    ("alignCenterVertical", "vertical_align_center", "vertical_align_center_outlined", "vertical_align_center", "居中对齐 / 跟随当前"),
    ("alignTop", "vertical_align_top", "vertical_align_top_outlined", "vertical_align_top", "顶部对齐"),
    ("viewAgenda", "view_agenda", "view_agenda_outlined", "view_agenda", "卡片列表视图"),
    ("viewColumn", "view_column", "view_column_outlined", "view_column", "分栏视图"),
    ("webAsset", "web_asset", "web_asset_outlined", "web_asset", "窗口 / 页面元素"),
    ("webAssetOff", "web_asset_off", "web_asset_off_outlined", "web_asset_off", "隐藏页面元素"),
]

# 旧 Material 图标在 Apple 映射表里没有、或映射不合适时，直接指定 CupertinoIcons 名
# （线框, 实心）。
APPLE_OVERRIDES: dict[str, tuple[str, str]] = {
    "settingsGear": ("gear", "gear_solid"),
    "dictionary": ("book", "book_fill"),
    "manga": ("photo_on_rectangle", "photo_fill_on_rectangle_fill"),
    "menu": ("line_horizontal_3", "line_horizontal_3"),
    "redo": ("arrow_uturn_right", "arrow_uturn_right"),
    "linkOff": ("link", "link"),
    "selectAll": ("checkmark_square", "checkmark_square_fill"),
    "searchOff": ("search", "search"),
    "brokenImage": ("photo", "photo_fill"),
    "mouse": ("cursor_rays", "cursor_rays"),
    "wifi": ("wifi", "wifi"),
    "imageSearch": ("photo", "photo_fill"),
    "voice": ("waveform", "waveform"),
    "aiAssistant": ("sparkles", "sparkles"),
    "floatingBall": ("smallcircle_circle", "smallcircle_fill_circle"),
    "modelTraining": ("arrow_2_circlepath", "arrow_2_circlepath"),
    "sdStorage": ("tray_full", "tray_full_fill"),
    "tracking": ("rectangle_stack", "rectangle_stack_fill"),
    "fingerprint": ("lock_shield", "lock_shield_fill"),
    "slowMotion": ("tortoise", "tortoise_fill"),
    "replay5": ("gobackward", "gobackward"),
    "compare": ("square_split_2x1", "square_split_2x1_fill"),
    "blur": ("circle_grid_3x3", "circle_grid_3x3_fill"),
    "blurLinear": ("line_horizontal_3_decrease", "line_horizontal_3_decrease"),
    "subtitlesOff": ("eye_slash", "eye_slash_fill"),
    "captionsOff": ("captions_bubble", "captions_bubble_fill"),
    "moreTime": ("goforward_plus", "goforward_plus"),
    "highQuality": ("tv", "tv_fill"),
    "animation": ("wand_stars", "wand_stars"),
    "signalLow": ("chart_bar", "chart_bar_fill"),
    "signalMedium": ("chart_bar", "chart_bar_fill"),
    "signalHigh": ("chart_bar", "chart_bar_fill"),
    "deviceRemove": ("xmark_rectangle", "xmark_rectangle_fill"),
    "trendingUp": ("arrow_up_right", "arrow_up_right"),
    "functions": ("sum", "sum"),
    "globeOff": ("wifi_slash", "wifi_slash"),
    "apps": ("square_grid_2x2", "square_grid_2x2_fill"),
    "borderBottom": ("arrow_down_to_line", "arrow_down_to_line"),
    "borderLeft": ("arrow_left_to_line", "arrow_left_to_line"),
    "borderRight": ("arrow_right_to_line", "arrow_right_to_line"),
    "borderTop": ("arrow_up_to_line", "arrow_up_to_line"),
    "dataUsage": ("chart_pie", "chart_pie_fill"),
    "filterOff": ("line_horizontal_3_decrease_circle", "line_horizontal_3_decrease_circle_fill"),
    "alignJustify": ("text_justify", "text_justify"),
    "lineSpacing": ("line_horizontal_3", "line_horizontal_3"),
    "formatShapes": ("textformat", "textformat"),
    "laptop": ("desktopcomputer", "desktopcomputer"),
    "lightbulb": ("lightbulb", "lightbulb_fill"),
    "removeCircle": ("minus_circle", "minus_circle_fill"),
    "spaceBar": ("textformat_alt", "textformat_alt"),
    "swapCircle": ("arrow_right_arrow_left_circle", "arrow_right_arrow_left_circle_fill"),
    "syncProblem": ("arrow_2_circlepath_circle", "arrow_2_circlepath_circle_fill"),
    "textVertical": ("arrow_down", "arrow_down"),
    "textHorizontal": ("arrow_right", "arrow_right"),
    "timerOff": ("stopwatch", "stopwatch_fill"),
    "toc": ("list_dash", "list_dash"),
    "alignCenterVertical": ("text_aligncenter", "text_aligncenter"),
    "webAssetOff": ("xmark_rectangle", "xmark_rectangle_fill"),
}


def parse_material_icons(sdk: str) -> tuple[dict[str, int], set[str]]:
    """旧 Icons 名 → 码位，以及带 matchTextDirection（RTL 镜像）的名字集合。"""
    path = os.path.join(sdk, "packages", "flutter", "lib", "src", "material", "icons.dart")
    out: dict[str, int] = {}
    mirrored: set[str] = set()
    pat = re.compile(
        r"static const IconData (\w+) = IconData\(\s*0x([0-9a-f]+),\s*fontFamily: 'MaterialIcons'(,\s*matchTextDirection: true)?"
    )
    with open(path, encoding="utf-8") as f:
        for m in pat.finditer(f.read()):
            out[m.group(1)] = int(m.group(2), 16)
            if m.group(3):
                mirrored.add(m.group(1))
    return out, mirrored


def parse_cupertino_icons(sdk: str) -> set[str]:
    path = os.path.join(sdk, "packages", "flutter", "lib", "src", "cupertino", "icons.dart")
    with open(path, encoding="utf-8") as f:
        return set(re.findall(r"static const IconData (\w+) =", f.read()))


def parse_apple_map(repo_fushi: str) -> dict[int, str]:
    path = os.path.join(repo_fushi, "lib", "src", "utils", "components", "glass", "fushi_apple_icon_map.dart")
    out: dict[int, str] = {}
    pat = re.compile(r"^\s*0x([0-9a-f]+): CupertinoIcons\.(\w+),")
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = pat.search(line)
            if m:
                out[int(m.group(1), 16)] = m.group(2)
    return out


def parse_codepoints(path: str) -> dict[str, int]:
    out: dict[str, int] = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2:
                out[parts[0]] = int(parts[1], 16)
    return out


def build_font(src: str, dst: str, codepoints: list[int], family: str, fill: float | None) -> None:
    font = TTFont(src)
    # 先按码位取子集（整份 15 MB 可变字体直接实例化要几分钟），再收窄轴。
    opts = subset.Options()
    opts.layout_features = []  # 只按码位取字形，不要连字表（体积大头之一）
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.glyph_names = False
    opts.hinting = False
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=codepoints)
    sub.subset(font)
    # 轴范围收窄到本仓实际用得到的区间（体积约 -30%）：GRAD 只用 0（亮）与 -25（暗色
    # 背景防光晕，M3 规范建议值）；wght 300..700 覆盖 Light 到 Bold。opsz 20..48 全保留。
    limits: dict[str, object] = {"GRAD": (-25, 0), "wght": (300, 700)}
    if fill is not None:
        # 钉死 FILL 轴，保留 wght / GRAD / opsz 可变。
        limits["FILL"] = fill
    font = instancer.instantiateVariableFont(font, limits)
    for rec in font["name"].names:
        if rec.nameID in (1, 4, 6, 16):
            rec.string = family
    font.save(dst)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", required=True)
    ap.add_argument("--codepoints", required=True)
    ap.add_argument("--flutter-sdk", required=True)
    args = ap.parse_args()

    fushi = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
    material, mirrored = parse_material_icons(args.flutter_sdk)
    cupertino = parse_cupertino_icons(args.flutter_sdk)
    apple_map = parse_apple_map(fushi)
    cps = parse_codepoints(args.codepoints)

    names_seen: set[str] = set()
    apple_by_cp: dict[int, tuple[str | None, str | None]] = {}
    rows = []
    errors: list[str] = []
    for name, sym, legacy_o, legacy_f, doc in SYMBOLS:
        if name in names_seen:
            errors.append(f"duplicate semantic name {name}")
        names_seen.add(name)
        if sym not in cps:
            errors.append(f"{name}: symbol {sym} not in codepoints")
            continue
        cp = cps[sym]
        if name in APPLE_OVERRIDES:
            ao, af = APPLE_OVERRIDES[name]
        else:
            ao = apple_map.get(material.get(legacy_o, -1)) if legacy_o else None
            af = apple_map.get(material.get(legacy_f, -1)) if legacy_f else None
            if legacy_o and legacy_o not in material:
                errors.append(f"{name}: legacy icon {legacy_o} unknown")
            if legacy_f and legacy_f not in material:
                errors.append(f"{name}: legacy icon {legacy_f} unknown")
            af = af or ao
            ao = ao or af
        for a in (ao, af):
            if a is not None and a not in cupertino:
                errors.append(f"{name}: CupertinoIcons.{a} unknown")
        prev = apple_by_cp.get(cp)
        if prev is not None and prev != (ao, af):
            errors.append(f"{name}: codepoint {cp:#x} shared with different Apple glyphs {prev} vs {(ao, af)}")
        apple_by_cp[cp] = (ao, af)
        rows.append((name, sym, cp, ao, af, doc, legacy_o, legacy_f, legacy_o in mirrored))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    unique_cps = sorted({r[2] for r in rows})
    fonts_dir = os.path.join(fushi, "assets", "icon_fonts")
    build_font(args.font, os.path.join(fonts_dir, "FushiSymbolsRounded.ttf"), unique_cps, FAMILY, None)
    # 线框字体保留 FILL 轴（0..1），调用方仍可用 Icon(fill:) 做过渡动画；实心字体钉 FILL=1。
    build_font(args.font, os.path.join(fonts_dir, "FushiSymbolsRoundedFilled.ttf"), unique_cps, FAMILY_FILLED, 1.0)

    out = []
    out.append("// GENERATED by fushi/tool/icons/gen_fushi_symbols.py — 不要手改，改 SYMBOLS 表后重跑。")
    out.append(f"// Material Symbols Rounded @ google/material-design-icons {SOURCE_COMMIT}")
    out.append("part of 'fushi_icons.dart';")
    out.append("")
    out.append("/// 语义图标表（线框 / FILL=0）。选中态用 [FushiIcons.filled]。")
    out.append("abstract final class FushiIcons {")
    mirrored_cps: set[int] = set()
    for name, sym, cp, ao, af, doc, lo, lf, mir in rows:
        legacy = f"（取代 Icons.{lo} / Icons.{lf}）" if lo else ""
        out.append(f"  /// {doc}：Symbols `{sym}`{legacy}")
        mt = ", matchTextDirection: true" if mir else ""
        if mir:
            mirrored_cps.add(cp)
        out.append(f"  static const IconData {name} = IconData(0x{cp:x}, fontFamily: kFushiSymbolsFontFamily{mt});")
    out.append("")
    out.append("  /// 全部语义名 → 线框图标（测试 / 样张页遍历用）。")
    out.append("  static const Map<String, IconData> all = <String, IconData>{")
    for r in rows:
        out.append(f"    '{r[0]}': {r[0]},")
    out.append("  };")
    out.append("")
    out.append("  /// [icon] 的实心（FILL=1）版本：选中态 / 激活态用。非语义图标原样返回。")
    out.append("  static IconData filled(IconData icon) {")
    out.append("    if (icon.fontFamily != kFushiSymbolsFontFamily) return icon;")
    out.append("    return _filled[icon.codePoint] ?? icon;")
    out.append("  }")
    out.append("")
    out.append("  /// [filled] 为 true 时取实心版，否则原样（导航项 / 开关按钮常用写法）。")
    out.append("  static IconData resolve(IconData icon, {required bool filled}) =>")
    out.append("      filled ? FushiIcons.filled(icon) : icon;")
    out.append("")
    out.append("  static const Map<int, IconData> _filled = <int, IconData>{")
    for cp in unique_cps:
        mt = ", matchTextDirection: true" if cp in mirrored_cps else ""
        out.append(f"    0x{cp:x}: IconData(0x{cp:x}, fontFamily: kFushiSymbolsFilledFontFamily{mt}),")
    out.append("  };")
    out.append("}")
    out.append("")
    out.append("/// 语义图标码位 → Apple 设计系统的 SF 风格字形（线框, 实心）。")
    out.append("const Map<int, (IconData, IconData)> kFushiSymbolAppleMap = <int, (IconData, IconData)>{")
    for cp in unique_cps:
        ao, af = apple_by_cp[cp]
        if ao is None:
            continue
        out.append(f"  0x{cp:x}: (CupertinoIcons.{ao}, CupertinoIcons.{af}),")
    out.append("};")
    out.append("")
    with open(os.path.join(fushi, "lib", "src", "utils", "fushi_icons.g.dart"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))
    missing_apple = [r[0] for r in rows if r[3] is None]
    print(f"{len(rows)} semantic icons, {len(unique_cps)} glyphs; no Apple glyph: {missing_apple}")
    for fn in ("FushiSymbolsRounded.ttf", "FushiSymbolsRoundedFilled.ttf"):
        print(fn, os.path.getsize(os.path.join(fonts_dir, fn)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
