#pragma once

#include <cstddef>
#include <string>
#include <vector>

// 查词游标扫描的候选前缀生成（词边界感知，对齐 Yomitan searchResolution）。
//
// 从 text 开头锚定，取前 min(scan_length, 长度) 个码点为最长窗口，逐步缩短，
// 产出「由长到短」的候选前缀串，供逐个做文本归一化 + 去屈折 + 精确查询。
//
// 关键规则：禁止把切点落在两个「空格分词类字母」之间（拉丁/西里尔/希腊/阿拉伯/
// 希伯来/亚美尼亚/格鲁吉亚），从而不会在单词中间切出无意义的词头片段；
// CJK 汉字/假名/谚文不属于该类 → 它们之间所有切点照旧合法（日语逐码点，零变化）。
// 以空白结尾的前缀属冗余（更短的去空白前缀已覆盖），一并丢弃。
std::vector<std::string> scan_candidates(const std::string& text, std::size_t scan_length);
