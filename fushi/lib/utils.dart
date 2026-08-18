export 'i18n/strings.g.dart';

export 'src/utils/fushi_localisations.dart';

export 'src/utils/components/cache_image_provider.dart';
export 'src/utils/components/fushi_gamepad_keyboard.dart';
export 'src/utils/components/fushi_icon_button.dart';
export 'src/utils/components/fushi_reorderable_column.dart';
export 'src/utils/components/fushi_reorder_drag_listener.dart';
export 'src/utils/components/fushi_divider.dart';
export 'src/utils/components/fushi_dropdown.dart';
export 'src/utils/components/fushi_option_selection_page.dart';
export 'src/utils/components/fushi_marquee.dart';
export 'src/utils/components/fushi_tag.dart';
export 'src/utils/components/cover_badge.dart';
export 'src/utils/components/fushi_destructive_confirm_dialog.dart';
export 'src/utils/components/fushi_placeholder_message.dart';
export 'src/utils/components/shelf_card_widgets.dart';
export 'src/utils/components/fushi_text_selection_controls.dart';
export 'src/utils/components/content_language_picker.dart';
export 'src/utils/components/fushi_list_tile.dart';
export 'src/utils/components/fushi_focusable.dart';
export 'src/utils/components/fushi_focus_ring.dart';
export 'src/utils/components/galgame_poster_card.dart';
export 'src/utils/components/fushi_design_tokens.dart';
export 'src/utils/components/fushi_motion_tokens.dart';
export 'src/utils/components/fushi_material_components.dart';
export 'src/utils/components/library_section_tabs.dart';
export 'src/utils/components/settings_shared.dart';
export 'src/utils/app_ui_scale.dart';
export 'src/utils/popup_theme_css.dart';

export 'src/utils/misc/fushi_byte_format.dart';
export 'src/utils/misc/fushi_color.dart';
export 'src/utils/misc/fushi_time_format.dart';
export 'src/utils/misc/safe_file_name.dart';
export 'src/utils/misc/fushi_audio_handler.dart';
export 'package:fushi_core/src/models/fushi_text_selection.dart';
export 'src/utils/misc/volume_key_channel.dart';
export 'src/utils/misc/tts_channel.dart';
export 'src/utils/misc/word_audio_resolver.dart';
export 'src/utils/misc/error_log_service.dart';
export 'src/utils/misc/render_backend_service.dart';
export 'src/utils/misc/debug_log_service.dart';
export 'src/utils/misc/show_app_dialog.dart';
export 'src/utils/misc/update_checker.dart';
// 全应用出站代理解析层。原先是 update_checker 的 part（随上一行一起被导出），BUG-1348
// 把它提成独立库供同步层复用，故这里显式补一条 export，消费方 import 路径零变化。
export 'src/utils/net/app_proxy.dart';
// BUG-1498：公网出站的单一装配点（同步工厂），以及两个下游包的接线文件。
export 'src/utils/net/app_http.dart';
export 'src/utils/net/dictionary_dio.dart';
export 'src/utils/net/anki_remote_media_http.dart';
export 'src/utils/net/anki_addon_download_http.dart';
export 'src/utils/misc/update_check_cache.dart';
export 'src/utils/misc/fushi_toast.dart';
export 'src/utils/misc/webview_asset_url.dart';
export 'src/utils/misc/platform_utils.dart';
export 'src/utils/misc/gallery_image_picker.dart';

export 'src/utils/adaptive/fushi_adaptive.dart';
