# Requirements: Hibiki 全局 MD3 UI 重设计

## 目标

参照 Seal 应用 (JunkFood02/Seal) 的 Material Design 3 设计语言，对 Hibiki 所有 UI 页面进行重设计。

## 参考来源

9 张 Seal 截图 (`.codex-test/reference/seal/1-9.jpg`)：
1. 主页 — 大标题 "Seal"、FAB (rounded square)、卡片 (大圆角)
2. 底部弹窗 — drag handle、分段标题 (primary 色)、chip 选项、双按钮
3. 选择列表 — checkbox (filled green)、缩略图 + 文字列表
4. 下载历史 — 大标题 "Downloads"、filter chips 横向滚动、列表 + 详情弹窗
5. 格式选择 — 卡片选项 (selected = primaryContainer fill)、分段标题
6. 模板编辑 — OutlinedTextField + floating label、chips wrap 布局
7. 自定义命令 — toggle 高亮卡 (accent background)、radio 列表
8. 显示设置 (Light) — 预览卡片、颜色选择圆圈、toggle + icon 列表
9. 显示设置 (Dark) — 完整深色映射

## Seal MD3 设计令牌 (从截图提取)

### 排版
- 页面标题: Headline Large / Display Small, 左对齐, bold
- 分段标题: Title Small / Label Large, primary 色
- 列表标题: Body Large, onSurface
- 副标题: Body Medium, onSurfaceVariant

### 圆角
- 卡片: ~12-16dp
- 对话框/底部弹窗: ~28dp 顶部
- FAB: ~16dp (rounded square)
- Chip: ~8dp
- 按钮: ~20dp (full capsule)

### 颜色语义
- 页面背景: surface
- 卡片: surfaceContainerLow / surfaceContainer
- 选中态: primaryContainer / secondaryContainer
- 分段标题: primary
- Toggle 高亮: primaryContainer background
- FAB: primaryContainer fill + onPrimaryContainer icon

### 间距
- 页面水平: 16-24dp
- 列表项高度: 56-72dp
- 分段间距: 16-24dp

## 约束

1. 使用现有 HibikiDesignTokens 架构 — 修改令牌值，不改架构
2. 保持 Material/Cupertino adaptive 分支 — 只改 Material 路径
3. 不破坏现有功能 — 仅视觉变更
4. 现有 dirty files 中的进行中工作 (AdaptiveSettingsTextField) 保持兼容
5. 运行 flutter analyze 和 flutter test 验证

## 验收标准

1. 所有 settings 页面的 section header 使用 primary 色
2. 卡片圆角 >= 12dp
3. 对话框/弹窗圆角 >= 28dp
4. ThemeData 包含 CardTheme, BottomSheetTheme, FABTheme, ChipTheme, FilledButtonTheme, OutlinedButtonTheme
5. HibikiCard 使用 tonal elevation 而非 border
6. 通过 flutter analyze (零错误)
7. 通过 flutter test (零回归)

## 需求评分

| 维度 | 得分 |
|------|------|
| 目标明确性 | 3/3 |
| 预期结果 | 2/3 |
| 边界范围 | 2/2 |
| 约束条件 | 1/2 |
| **总分** | **8/10** |
