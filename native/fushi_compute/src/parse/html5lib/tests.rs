//! 回归测试：期望值全部由旧 `package:html` 0.15.6 生成（一次性 Dart 脚本：同一个 xorshift
//! 生成器 + 同一转储格式 → FNV-1a 64 摘要；代表样例为完整转储）。不提交大语料。

use super::{dump, parse_document};

const PIECES: &[&str] = &[
    "<p>",
    "</p>",
    "<div>",
    "</div>",
    "<span id=a>",
    "</span>",
    "<b>",
    "</b>",
    "<i>",
    "</i>",
    "<a href=x>",
    "</a>",
    "<ruby>",
    "</ruby>",
    "<rb>",
    "<rt>",
    "</rt>",
    "<rp>",
    "<rtc>",
    "</rtc>",
    "<table>",
    "</table>",
    "<tr>",
    "<td>",
    "</td>",
    "<th>",
    "<tbody>",
    "<caption>",
    "<colgroup>",
    "<col>",
    "<select>",
    "<option>",
    "<optgroup>",
    "</select>",
    "<hr>",
    "<br>",
    "</br>",
    "<img src=p.png>",
    "<svg>",
    "</svg>",
    "<image xlink:href=a.jpg href=b.jpg/>",
    "<foreignObject>",
    "<desc>",
    "<g>",
    "<math>",
    "<mi>",
    "</math>",
    "<annotation-xml encoding=text/html>",
    "<template>",
    "</template>",
    "<head>",
    "<body>",
    "</body>",
    "<html lang=ja>",
    "<frameset>",
    "<frame>",
    "<noscript>",
    "</noscript>",
    "<title>",
    "</title>",
    "<style>",
    "</style>",
    "<script>",
    "</script>",
    "<textarea>",
    "</textarea>",
    "<pre>",
    "\n",
    " ",
    "\u{9}",
    "\u{d}\n",
    "\u{3000}",
    "\u{6f22}\u{5b57}",
    "\u{304b}\u{306a}",
    "\u{300c}\u{53f0}\u{8a5e}\u{300d}",
    "abc",
    "&amp;",
    "&amp",
    "&notit;",
    "&copy",
    "&#x3042;",
    "&#0;",
    "&#128;",
    "&#13;",
    "&lt",
    "\u{0}",
    "<!-- c -->",
    "<!--",
    "-->",
    "<![CDATA[x]]>",
    "<!DOCTYPE html>",
    "<li>",
    "<dd>",
    "<dt>",
    "<ul>",
    "<h1>",
    "<h2>",
    "</h1>",
    "<form>",
    "</form>",
    "<button>",
    "<nobr>",
    "<font color=red>",
    "<plaintext>",
    "<xmp>",
    "<isindex>",
    "<p id=a id=b>",
    "<svg viewbox=0>",
    "<math definitionurl=u>",
    "<",
    "&",
    "</",
    "<?x?>",
    "\u{2000b}",
];

struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Rng {
        Rng(seed.wrapping_mul(2654435761).wrapping_add(1))
    }

    fn next(&mut self, n: usize) -> usize {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        ((self.0 >> 1) % n as u64) as usize
    }
}

fn soup(r: &mut Rng) -> String {
    let len = 1 + r.next(40);
    let mut s = String::new();
    for _ in 0..len {
        s.push_str(PIECES[r.next(PIECES.len())]);
    }
    s
}

