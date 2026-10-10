#pragma once

#include <cstddef>
#include <functional>
#include <string>
#include <vector>

// BUG-3261：汉字 + 假名混写的查询串（「棚にあげる」「目をつける」「手をやいた」）。
//
// 词典索引只有两种键：完整表记（棚に上げる）与完整读音（たなにあげる）。真实文本里
// 惯用句 / 复合词常把一部分汉字写成假名，混写串两种键都对不上，引擎只剩「棚」这种
// 单字命中——用户看到的就是「惯用句查不出来」。
//
// 这里补一条读音通路：把查询串里每段汉字换成它单独查得到的读音，拼出候选**完整读音**
// 去查读音索引；查回来的词条再用 [matches_mixed_orthography] 逐字核对，只有「词头的
// 每个汉字要么原样出现、要么被写成它在该词读音里对应的假名」才算命中。查询串里的
// 汉字必须原样出现在词头里，所以「日が」不会命中「僻（ひが）」。
namespace mixed_orthography {

// 候选读音的生成上限：汉字段数（超出即放弃本串）、每段读音数、组合总数（段数多时
// 每段按常用度截取更少的读音，保证组合不超过上限）。混写惯用句通常只有一两段汉字；
// 上限防的是长串组合爆炸拖慢弹窗。
inline constexpr std::size_t kMaxKanjiRuns = 3;
inline constexpr std::size_t kMaxReadingsPerRun = 16;
inline constexpr std::size_t kMaxCandidates = 64;

// 串里同时有汉字和假名时为 true——只有这种串才走混写通路（纯假名已由读音索引覆盖，
// 纯汉字没有可替换的假名）。
bool is_mixed(const std::string& text);

// 由 [run_readings] 给出每段汉字的读音（常用在前），拼出候选完整读音（平假名，去重，
// 不含与原串相同的串）。任一段没有读音、或汉字段超过 kMaxKanjiRuns 时返回空。
std::vector<std::string> reading_candidates(
    const std::string& text, const std::function<std::vector<std::string>(const std::string&)>& run_readings);

// [query] 是否是词条（[expression]，[reading]）的一种混写：词头的假名逐字与查询一致，
// 每个汉字要么原样出现在查询里、要么被写成读音里与它对应的一段假名。假名比较不分
// 平假名 / 片假名。[reading] 为空时不成立。
bool matches_mixed_orthography(const std::string& query, const std::string& expression,
                               const std::string& reading);

// 读音里的片假名转平假名；其余字符原样。
std::string to_hiragana(const std::string& text);

}  // namespace mixed_orthography
