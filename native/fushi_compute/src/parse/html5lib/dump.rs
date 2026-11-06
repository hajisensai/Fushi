//! 树转储（回归测试用）：一个节点一行，格式与生成期望值时 `package:html` 一侧的 Dart
//! 转储器逐字节相同。只在测试里编译，不是 C ABI 的一部分。

use std::fmt::Write as _;

use super::{AttrKey, Dom, NodeKind};

/// 逐 UTF-16 码元转义：可见 ASCII（空格、反斜杠除外）原样，其余 `\uXXXX`。
fn esc(s: &str, out: &mut String) {
    for u in s.encode_utf16() {
        if (0x21..0x7f).contains(&u) && u != u16::from(b'\\') {
            out.push(u as u8 as char);
        } else {
            let _ = write!(out, "\\u{u:04x}");
        }
    }
}

/// 一个节点一行：`<深度个空格><类型> ...`。
/// - `D`：Document；`!`：doctype（name / publicId / systemId，空为 `-`）
/// - `E <namespaceUri> <localName> [<键>=<值>]...`：`AttributeName` 键前加 `@`
/// - `T <文本>`、`C <注释>`
pub fn dump(dom: &Dom, out: &mut String) {
    let mut stack = vec![(0usize, 0usize)];
    while let Some((id, depth)) = stack.pop() {
        for _ in 0..depth {
            out.push(' ');
        }
        match &dom.nodes[id].kind {
            NodeKind::Document => out.push('D'),
            NodeKind::Doctype {
                name,
                public_id,
                system_id,
            } => {
                out.push_str("! ");
                esc(name, out);
                for v in [public_id, system_id] {
                    out.push(' ');
                    match v {
                        Some(v) => {
                            out.push('"');
                            esc(v, out);
                        }
                        None => out.push('-'),
                    }
                }
            }
            NodeKind::Comment(c) => {
                out.push_str("C ");
                esc(c, out);
            }
            NodeKind::Text(t) => {
                out.push_str("T ");
                esc(t, out);
            }
            NodeKind::Element { name, ns, attrs } => {
                out.push_str("E ");
                out.push_str(ns.uri());
                out.push(' ');
                esc(name, out);
                for (k, v) in &attrs.borrow().entries {
                    out.push(' ');
                    if !matches!(k, AttrKey::Plain(_)) {
                        out.push('@');
                    }
                    esc(&k.label(), out);
                    out.push('=');
                    esc(v, out);
                }
            }
        }
        out.push('\n');
        for &c in dom.nodes[id].children.iter().rev() {
            stack.push((c, depth + 1));
        }
    }
}
