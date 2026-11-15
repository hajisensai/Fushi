//! 艺人署名拆分：标签里常把多位艺人写进一个字段（`藤澤慶昌&加藤達也`、
//! `平沢 唯(CV:豊崎愛生)、平沢 憂(CV:米澤 円)`），入库时拆成一人一个署名（一人一个
//! `artist_uid`），否则同一个人随拼法不同散成艺人列表里一堆条目。
//!
//! 分隔符与 Dart 侧比对规则 `packages/fushi_engine/lib/media/music/metadata/music_metadata_text.dart`
//! 的 `_artistSeparators` 同一张表：`,` `、` `，` `/` `／` `;` `；` `&` `＆` `×` 与
//! `x` / `feat` / `feat.` / `ft` / `ft.` / `with` / `vs` / `vs.`（不分大小写）。入库是显示用的
//! 名字，比对规则只管判同，两处多两条护栏：
//! - 括号里的不拆（`ノア(CV:A&B)` 是一个署名，声优注记属于前面的角色名）；
//! - 关键词分隔只认「前后都是空白」的独立词（`.` 结尾的缩写可直接接名字：`A feat.B`），
//!   且两侧都得有名字（`X JAPAN` 的 `X` 不是分隔符）。
//!
//! 已知取舍：名字本身带分隔符的组合（`Earth, Wind & Fire`、`AC/DC`）会被拆开；
//! `.` 不是分隔符（`Mr.Children` 要保住），`藤澤慶昌.加藤達也` 这类写法不拆。

const OPEN: &[char] = &['(', '（', '[', '［', '【', '〔', '〈', '《', '「', '『'];
const CLOSE: &[char] = &[')', '）', ']', '］', '】', '〕', '〉', '》', '」', '』'];
const PUNCT: &[char] = &[',', '、', '，', '/', '／', ';', '；', '&', '＆', '×'];
/// （关键词, 可否以 `.` 收尾）。
const KEYWORDS: &[(&str, bool)] = &[
    ("feat", true),
    ("ft", true),
    ("with", false),
    ("vs", true),
    ("x", false),
];

/// 从 `chars[i]` 起匹配一个关键词分隔符，返回分隔符之后的下标。
fn keyword_at(chars: &[char], i: usize) -> Option<usize> {
    for &(word, dotted) in KEYWORDS {
        let n = word.len();
        if i + n > chars.len() {
            continue;
        }
        let hit = chars[i..i + n]
            .iter()
            .zip(word.chars())
            .all(|(c, w)| c.to_ascii_lowercase() == w);
        if !hit {
            continue;
        }
        let j = i + n;
        if dotted && chars.get(j) == Some(&'.') {
            return Some(j + 1);
        }
        if chars.get(j).is_some_and(|c| c.is_whitespace()) {
            return Some(j);
        }
    }
    None
}

/// 把一个署名字段拆成单个艺人名（去首尾空白、去空、按出现顺序去重）。没有可拆的
/// 分隔符时返回整串（去空白后）；全空返回空表。
pub fn split_artist_credit(credit: &str) -> Vec<String> {
    let chars: Vec<char> = credit.chars().collect();
    let mut parts: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut depth = 0usize;
    let mut i = 0usize;
    while i < chars.len() {
        let c = chars[i];
        if OPEN.contains(&c) {
            depth += 1;
        } else if CLOSE.contains(&c) {
            depth = depth.saturating_sub(1);
        } else if depth == 0 {
            if PUNCT.contains(&c) {
                parts.push(std::mem::take(&mut cur));
                i += 1;
                continue;
            }
            let after_space = i > 0 && chars[i - 1].is_whitespace();
            if after_space && !cur.trim().is_empty() {
                if let Some(j) = keyword_at(&chars, i) {
                    let rest_has_name = chars[j..]
                        .iter()
                        .take_while(|c| !PUNCT.contains(c))
                        .any(|c| !c.is_whitespace());
                    if rest_has_name {
                        parts.push(std::mem::take(&mut cur));
                        i = j;
                        continue;
                    }
                }
            }
        }
        cur.push(c);
        i += 1;
    }
    parts.push(cur);
    let mut out: Vec<String> = Vec::new();
    for p in parts {
        let t = p.trim();
        if !t.is_empty() && !out.iter().any(|o| o == t) {
            out.push(t.to_owned());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::split_artist_credit as split;

    fn v(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn splits_feedback_variants_into_the_same_people() {
        // BUG-4493 反馈截图里的同一组人，三种拼法拆出同一组名字。
        let want = v(&["藤澤慶昌", "加藤達也"]);
        assert_eq!(split("藤澤慶昌&加藤達也"), want);
        assert_eq!(split("藤澤慶昌/加藤達也"), want);
        assert_eq!(split("藤澤慶昌 ／ 加藤達也"), want);
        assert_eq!(split("藤澤慶昌、加藤達也"), want);
        assert_eq!(
            split("花柳香子(CV:伊藤彩沙)、石動双葉(CV:生田輝)"),
            v(&["花柳香子(CV:伊藤彩沙)", "石動双葉(CV:生田輝)"])
        );
    }

    #[test]
    fn same_separator_table_as_dart() {
        for sep in [",", "、", "，", "/", "／", ";", "；", "&", "＆", "×"] {
            assert_eq!(split(&format!("A{sep}B")), v(&["A", "B"]), "{sep}");
        }
        for sep in [
            " feat. ", " feat ", " Feat.", " ft. ", " FT ", " with ", " vs ", " vs.", " x ", " X ",
        ] {
            assert_eq!(
                split(&format!("Aimer{sep}Bee")),
                v(&["Aimer", "Bee"]),
                "{sep:?}"
            );
        }
    }

    #[test]
    fn brackets_and_keywords_inside_names_stay_whole() {
        assert_eq!(
            split("ノア(CV:鈴代紗弓&小原好美)"),
            v(&["ノア(CV:鈴代紗弓&小原好美)"])
        );
        assert_eq!(split("【A/B】"), v(&["【A/B】"]));
        assert_eq!(split("X JAPAN"), v(&["X JAPAN"]));
        assert_eq!(split("Feather"), v(&["Feather"]));
        assert_eq!(split("Kid Within"), v(&["Kid Within"]));
        assert_eq!(split("AxB"), v(&["AxB"]));
        assert_eq!(split("Mr.Children"), v(&["Mr.Children"]));
        assert_eq!(split("Band with"), v(&["Band with"]));
        assert_eq!(split("  YOASOBI  "), v(&["YOASOBI"]));
    }

    #[test]
    fn drops_empties_and_duplicates() {
        assert_eq!(split("A, , A & B"), v(&["A", "B"]));
        assert!(split(" / ").is_empty());
        assert!(split("").is_empty());
    }
}
