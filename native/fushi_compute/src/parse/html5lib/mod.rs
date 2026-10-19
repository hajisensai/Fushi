//! `package:html` 0.15.6（html5lib 的 Dart 移植）解析器的逐行 Rust 移植。
//!
//! EPUB 章节的 DOM 派生量（纯文本 / ruby 读音轨 / 字数 / 锚点偏移 / 插图扫描……）必须与
//! 旧 Dart 实现**逐码元一致**，而旧实现的树来自 `package:html`：它停在旧版 WHATWG
//! 规范（没有 `<template>`、`<rb>` / `<rtc>` 不隐含结束、`<select>` 里 `<hr>` 被忽略……），
//! 与任何现行规范实现（html5ever 等）在畸形输入上都会分叉。所以这里不「实现规范」，
//! 而是把 `package:html` 的代码**原样**搬过来，连它的怪癖一起：
//!
//! - 输入流：`HtmlInputStream.reset`（CR / CRLF → LF；孤立代理已在 Dart 侧 UTF-8
//!   编码时变成 U+FFFD，与 reset 的替换结果相同）。
//! - tokenizer：`src/tokenizer.dart` 全部状态（含无分号 legacy 实体、数字字符引用替换表，
//!   数值超出 64 位时 `int.parse` 抛 `FormatException` → 整次解析失败）。
//! - tree builder：`src/treebuilder.dart` + `parser.dart` 全部 phase，含 adoption agency、
//!   foster parenting、Noah's Ark、外来内容的标签名 / 属性名调整（调整过的属性被挪到属性表
//!   末尾）、`LinkedHashMap` 的属性顺序与重复属性（先到者赢）。
//! - DOM 语义：`dom.dart` 的 `NodeList`——`Node.remove()` 只把节点从父列表摘掉、**不清**
//!   `parentNode`（之后 foster parenting / adoption agency 会读到这个陈旧指针）；
//!   `insert` 先算下标、再把节点从旧父摘下、再按旧下标插入。
//! - Dart 侧会抛异常的地方（`StateError` / `RangeError` / 类型转换失败 / `int.parse`
//!   溢出）一律返回 [ParseFailure]，调用方按「解析抛异常」处理。
//!
//! 不移植：span / 错误列表（解析错误对树没有影响）、编码探测（输入已是字符串）、
//! fragment 解析（`parse()` 只走 document 解析）、`assert`（AOT / release 下不执行）。
//!
//! ---------------------------------------------------------------------------
//! 移植自 package:html 0.15.6（https://pub.dev/packages/html），原许可如下：
//!
//! Copyright (c) 2006-2012 The Authors
//!
//! Contributors:
//! James Graham, Anne van Kesteren, Lachlan Hunt, Matt McDonald, Sam Ruby,
//! Ian Hickson (Google), Thomas Broyer, Jacques Distler, Henri Sivonen,
//! Adam Barth, Eric Seidel, The Mozilla Foundation (contributions from Henri
//! Sivonen since 2008), David Flanagan (Mozilla),
//! Google LLC (contributed the Dart port) - misc@dartlang.org
//!
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to
//! deal in the Software without restriction, including without limitation the
//! rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
//! sell copies of the Software, and to permit persons to whom the Software is
//! furnished to do so, subject to the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in
//! all copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//! FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
//! IN THE SOFTWARE.

mod dom;
#[cfg(test)]
mod dump;
mod entities;
mod parser;
#[cfg(test)]
mod tests;
mod tokenizer;

pub use dom::{AttrKey, Dom, NodeKind, Ns};
#[cfg(test)]
use dump::dump;

/// 解析失败：对应 Dart 侧 `parse()` 抛出的异常（消息只作诊断，不参与结果）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseFailure(pub &'static str);

pub(crate) type Res<T> = Result<T, ParseFailure>;

/// `package:html` 的 `parse(input)`：document 解析，返回整棵树（下标 0 为 Document）。
pub fn parse_document(input: &str) -> Result<Dom, ParseFailure> {
    parser::Parser::new(input).parse()
}
