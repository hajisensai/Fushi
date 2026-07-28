import 'package:flutter/material.dart';

import 'package:hibiki/utils.dart';

/// Jimaku API key 输入框——三个 Jimaku 界面（视频字幕对话框 / 番剧下载对话框 /
/// 合集批量对话框）共用的**唯一实现**。
///
/// 权威配置入口是「设置 → 视频 → 字幕」；对话框里的这一份是「还没配就地补」的
/// 快捷方式，因此 helper 文案里明写去哪儿改。此前三处各写一遍 `TextField` +
/// label/helper/obscure，改口径要改三处、也没人告诉用户设置页里也能改。
class JimakuApiKeyField extends StatelessWidget {
  const JimakuApiKeyField({
    required this.controller,
    this.onChanged,
    this.dense = false,
    this.showKeyIcon = false,
    super.key,
  });

  final TextEditingController controller;

  /// 输入变化回调（下载对话框据此直接落偏好；另两处在提交时统一写）。
  final ValueChanged<String>? onChanged;

  /// 紧凑排版（对话框里与其它 dense 输入框同高）。
  final bool dense;

  /// 行首钥匙图标（下载对话框的横幅式排版用）。
  final bool showKeyIcon;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      obscureText: true,
      decoration: InputDecoration(
        labelText: t.video_jimaku_api_key,
        helperText: '${t.video_jimaku_api_key_hint}\n'
            '${t.video_jimaku_api_key_settings_hint}',
        helperMaxLines: 3,
        isDense: dense,
        prefixIcon: showKeyIcon ? const Icon(Icons.vpn_key, size: 18) : null,
      ),
    );
  }
}
