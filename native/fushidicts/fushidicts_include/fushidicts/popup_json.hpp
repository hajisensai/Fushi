#pragma once

#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "lookup.hpp"
#include "query.hpp"

// 变形名 / 语法说明的界面语言译文：英文原文 → 译文（Dart
// `TransformDescriptionCatalog` 的镜像，键就是 assets/transforms/<lang>.json 的原文）。
using PopupTranslations = std::unordered_map<std::string, std::string>;

struct PopupJsonOptions {
  // 词头（表记 + 有效读音）卡数上限（BUG-1472）。
  int max_terms = 100;
  // true = 旧口径：max_terms 数的是注释行（Android 系统划词弹窗的 JNI 路径一直这样，
  // 保持它的输出逐字节不变）。
  bool budget_counts_glossaries = false;
  // 被用户关掉的词典：释义不进卡、不建卡、不占预算。
  std::unordered_set<std::string> hidden;
  // 用户管理页的词典顺序；卡内释义按它稳定排序，不在表里的排最后（BUG-2579）。空 = 不排。
  std::vector<std::string> dictionary_order;
  // 变形标签译文；nullptr / 空表 = 原文（BUG-2038：只在显示边界翻译）。
  const PopupTranslations* translations = nullptr;
};

// app 内弹窗 / 浏览器扩展 / 无头服务端的弹窗 JSON（唯一实现，Dart 侧不再有镜像）。
std::string build_popup_json(const std::vector<LookupResult>& results,
                             const PopupJsonOptions& options);

// Android 系统划词弹窗（JNI nativeLookupJson）的旧口径：注释行预算、不过滤、不排序、
// 不翻译。等价于 options{max_terms, budget_counts_glossaries = true}。
std::string build_popup_json(const std::vector<LookupResult>& results,
                             int max_terms);

std::string build_styles_json(DictionaryQuery& query);