fn fnv(bytes: &[u8], mut h: u64) -> u64 {
    for &b in bytes {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

fn dump_of(html: &str) -> String {
    let mut out = String::new();
    dump(&parse_document(html).expect("parse"), &mut out);
    out
}

#[test]
fn fixed_seed_corpora_match_package_html() {
    let expected: &[(u64, i64)] = &[
        (1, -1351400450361808860),
        (2, -5466771829309998937),
        (3, 5186602085700291816),
        (4, -2934442056473566283),
        (5, -1651584012162913748),
    ];
    for &(seed, want) in expected {
        let mut r = Rng::new(seed);
        let mut h: u64 = 0xcbf29ce484222325;
        for _ in 0..3000 {
            h = fnv(dump_of(&soup(&mut r)).as_bytes(), h);
        }
        assert_eq!(h as i64, want, "seed {seed}");
    }
}

#[test]
fn representative_samples_match_package_html() {
    let cases: &[(&str, &str)] = &[
        (
            "<head><template><title>t</title></template></head><body>x",
            "D\n E http://www.w3.org/1999/xhtml html\n  E http://www.w3.org/1999/xhtml head\n  E http://www.w3.org/1999/xhtml body\n   E http://www.w3.org/1999/xhtml template\n    E http://www.w3.org/1999/xhtml title\n     T t\n   T x\n",
        ),
        (
            "<ruby>\u{6f22}<rb>\u{304b}</rb><rb>\u{3093}<rt>x</rt><rtc>y<rt>z</rtc>w</ruby>",
            "D\n E http://www.w3.org/1999/xhtml html\n  E http://www.w3.org/1999/xhtml head\n  E http://www.w3.org/1999/xhtml body\n   E http://www.w3.org/1999/xhtml ruby\n    T \\u6f22\n    E http://www.w3.org/1999/xhtml rb\n     T \\u304b\n    E http://www.w3.org/1999/xhtml rb\n     T \\u3093\n     E http://www.w3.org/1999/xhtml rt\n      T x\n     E http://www.w3.org/1999/xhtml rtc\n      T y\n      E http://www.w3.org/1999/xhtml rt\n       T z\n     T w\n",
        ),
        (
            "<select><option>a<hr><option>b</select>",
            "D\n E http://www.w3.org/1999/xhtml html\n  E http://www.w3.org/1999/xhtml head\n  E http://www.w3.org/1999/xhtml body\n   E http://www.w3.org/1999/xhtml select\n    E http://www.w3.org/1999/xhtml option\n     T a\n    E http://www.w3.org/1999/xhtml option\n     T b\n",
        ),
        (
            "<p>a</br>b</p><svg><noscript>x</noscript><p>y</p></svg>",
            "D\n E http://www.w3.org/1999/xhtml html\n  E http://www.w3.org/1999/xhtml head\n  E http://www.w3.org/1999/xhtml body\n   E http://www.w3.org/1999/xhtml p\n    T a\n    E http://www.w3.org/1999/xhtml br\n    T b\n   E http://www.w3.org/2000/svg svg\n    E http://www.w3.org/2000/svg noscript\n     T x\n   E http://www.w3.org/1999/xhtml p\n    T y\n",
        ),
        (
            "<b><i><u>abc</b>def</i>ghi</u><table><b><tr><td>aaa</td></tr>bbb</table>ccc",
            "D\n E http://www.w3.org/1999/xhtml html\n  E http://www.w3.org/1999/xhtml head\n  E http://www.w3.org/1999/xhtml body\n   E http://www.w3.org/1999/xhtml b\n    E http://www.w3.org/1999/xhtml i\n     E http://www.w3.org/1999/xhtml u\n      T abc\n   E http://www.w3.org/1999/xhtml i\n    E http://www.w3.org/1999/xhtml u\n     T def\n   E http://www.w3.org/1999/xhtml u\n    T ghi\n   E http://www.w3.org/1999/xhtml b\n   E http://www.w3.org/1999/xhtml b\n    T bbb\n   E http://www.w3.org/1999/xhtml table\n    E http://www.w3.org/1999/xhtml tbody\n     E http://www.w3.org/1999/xhtml tr\n      E http://www.w3.org/1999/xhtml td\n       T aaa\n   E http://www.w3.org/1999/xhtml b\n    T ccc\n",
        ),
        (
            "<svg viewbox=\"0 0 1 1\" xlink:href=a id=i><image xlink:href=\"a.jpg\" href=\"b.jpg\"/></svg>&notit; &copy &#128;",
            "D\n E http://www.w3.org/1999/xhtml html\n  E http://www.w3.org/1999/xhtml head\n  E http://www.w3.org/1999/xhtml body\n   E http://www.w3.org/2000/svg svg id=i viewBox=0\\u00200\\u00201\\u00201 @xlink:href=a\n    E http://www.w3.org/2000/svg image href=b.jpg @xlink:href=a.jpg\n   T \\u00acit;\\u0020\\u00a9\\u0020\\u20ac\n",
        ),
    ];
    for &(src, want) in cases {
        assert_eq!(dump_of(src), want, "{src}");
    }
}

#[test]
fn numeric_reference_overflow_fails_like_int_parse() {
    // Dart `int.parse` 超出 64 位抛 FormatException，整个 parse() 失败。
    assert!(parse_document("<p>&#99999999999999999999;</p>").is_err());
    assert!(parse_document("<p>&#x8000000000000000;</p>").is_err());
    assert!(parse_document("<p title='&#99999999999999999999;'>x</p>").is_err());
    assert!(parse_document("<p>&#9223372036854775807;</p>").is_ok());
    assert!(parse_document("<p>&#x7FFFFFFFFFFFFFFF;</p>").is_ok());
}

#[test]
fn input_stream_normalizes_newlines_and_keeps_bom() {
    let d = dump_of("\u{feff}a\rb\r\nc\r\rd");
    assert!(
        d.contains("T \\ufeffa\\u000ab\\u000ac\\u000a\\u000ad\n"),
        "{d}"
    );
}
