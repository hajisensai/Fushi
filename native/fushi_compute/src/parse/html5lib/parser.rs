//! `src/treebuilder.dart` + `parser.dart`（`HtmlParser` 与全部 phase）。
//!
//! 结构对照：每个 Dart phase 的 `processX` 方法对应这里 `process_x(phase, ..)` 里的一个
//! 分支；返回 `true` 表示 Dart 版返回了 token（主循环用同一个 token 重新处理），`false`
//! 表示返回 `null`。Dart 里 `parser._inBodyPhase.processStartTag(token)` 这类「借用别的
//! phase」的调用写成 `self.process_start_tag(Phase::InBody, t)`；`parser.phase.processX`
//! （当前 phase）写成 `self.process_x(self.phase, ..)`——两者在 Dart 里语义不同，不能混。

use std::cell::RefCell;
use std::rc::Rc;

use super::dom::{AttrKey, AttrMap, Dom, NodeId, NodeKind, Ns};
use super::tokenizer::{ascii_lower, Doctype, StartTag, State, Token, Tokenizer};
use super::{ParseFailure, Res};
use crate::parse::dart_lower::dart_lower_str;

fn state_error() -> ParseFailure {
    ParseFailure("StateError")
}

fn range_error() -> ParseFailure {
    ParseFailure("RangeError")
}

// ---------------------------------------------------------------------------
// constants.dart
// ---------------------------------------------------------------------------

const HTML: Ns = Ns::Html;
const MATHML: Ns = Ns::MathMl;
const SVG: Ns = Ns::Svg;

const SCOPING_ELEMENTS: &[(Ns, &str)] = &[
    (HTML, "applet"),
    (HTML, "caption"),
    (HTML, "html"),
    (HTML, "marquee"),
    (HTML, "object"),
    (HTML, "table"),
    (HTML, "td"),
    (HTML, "th"),
    (MATHML, "mi"),
    (MATHML, "mo"),
    (MATHML, "mn"),
    (MATHML, "ms"),
    (MATHML, "mtext"),
    (MATHML, "annotation-xml"),
    (SVG, "foreignObject"),
    (SVG, "desc"),
    (SVG, "title"),
];

const SPECIAL_ELEMENTS: &[(Ns, &str)] = &[
    (HTML, "address"),
    (HTML, "applet"),
    (HTML, "area"),
    (HTML, "article"),
    (HTML, "aside"),
    (HTML, "base"),
    (HTML, "basefont"),
    (HTML, "bgsound"),
    (HTML, "blockquote"),
    (HTML, "body"),
    (HTML, "br"),
    (HTML, "button"),
    (HTML, "caption"),
    (HTML, "center"),
    (HTML, "col"),
    (HTML, "colgroup"),
    (HTML, "command"),
    (HTML, "dd"),
    (HTML, "details"),
    (HTML, "dir"),
    (HTML, "div"),
    (HTML, "dl"),
    (HTML, "dt"),
    (HTML, "embed"),
    (HTML, "fieldset"),
    (HTML, "figure"),
    (HTML, "footer"),
    (HTML, "form"),
    (HTML, "frame"),
    (HTML, "frameset"),
    (HTML, "h1"),
    (HTML, "h2"),
    (HTML, "h3"),
    (HTML, "h4"),
    (HTML, "h5"),
    (HTML, "h6"),
    (HTML, "head"),
    (HTML, "header"),
    (HTML, "hr"),
    (HTML, "html"),
    (HTML, "iframe"),
    (HTML, "image"),
    (HTML, "img"),
    (HTML, "input"),
    (HTML, "isindex"),
    (HTML, "li"),
    (HTML, "link"),
    (HTML, "listing"),
    (HTML, "marquee"),
    (HTML, "men"),
    (HTML, "meta"),
    (HTML, "nav"),
    (HTML, "noembed"),
    (HTML, "noframes"),
    (HTML, "noscript"),
    (HTML, "object"),
    (HTML, "ol"),
    (HTML, "p"),
    (HTML, "param"),
    (HTML, "plaintext"),
    (HTML, "pre"),
    (HTML, "script"),
    (HTML, "section"),
    (HTML, "select"),
    (HTML, "style"),
    (HTML, "table"),
    (HTML, "tbody"),
    (HTML, "td"),
    (HTML, "textarea"),
    (HTML, "tfoot"),
    (HTML, "th"),
    (HTML, "thead"),
    (HTML, "title"),
    (HTML, "tr"),
    (HTML, "ul"),
    (HTML, "wbr"),
    (HTML, "xmp"),
    (SVG, "foreignObject"),
];

/// 原文拼写错误 `annotaion-xml` 照抄（所以 MathML `annotation-xml` 只靠 encoding 属性判定）。
const HTML_INTEGRATION_POINT_ELEMENTS: &[(Ns, &str)] = &[
    (MATHML, "annotaion-xml"),
    (SVG, "foreignObject"),
    (SVG, "desc"),
    (SVG, "title"),
];

const MATHML_TEXT_INTEGRATION_POINT_ELEMENTS: &[(Ns, &str)] = &[
    (MATHML, "mi"),
    (MATHML, "mo"),
    (MATHML, "mn"),
    (MATHML, "ms"),
    (MATHML, "mtext"),
];

const TABLE_INSERT_MODE_ELEMENTS: &[&str] = &["table", "tbody", "tfoot", "thead", "tr"];

const HEADING_ELEMENTS: &[&str] = &["h1", "h2", "h3", "h4", "h5", "h6"];

const BREAKOUT_ELEMENTS: &[&str] = &[
    "b",
    "big",
    "blockquote",
    "body",
    "br",
    "center",
    "code",
    "dd",
    "div",
    "dl",
    "dt",
    "em",
    "embed",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "head",
    "hr",
    "i",
    "img",
    "li",
    "listing",
    "menu",
    "meta",
    "nobr",
    "ol",
    "p",
    "pre",
    "ruby",
    "s",
    "small",
    "span",
    "strike",
    "strong",
    "sub",
    "sup",
    "table",
    "tt",
    "u",
    "ul",
    "var",
];

const SVG_ATTRIBUTE_REPLACEMENTS: &[(&str, &str)] = &[
    ("attributename", "attributeName"),
    ("attributetype", "attributeType"),
    ("basefrequency", "baseFrequency"),
    ("baseprofile", "baseProfile"),
    ("calcmode", "calcMode"),
    ("clippathunits", "clipPathUnits"),
    ("contentscripttype", "contentScriptType"),
    ("contentstyletype", "contentStyleType"),
    ("diffuseconstant", "diffuseConstant"),
    ("edgemode", "edgeMode"),
    ("externalresourcesrequired", "externalResourcesRequired"),
    ("filterres", "filterRes"),
    ("filterunits", "filterUnits"),
    ("glyphref", "glyphRef"),
    ("gradienttransform", "gradientTransform"),
    ("gradientunits", "gradientUnits"),
    ("kernelmatrix", "kernelMatrix"),
    ("kernelunitlength", "kernelUnitLength"),
    ("keypoints", "keyPoints"),
    ("keysplines", "keySplines"),
    ("keytimes", "keyTimes"),
    ("lengthadjust", "lengthAdjust"),
    ("limitingconeangle", "limitingConeAngle"),
    ("markerheight", "markerHeight"),
    ("markerunits", "markerUnits"),
    ("markerwidth", "markerWidth"),
    ("maskcontentunits", "maskContentUnits"),
    ("maskunits", "maskUnits"),
    ("numoctaves", "numOctaves"),
    ("pathlength", "pathLength"),
    ("patterncontentunits", "patternContentUnits"),
    ("patterntransform", "patternTransform"),
    ("patternunits", "patternUnits"),
    ("pointsatx", "pointsAtX"),
    ("pointsaty", "pointsAtY"),
    ("pointsatz", "pointsAtZ"),
    ("preservealpha", "preserveAlpha"),
    ("preserveaspectratio", "preserveAspectRatio"),
    ("primitiveunits", "primitiveUnits"),
    ("refx", "refX"),
    ("refy", "refY"),
    ("repeatcount", "repeatCount"),
    ("repeatdur", "repeatDur"),
    ("requiredextensions", "requiredExtensions"),
    ("requiredfeatures", "requiredFeatures"),
    ("specularconstant", "specularConstant"),
    ("specularexponent", "specularExponent"),
    ("spreadmethod", "spreadMethod"),
    ("startoffset", "startOffset"),
    ("stddeviation", "stdDeviation"),
    ("stitchtiles", "stitchTiles"),
    ("surfacescale", "surfaceScale"),
    ("systemlanguage", "systemLanguage"),
    ("tablevalues", "tableValues"),
    ("targetx", "targetX"),
    ("targety", "targetY"),
    ("textlength", "textLength"),
    ("viewbox", "viewBox"),
    ("viewtarget", "viewTarget"),
    ("xchannelselector", "xChannelSelector"),
    ("ychannelselector", "yChannelSelector"),
    ("zoomandpan", "zoomAndPan"),
];

const XLINK: &str = "http://www.w3.org/1999/xlink";
const XML: &str = "http://www.w3.org/XML/1998/namespace";
const XMLNS: &str = "http://www.w3.org/2000/xmlns/";

/// `adjustForeignAttributes` 的替换表：（原名，prefix，name，namespace）。
const FOREIGN_ATTRIBUTE_REPLACEMENTS: &[(&str, Option<&str>, &str, &str)] = &[
    ("xlink:actuate", Some("xlink"), "actuate", XLINK),
    ("xlink:arcrole", Some("xlink"), "arcrole", XLINK),
    ("xlink:href", Some("xlink"), "href", XLINK),
    ("xlink:role", Some("xlink"), "role", XLINK),
    ("xlink:show", Some("xlink"), "show", XLINK),
    ("xlink:title", Some("xlink"), "title", XLINK),
    ("xlink:type", Some("xlink"), "type", XLINK),
    ("xml:base", Some("xml"), "base", XML),
    ("xml:lang", Some("xml"), "lang", XML),
    ("xml:space", Some("xml"), "space", XML),
    ("xmlns", None, "xmlns", XMLNS),
    ("xmlns:xlink", Some("xmlns"), "xlink", XMLNS),
];

const SVG_TAG_REPLACEMENTS: &[(&str, &str)] = &[
    ("altglyph", "altGlyph"),
    ("altglyphdef", "altGlyphDef"),
    ("altglyphitem", "altGlyphItem"),
    ("animatecolor", "animateColor"),
    ("animatemotion", "animateMotion"),
    ("animatetransform", "animateTransform"),
    ("clippath", "clipPath"),
    ("feblend", "feBlend"),
    ("fecolormatrix", "feColorMatrix"),
    ("fecomponenttransfer", "feComponentTransfer"),
    ("fecomposite", "feComposite"),
    ("feconvolvematrix", "feConvolveMatrix"),
    ("fediffuselighting", "feDiffuseLighting"),
    ("fedisplacementmap", "feDisplacementMap"),
    ("fedistantlight", "feDistantLight"),
    ("feflood", "feFlood"),
    ("fefunca", "feFuncA"),
    ("fefuncb", "feFuncB"),
    ("fefuncg", "feFuncG"),
    ("fefuncr", "feFuncR"),
    ("fegaussianblur", "feGaussianBlur"),
    ("feimage", "feImage"),
    ("femerge", "feMerge"),
    ("femergenode", "feMergeNode"),
    ("femorphology", "feMorphology"),
    ("feoffset", "feOffset"),
    ("fepointlight", "fePointLight"),
    ("fespecularlighting", "feSpecularLighting"),
    ("fespotlight", "feSpotLight"),
    ("fetile", "feTile"),
    ("feturbulence", "feTurbulence"),
    ("foreignobject", "foreignObject"),
    ("glyphref", "glyphRef"),
    ("lineargradient", "linearGradient"),
    ("radialgradient", "radialGradient"),
    ("textpath", "textPath"),
];

const QUIRKS_PUBLIC_PREFIXES: &[&str] = &[
    "+//silmaril//dtd html pro v0r11 19970101//",
    "-//advasoft ltd//dtd html 3.0 aswedit + extensions//",
    "-//as//dtd html 3.0 aswedit + extensions//",
    "-//ietf//dtd html 2.0 level 1//",
    "-//ietf//dtd html 2.0 level 2//",
    "-//ietf//dtd html 2.0 strict level 1//",
    "-//ietf//dtd html 2.0 strict level 2//",
    "-//ietf//dtd html 2.0 strict//",
    "-//ietf//dtd html 2.0//",
    "-//ietf//dtd html 2.1e//",
    "-//ietf//dtd html 3.0//",
    "-//ietf//dtd html 3.2 final//",
    "-//ietf//dtd html 3.2//",
    "-//ietf//dtd html 3//",
    "-//ietf//dtd html level 0//",
    "-//ietf//dtd html level 1//",
    "-//ietf//dtd html level 2//",
    "-//ietf//dtd html level 3//",
    "-//ietf//dtd html strict level 0//",
    "-//ietf//dtd html strict level 1//",
    "-//ietf//dtd html strict level 2//",
    "-//ietf//dtd html strict level 3//",
    "-//ietf//dtd html strict//",
    "-//ietf//dtd html//",
    "-//metrius//dtd metrius presentational//",
    "-//microsoft//dtd internet explorer 2.0 html strict//",
    "-//microsoft//dtd internet explorer 2.0 html//",
    "-//microsoft//dtd internet explorer 2.0 tables//",
    "-//microsoft//dtd internet explorer 3.0 html strict//",
    "-//microsoft//dtd internet explorer 3.0 html//",
    "-//microsoft//dtd internet explorer 3.0 tables//",
    "-//netscape comm. corp.//dtd html//",
    "-//netscape comm. corp.//dtd strict html//",
    "-//o'reilly and associates//dtd html 2.0//",
    "-//o'reilly and associates//dtd html extended 1.0//",
    "-//o'reilly and associates//dtd html extended relaxed 1.0//",
    "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
    "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//",
    "-//spyglass//dtd html 2.0 extended//",
    "-//sq//dtd html 2.0 hotmetal + extensions//",
    "-//sun microsystems corp.//dtd hotjava html//",
    "-//sun microsystems corp.//dtd hotjava strict html//",
    "-//w3c//dtd html 3 1995-03-24//",
    "-//w3c//dtd html 3.2 draft//",
    "-//w3c//dtd html 3.2 final//",
    "-//w3c//dtd html 3.2//",
    "-//w3c//dtd html 3.2s draft//",
    "-//w3c//dtd html 4.0 frameset//",
    "-//w3c//dtd html 4.0 transitional//",
    "-//w3c//dtd html experimental 19960712//",
    "-//w3c//dtd html experimental 970421//",
    "-//w3c//dtd w3 html//",
    "-//w3o//dtd w3 html 3.0//",
    "-//webtechs//dtd mozilla html 2.0//",
    "-//webtechs//dtd mozilla html//",
];

/// utils.dart `allWhitespace`。
fn all_whitespace(s: &str) -> bool {
    s.chars()
        .all(|c| matches!(c, '\t' | '\n' | '\x0C' | '\r' | ' '))
}

fn starts_with_any(s: &str, prefixes: &[&str]) -> bool {
    prefixes.iter().any(|p| s.starts_with(p))
}

// ---------------------------------------------------------------------------
// HtmlParser
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Phase {
    Initial,
    BeforeHtml,
    BeforeHead,
    InHead,
    AfterHead,
    InBody,
    Text,
    InTable,
    InTableText,
    InCaption,
    InColumnGroup,
    InTableBody,
    InRow,
    InCell,
    InSelect,
    InSelectInTable,
    InForeignContent,
    AfterBody,
    InFrameset,
    AfterFrameset,
    AfterAfterBody,
    AfterAfterFrameset,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Scope {
    Default,
    Button,
    List,
    Table,
    Select,
}

#[derive(Clone, Copy)]
enum Target<'a> {
    Name(&'a str),
    Node(NodeId),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CompatMode {
    NoQuirks,
    Quirks,
    LimitedQuirks,
}

pub struct Parser {
    tokenizer: Tokenizer,
    // TreeBuilder
    dom: Dom,
    open: Vec<NodeId>,
    afe: Vec<Option<NodeId>>,
    head_pointer: Option<NodeId>,
    form_pointer: Option<NodeId>,
    insert_from_table: bool,
    // HtmlParser
    first_start_tag: bool,
    compat_mode: CompatMode,
    phase: Phase,
    original_phase: Option<Phase>,
    frameset_ok: bool,
    // InBodyPhase.dropNewline
    drop_newline: bool,
    // InTableTextPhase
    table_text_original_phase: Option<Phase>,
    table_text_tokens: Vec<String>,
}

impl Parser {
    pub fn new(input: &str) -> Parser {
        Parser {
            tokenizer: Tokenizer::new(input),
            dom: Dom::new(),
            open: Vec::new(),
            afe: Vec::new(),
            head_pointer: None,
            form_pointer: None,
            insert_from_table: false,
            first_start_tag: false,
            compat_mode: CompatMode::NoQuirks,
            phase: Phase::Initial,
            original_phase: None,
            frameset_ok: true,
            drop_newline: false,
            table_text_original_phase: None,
            table_text_tokens: Vec::new(),
        }
    }

    pub fn parse(mut self) -> Res<Dom> {
        self.main_loop()?;
        Ok(self.dom)
    }

    // ---- small helpers -------------------------------------------------

    fn name(&self, id: NodeId) -> &str {
        self.dom.local_name(id)
    }

    fn tuple_in(&self, id: NodeId, set: &[(Ns, &str)]) -> bool {
        let ns = self.dom.ns(id);
        let name = self.dom.local_name(id);
        set.iter().any(|&(n, l)| n == ns && l == name)
    }

    fn is_special(&self, id: NodeId) -> bool {
        self.tuple_in(id, SPECIAL_ELEMENTS)
    }

    fn last_open(&self) -> Res<NodeId> {
        self.open.last().copied().ok_or_else(state_error)
    }

    fn last_name(&self) -> Res<&str> {
        Ok(self.name(self.last_open()?))
    }

    fn pop(&mut self) -> Res<NodeId> {
        self.open.pop().ok_or_else(range_error)
    }

    fn open_at(&self, i: isize) -> Res<NodeId> {
        if i < 0 {
            return Err(range_error());
        }
        self.open.get(i as usize).copied().ok_or_else(range_error)
    }

    fn open_index_of(&self, id: NodeId) -> isize {
        self.open
            .iter()
            .position(|&n| n == id)
            .map_or(-1, |i| i as isize)
    }

    fn open_contains(&self, id: NodeId) -> bool {
        self.open.contains(&id)
    }

    /// `openElements.remove(node)`：第一次出现。
    fn open_remove(&mut self, id: NodeId) {
        if let Some(i) = self.open.iter().position(|&n| n == id) {
            self.open.remove(i);
        }
    }

    fn afe_index_of(&self, id: NodeId) -> isize {
        self.afe
            .iter()
            .position(|&n| n == Some(id))
            .map_or(-1, |i| i as isize)
    }

    fn afe_remove(&mut self, id: NodeId) {
        if let Some(i) = self.afe.iter().position(|&n| n == Some(id)) {
            self.afe.remove(i);
        }
    }

    // ---- TreeBuilder ---------------------------------------------------

    #[allow(clippy::type_complexity)]
    fn element_in_scope(&self, target: Target, variant: Scope) -> Res<bool> {
        const BUTTON: &[(Ns, &str)] = &[(HTML, "button")];
        const LIST: &[(Ns, &str)] = &[(HTML, "ol"), (HTML, "ul")];
        const TABLE: &[(Ns, &str)] = &[(HTML, "html"), (HTML, "table")];
        const SELECT: &[(Ns, &str)] = &[(HTML, "optgroup"), (HTML, "option")];
        let (set1, set2, invert): (&[(Ns, &str)], &[(Ns, &str)], bool) = match variant {
            Scope::Default => (SCOPING_ELEMENTS, &[], false),
            Scope::Button => (SCOPING_ELEMENTS, BUTTON, false),
            Scope::List => (SCOPING_ELEMENTS, LIST, false),
            Scope::Table => (TABLE, &[], false),
            Scope::Select => (SELECT, &[], true),
        };
        for &node in self.open.iter().rev() {
            let hit = match target {
                Target::Name(n) => self.name(node) == n,
                Target::Node(t) => node == t,
            };
            if hit {
                return Ok(true);
            } else if invert != (self.tuple_in(node, set1) || self.tuple_in(node, set2)) {
                return Ok(false);
            }
        }
        Err(state_error())
    }

    fn in_scope(&self, name: &str) -> Res<bool> {
        self.element_in_scope(Target::Name(name), Scope::Default)
    }

    fn in_scope_v(&self, name: &str, variant: Scope) -> Res<bool> {
        self.element_in_scope(Target::Name(name), variant)
    }

    fn nodes_equal(&self, a: NodeId, b: NodeId) -> bool {
        self.dom.ns(a) == self.dom.ns(b)
            && self.name(a) == self.name(b)
            && self
                .dom
                .attrs(a)
                .borrow()
                .equals(&self.dom.attrs(b).borrow())
    }

    /// `ActiveFormattingElements.add`（Noah's Ark：标记后第 3 个同样的元素把最早那个挤掉）。
    fn afe_add(&mut self, node: Option<NodeId>) {
        if let Some(n) = node {
            let mut equal_count = 0;
            let mut victim = None;
            for &e in self.afe.iter().rev() {
                let Some(e) = e else { break };
                if self.nodes_equal(e, n) {
                    equal_count += 1;
                }
                if equal_count == 3 {
                    victim = Some(e);
                    break;
                }
            }
            if let Some(v) = victim {
                self.afe_remove(v);
            }
        }
        self.afe.push(node);
    }

    fn reconstruct_active_formatting_elements(&mut self) -> Res<()> {
        if self.afe.is_empty() {
            return Ok(());
        }
        let mut i = self.afe.len() as isize - 1;
        let mut entry = self.afe[i as usize];
        match entry {
            None => return Ok(()),
            Some(e) if self.open_contains(e) => return Ok(()),
            _ => {}
        }
        while let Some(e) = entry {
            if self.open_contains(e) {
                break;
            }
            if i == 0 {
                i = -1;
                break;
            }
            i -= 1;
            entry = self.afe[i as usize];
        }
        loop {
            i += 1;
            let e = self
                .afe
                .get(i as usize)
                .copied()
                .flatten()
                .ok_or(ParseFailure("TypeError: null entry"))?;
            let attrs = Rc::new(RefCell::new(self.dom.attrs(e).borrow().clone()));
            let mut clone_token = StartTag::with_data(self.name(e), attrs);
            clone_token.namespace = Some(self.dom.ns(e));
            let element = self.insert_element(&clone_token)?;
            self.afe[i as usize] = Some(element);
            if self.afe.last() == Some(&Some(element)) {
                break;
            }
        }
        Ok(())
    }

    fn clear_active_formatting_elements(&mut self) -> Res<()> {
        let mut entry = self.afe.pop().ok_or_else(state_error)?;
        while !self.afe.is_empty() && entry.is_some() {
            entry = self.afe.pop().unwrap();
        }
        Ok(())
    }

    fn element_in_active_formatting_elements(&self, name: &str) -> Option<NodeId> {
        for &item in self.afe.iter().rev() {
            match item {
                None => break,
                Some(e) if self.name(e) == name => return Some(e),
                _ => {}
            }
        }
        None
    }

    fn create_element(&mut self, token: &StartTag) -> NodeId {
        let ns = token.namespace.unwrap_or(HTML);
        self.dom
            .new_element(token.name.clone(), ns, Rc::clone(&token.data))
    }

    fn insert_root(&mut self, token: &StartTag) {
        let element = self.create_element(token);
        self.open.push(element);
        self.dom.append(0, element);
    }

    fn insert_doctype(&mut self, token: &Doctype) {
        let n = self.dom.add(NodeKind::Doctype {
            name: token.name.clone(),
            public_id: token.public_id.clone(),
            system_id: token.system_id.clone(),
        });
        self.dom.append(0, n);
    }

    fn insert_comment(&mut self, data: &str, parent: NodeId) {
        let n = self.dom.add(NodeKind::Comment(data.to_string()));
        self.dom.append(parent, n);
    }

    fn insert_element(&mut self, token: &StartTag) -> Res<NodeId> {
        if self.insert_from_table {
            self.insert_element_table(token)
        } else {
            self.insert_element_normal(token)
        }
    }

    fn insert_element_normal(&mut self, token: &StartTag) -> Res<NodeId> {
        let element = self.create_element(token);
        let parent = self.last_open()?;
        self.dom.append(parent, element);
        self.open.push(element);
        Ok(element)
    }

    fn insert_element_table(&mut self, token: &StartTag) -> Res<NodeId> {
        let element = self.create_element(token);
        if !TABLE_INSERT_MODE_ELEMENTS.contains(&self.last_name()?) {
            return self.insert_element_normal(token);
        }
        let (parent, before) = self.get_table_misnested_node_position()?;
        match before {
            None => self.dom.append(parent, element),
            Some(_) => self.dom.insert_before(parent, element, before)?,
        }
        self.open.push(element);
        Ok(element)
    }

    fn insert_text(&mut self, data: &str) -> Res<()> {
        let parent = self.last_open()?;
        if !self.insert_from_table || !TABLE_INSERT_MODE_ELEMENTS.contains(&self.last_name()?) {
            self.insert_text_at(parent, data, None)
        } else {
            let (p, before) = self.get_table_misnested_node_position()?;
            self.insert_text_at(p, data, before)
        }
    }

    /// `TreeBuilder._insertText`。
    fn insert_text_at(&mut self, parent: NodeId, data: &str, ref_node: Option<NodeId>) -> Res<()> {
        match ref_node {
            None => {
                if let Some(&last) = self.dom.nodes[parent].children.last() {
                    if self.dom.is_text(last) {
                        self.dom.append_text_data(last, data);
                        return Ok(());
                    }
                }
                let t = self.dom.add(NodeKind::Text(data.to_string()));
                self.dom.append(parent, t);
            }
            Some(r) => {
                let index = self.dom.index_of_child(parent, r);
                if index > 0 {
                    let prev = self.dom.nodes[parent].children[index as usize - 1];
                    if self.dom.is_text(prev) {
                        self.dom.append_text_data(prev, data);
                        return Ok(());
                    }
                }
                let t = self.dom.add(NodeKind::Text(data.to_string()));
                self.dom.insert_at(parent, index, t)?;
            }
        }
        Ok(())
    }

    fn get_table_misnested_node_position(&self) -> Res<(NodeId, Option<NodeId>)> {
        let last_table = self
            .open
            .iter()
            .rev()
            .copied()
            .find(|&e| self.name(e) == "table");
        match last_table {
            Some(t) => match self.dom.nodes[t].parent {
                Some(p) => Ok((p, Some(t))),
                None => Ok((self.open_at(self.open_index_of(t) - 1)?, None)),
            },
            None => Ok((self.open_at(0)?, None)),
        }
    }

    fn generate_implied_end_tags(&mut self, exclude: Option<&str>) -> Res<()> {
        loop {
            let name = self.last_name()?;
            if Some(name) != exclude
                && ["dd", "dt", "li", "option", "optgroup", "p", "rp", "rt"].contains(&name)
            {
                self.open.pop();
            } else {
                return Ok(());
            }
        }
    }

    // ---- HtmlParser ----------------------------------------------------

    fn is_html_integration_point(&self, e: NodeId) -> bool {
        if self.name(e) == "annotation-xml" && self.dom.ns(e) == MATHML {
            let attrs = self.dom.attrs(e).borrow();
            let enc = attrs.get_plain("encoding").map(ascii_lower);
            matches!(enc.as_deref(), Some("text/html" | "application/xhtml+xml"))
        } else {
            self.tuple_in(e, HTML_INTEGRATION_POINT_ELEMENTS)
        }
    }

    fn is_mathml_text_integration_point(&self, e: NodeId) -> bool {
        self.tuple_in(e, MATHML_TEXT_INTEGRATION_POINT_ELEMENTS)
    }

    fn in_foreign_content(&self, token: &Token) -> bool {
        let Some(&node) = self.open.last() else {
            return false;
        };
        if self.dom.ns(node) == HTML {
            return false;
        }
        let is_chars = matches!(token, Token::Characters(_) | Token::SpaceCharacters(_));
        if self.is_mathml_text_integration_point(node) {
            if let Token::StartTag(t) = token {
                if t.name != "mglyph" && t.name != "malignmark" {
                    return false;
                }
            }
            if is_chars {
                return false;
            }
        }
        if self.name(node) == "annotation-xml" {
            if let Token::StartTag(t) = token {
                if t.name == "svg" {
                    return false;
                }
            }
        }
        if self.is_html_integration_point(node) && (matches!(token, Token::StartTag(_)) || is_chars)
        {
            return false;
        }
        true
    }

    fn main_loop(&mut self) -> Res<()> {
        loop {
            let cdata_allowed = self.open.last().is_some_and(|&n| self.dom.ns(n) != HTML);
            let Some(mut token) = self.tokenizer.next_token(cdata_allowed)? else {
                break;
            };
            loop {
                let local = if self.in_foreign_content(&token) {
                    Phase::InForeignContent
                } else {
                    self.phase
                };
                let again = match &mut token {
                    Token::Characters(s) => self.process_characters(local, s)?,
                    Token::SpaceCharacters(s) => self.process_space_characters(local, s)?,
                    Token::StartTag(t) => self.process_start_tag(local, t)?,
                    Token::EndTag(n) => self.process_end_tag(local, n)?,
                    Token::Comment(c) => self.process_comment(local, c)?,
                    Token::Doctype(d) => self.process_doctype(local, d)?,
                };
                if !again {
                    break;
                }
            }
        }
        while self.process_eof(self.phase)? {}
        Ok(())
    }

    fn adjust_mathml_attributes(&mut self, token: &StartTag) {
        let mut data = token.data.borrow_mut();
        if let Some(orig) = data.remove(&AttrKey::Plain("definitionurl".to_string())) {
            data.set(AttrKey::Plain("definitionURL".to_string()), orig);
        }
    }

    fn adjust_svg_attributes(&mut self, token: &StartTag) -> Res<()> {
        let mut data = token.data.borrow_mut();
        let keys: Vec<AttrKey> = data.entries.iter().map(|(k, _)| k.clone()).collect();
        for key in keys {
            let AttrKey::Plain(original) = &key else {
                return Err(ParseFailure("TypeError: AttributeName is not a String"));
            };
            if let Some(&(_, svg_name)) = SVG_ATTRIBUTE_REPLACEMENTS
                .iter()
                .find(|(k, _)| k == original)
            {
                let v = data.remove(&key).ok_or(ParseFailure("TypeError: null"))?;
                data.set(AttrKey::Plain(svg_name.to_string()), v);
            }
        }
        Ok(())
    }

    fn adjust_foreign_attributes(&mut self, token: &StartTag) -> Res<()> {
        let mut data = token.data.borrow_mut();
        let keys: Vec<AttrKey> = data.entries.iter().map(|(k, _)| k.clone()).collect();
        for key in keys {
            let AttrKey::Plain(original) = &key else {
                return Err(ParseFailure("TypeError: AttributeName is not a String"));
            };
            if let Some(&(_, prefix, name, namespace)) = FOREIGN_ATTRIBUTE_REPLACEMENTS
                .iter()
                .find(|(k, ..)| k == original)
            {
                let v = data.remove(&key).ok_or(ParseFailure("TypeError: null"))?;
                data.set(
                    AttrKey::Name {
                        prefix,
                        name,
                        namespace,
                    },
                    v,
                );
            }
        }
        Ok(())
    }

    fn reset_insertion_mode(&mut self) {
        let first = self.open.first().copied();
        for &node in self.open.iter().rev() {
            let last = Some(node) == first;
            // fragment 解析之外 innerHTML 为 null：根节点的 nodeName 是 null，哪个分支都不中。
            let node_name: Option<&str> = if last { None } else { Some(self.name(node)) };
            if !last && self.dom.ns(node) != HTML {
                continue;
            }
            let phase = match node_name {
                Some("select") => Phase::InSelect,
                Some("td" | "th") => Phase::InCell,
                Some("tr") => Phase::InRow,
                Some("tbody" | "thead" | "tfoot") => Phase::InTableBody,
                Some("caption") => Phase::InCaption,
                Some("colgroup") => Phase::InColumnGroup,
                Some("table") => Phase::InTable,
                Some("head" | "body") => Phase::InBody,
                Some("frameset") => Phase::InFrameset,
                Some("html") => Phase::BeforeHead,
                _ => continue,
            };
            self.phase = phase;
            return;
        }
        self.phase = Phase::InBody;
    }

    fn parse_rcdata_rawtext(&mut self, token: &StartTag, rawtext: bool) -> Res<()> {
        self.insert_element(token)?;
        self.tokenizer.state = if rawtext {
            State::Rawtext
        } else {
            State::Rcdata
        };
        self.original_phase = Some(self.phase);
        self.phase = Phase::Text;
        Ok(())
    }

    // ---- Phase base ----------------------------------------------------

    /// `Phase.startTagHtml`。
    fn start_tag_html(&mut self, token: &StartTag) -> Res<bool> {
        let root = self.open_at(0)?;
        let root_attrs = Rc::clone(self.dom.attrs(root));
        let entries = token.data.borrow().entries.clone();
        for (k, v) in entries {
            root_attrs.borrow_mut().put_if_absent(k, v);
        }
        self.first_start_tag = false;
        Ok(false)
    }

    fn pop_open_elements_until(&mut self, name: &str) -> Res<()> {
        let mut node = self.pop()?;
        while self.name(node) != name {
            node = self.pop()?;
        }
        Ok(())
    }

    // ---- dispatch --------------------------------------------------------

    fn process_eof(&mut self, phase: Phase) -> Res<bool> {
        use Phase as P;
        match phase {
            P::Initial => {
                self.initial_anything_else();
                Ok(true)
            }
            P::BeforeHtml => {
                self.insert_html_element();
                Ok(true)
            }
            P::BeforeHead => {
                self.before_head_start_tag_head(&StartTag::new("head"))?;
                Ok(true)
            }
            P::InHead => {
                self.in_head_anything_else()?;
                Ok(true)
            }
            P::AfterHead => {
                self.after_head_anything_else()?;
                Ok(true)
            }
            P::InBody => Ok(false),
            P::Text => {
                self.last_open()?;
                self.pop()?;
                self.phase = self
                    .original_phase
                    .ok_or(ParseFailure("TypeError: null phase"))?;
                Ok(true)
            }
            P::InTable => {
                self.last_open()?;
                Ok(false)
            }
            P::InTableText => {
                self.flush_characters()?;
                self.phase = self.table_text_original()?;
                Ok(true)
            }
            P::InCaption | P::InCell => {
                self.process_eof(P::InBody)?;
                Ok(false)
            }
            P::InColumnGroup => {
                if self.last_name()? == "html" {
                    Ok(false)
                } else {
                    self.end_tag_colgroup()?;
                    Ok(true)
                }
            }
            P::InTableBody | P::InRow => {
                self.process_eof(P::InTable)?;
                Ok(false)
            }
            P::InSelect => {
                self.last_open()?;
                Ok(false)
            }
            P::InSelectInTable => {
                self.process_eof(P::InSelect)?;
                Ok(false)
            }
            P::InForeignContent => Err(ParseFailure("UnimplementedError")),
            P::InFrameset => {
                self.last_open()?;
                Ok(false)
            }
            P::AfterBody | P::AfterFrameset | P::AfterAfterBody | P::AfterAfterFrameset => {
                Ok(false)
            }
        }
    }

    fn process_comment(&mut self, phase: Phase, data: &str) -> Res<bool> {
        use Phase as P;
        match phase {
            P::Initial | P::BeforeHtml | P::AfterAfterBody | P::AfterAfterFrameset => {
                self.insert_comment(data, 0);
                Ok(false)
            }
            P::InTableText => {
                self.flush_characters()?;
                self.phase = self.table_text_original()?;
                Ok(true)
            }
            P::AfterBody => {
                let root = self.open_at(0)?;
                self.insert_comment(data, root);
                Ok(false)
            }
            _ => {
                let parent = self.last_open()?;
                self.insert_comment(data, parent);
                Ok(false)
            }
        }
    }

    fn process_doctype(&mut self, phase: Phase, token: &Doctype) -> Res<bool> {
        if phase == Phase::Initial {
            self.initial_doctype(token);
        }
        Ok(false)
    }

    fn process_space_characters(&mut self, phase: Phase, data: &mut String) -> Res<bool> {
        use Phase as P;
        match phase {
            P::Initial | P::BeforeHtml | P::BeforeHead => Ok(false),
            P::InBody => {
                if self.drop_newline {
                    self.process_space_characters_drop_newline(data)?;
                } else {
                    self.reconstruct_active_formatting_elements()?;
                    self.insert_text(data)?;
                }
                Ok(false)
            }
            P::InTable => {
                self.enter_table_text();
                self.table_text_tokens.push(data.clone());
                Ok(false)
            }
            P::InTableText => {
                self.table_text_tokens.push(data.clone());
                Ok(false)
            }
            P::InTableBody | P::InRow => self.process_space_characters(P::InTable, data),
            P::AfterAfterBody | P::AfterAfterFrameset => {
                self.process_space_characters(P::InBody, data)
            }
            _ => {
                self.insert_text(data)?;
                Ok(false)
            }
        }
    }

    fn process_characters(&mut self, phase: Phase, data: &mut String) -> Res<bool> {
        use Phase as P;
        match phase {
            P::Initial => {
                self.initial_anything_else();
                Ok(true)
            }
            P::BeforeHtml => {
                self.insert_html_element();
                Ok(true)
            }
            P::BeforeHead => {
                self.before_head_start_tag_head(&StartTag::new("head"))?;
                Ok(true)
            }
            P::InHead => {
                self.in_head_anything_else()?;
                Ok(true)
            }
            P::AfterHead => {
                self.after_head_anything_else()?;
                Ok(true)
            }
            P::InBody => {
                if data == "\0" {
                    return Ok(false);
                }
                self.reconstruct_active_formatting_elements()?;
                self.insert_text(data)?;
                if self.frameset_ok && !all_whitespace(data) {
                    self.frameset_ok = false;
                }
                Ok(false)
            }
            P::Text => {
                self.insert_text(data)?;
                Ok(false)
            }
            P::InTable => {
                self.enter_table_text();
                if data != "\0" {
                    self.table_text_tokens.push(data.clone());
                }
                Ok(false)
            }
            P::InTableText => {
                if data != "\0" {
                    self.table_text_tokens.push(data.clone());
                }
                Ok(false)
            }
            P::InCaption | P::InCell => self.process_characters(P::InBody, data),
            P::InColumnGroup => {
                let ignore = self.last_name()? == "html";
                self.end_tag_colgroup()?;
                Ok(!ignore)
            }
            P::InTableBody | P::InRow => self.process_characters(P::InTable, data),
            P::InSelect => {
                if data == "\0" {
                    return Ok(false);
                }
                self.insert_text(data)?;
                Ok(false)
            }
            P::InSelectInTable => self.process_characters(P::InSelect, data),
            P::InForeignContent => {
                if data == "\0" {
                    *data = "\u{FFFD}".to_string();
                } else if self.frameset_ok && !all_whitespace(data) {
                    self.frameset_ok = false;
                }
                self.insert_text(data)?;
                Ok(false)
            }
            P::AfterBody => {
                self.phase = P::InBody;
                Ok(true)
            }
            P::InFrameset | P::AfterFrameset | P::AfterAfterFrameset => Ok(false),
            P::AfterAfterBody => {
                self.phase = P::InBody;
                Ok(true)
            }
        }
    }

    fn process_start_tag(&mut self, phase: Phase, t: &mut StartTag) -> Res<bool> {
        use Phase as P;
        match phase {
            P::Initial => {
                self.initial_anything_else();
                Ok(true)
            }
            P::BeforeHtml => {
                if t.name == "html" {
                    self.first_start_tag = true;
                }
                self.insert_html_element();
                Ok(true)
            }
            P::BeforeHead => match t.name.as_str() {
                "html" => self.process_start_tag(P::InBody, t),
                "head" => {
                    self.before_head_start_tag_head(t)?;
                    Ok(false)
                }
                _ => {
                    self.before_head_start_tag_head(&StartTag::new("head"))?;
                    Ok(true)
                }
            },
            P::InHead => self.in_head_start_tag(t),
            P::AfterHead => self.after_head_start_tag(t),
            P::InBody => self.in_body_start_tag(t),
            P::Text => Err(ParseFailure(
                "StateError: Cannot process start stag in text phase",
            )),
            P::InTable => self.in_table_start_tag(t),
            P::InTableText => {
                self.flush_characters()?;
                self.phase = self.table_text_original()?;
                Ok(true)
            }
            P::InCaption => match t.name.as_str() {
                "html" => self.start_tag_html(t),
                "caption" | "col" | "colgroup" | "tbody" | "td" | "tfoot" | "th" | "thead"
                | "tr" => {
                    let ignore = self.ignore_end_tag_caption()?;
                    self.process_end_tag(self.phase, "caption")?;
                    Ok(!ignore)
                }
                _ => self.process_start_tag(P::InBody, t),
            },
            P::InColumnGroup => match t.name.as_str() {
                "html" => self.start_tag_html(t),
                "col" => {
                    self.insert_element(t)?;
                    self.pop()?;
                    Ok(false)
                }
                _ => {
                    let ignore = self.last_name()? == "html";
                    self.end_tag_colgroup()?;
                    Ok(!ignore)
                }
            },
            P::InTableBody => match t.name.as_str() {
                "html" => self.start_tag_html(t),
                "tr" => {
                    self.start_tag_tr(t)?;
                    Ok(false)
                }
                "td" | "th" => {
                    self.start_tag_tr(&StartTag::new("tr"))?;
                    Ok(true)
                }
                "caption" | "col" | "colgroup" | "tbody" | "tfoot" | "thead" => {
                    self.table_body_end_tag_table()
                }
                _ => self.process_start_tag(P::InTable, t),
            },
            P::InRow => match t.name.as_str() {
                "html" => self.start_tag_html(t),
                "td" | "th" => {
                    self.clear_stack_to_table_row_context()?;
                    self.insert_element(t)?;
                    self.phase = P::InCell;
                    self.afe_add(None);
                    Ok(false)
                }
                "caption" | "col" | "colgroup" | "tbody" | "tfoot" | "thead" | "tr" => {
                    let ignore = self.ignore_end_tag_tr()?;
                    self.end_tag_tr()?;
                    Ok(!ignore)
                }
                _ => self.process_start_tag(P::InTable, t),
            },
            P::InCell => match t.name.as_str() {
                "html" => self.start_tag_html(t),
                "caption" | "col" | "colgroup" | "tbody" | "td" | "tfoot" | "th" | "thead"
                | "tr" => {
                    if self.in_scope_v("td", Scope::Table)?
                        || self.in_scope_v("th", Scope::Table)?
                    {
                        self.close_cell()?;
                        Ok(true)
                    } else {
                        Ok(false)
                    }
                }
                _ => self.process_start_tag(P::InBody, t),
            },
            P::InSelect => self.in_select_start_tag(t),
            P::InSelectInTable => match t.name.as_str() {
                "caption" | "table" | "tbody" | "tfoot" | "thead" | "tr" | "td" | "th" => {
                    self.process_end_tag(P::InSelect, "select")?;
                    Ok(true)
                }
                _ => self.process_start_tag(P::InSelect, t),
            },
            P::InForeignContent => self.foreign_start_tag(t),
            P::AfterBody | P::AfterAfterBody => {
                if t.name == "html" {
                    return self.process_start_tag(P::InBody, t);
                }
                self.phase = P::InBody;
                Ok(true)
            }
            P::InFrameset => match t.name.as_str() {
                "html" => self.start_tag_html(t),
                "frameset" => {
                    self.insert_element(t)?;
                    Ok(false)
                }
                "frame" => {
                    self.insert_element(t)?;
                    self.pop()?;
                    Ok(false)
                }
                "noframes" => self.process_start_tag(P::InBody, t),
                _ => Ok(false),
            },
            P::AfterFrameset => match t.name.as_str() {
                "html" => self.start_tag_html(t),
                "noframes" => self.process_start_tag(P::InHead, t),
                _ => Ok(false),
            },
            P::AfterAfterFrameset => match t.name.as_str() {
                "html" => self.process_start_tag(P::InBody, t),
                "noframes" => self.process_start_tag(P::InHead, t),
                _ => Ok(false),
            },
        }
    }

    fn process_end_tag(&mut self, phase: Phase, name: &str) -> Res<bool> {
        use Phase as P;
        match phase {
            P::Initial => {
                self.initial_anything_else();
                Ok(true)
            }
            P::BeforeHtml => match name {
                "head" | "body" | "html" | "br" => {
                    self.insert_html_element();
                    Ok(true)
                }
                _ => Ok(false),
            },
            P::BeforeHead => match name {
                "head" | "body" | "html" | "br" => {
                    self.before_head_start_tag_head(&StartTag::new("head"))?;
                    Ok(true)
                }
                _ => Ok(false),
            },
            P::InHead => match name {
                "head" => {
                    self.in_head_end_tag_head()?;
                    Ok(false)
                }
                "br" | "html" | "body" => {
                    self.in_head_anything_else()?;
                    Ok(true)
                }
                _ => Ok(false),
            },
            P::AfterHead => match name {
                "body" | "html" | "br" => {
                    self.after_head_anything_else()?;
                    Ok(true)
                }
                _ => Ok(false),
            },
            P::InBody => self.in_body_end_tag(name),
            P::Text => {
                self.pop()?;
                self.phase = self
                    .original_phase
                    .ok_or(ParseFailure("TypeError: null phase"))?;
                Ok(false)
            }
            P::InTable => self.in_table_end_tag(name),
            P::InTableText => {
                self.flush_characters()?;
                self.phase = self.table_text_original()?;
                Ok(true)
            }
            P::InCaption => match name {
                "caption" => {
                    self.end_tag_caption()?;
                    Ok(false)
                }
                "table" => {
                    let ignore = self.ignore_end_tag_caption()?;
                    self.process_end_tag(self.phase, "caption")?;
                    Ok(!ignore)
                }
                "body" | "col" | "colgroup" | "html" | "tbody" | "td" | "tfoot" | "th"
                | "thead" | "tr" => Ok(false),
                _ => self.process_end_tag(P::InBody, name),
            },
            P::InColumnGroup => match name {
                "colgroup" => {
                    self.end_tag_colgroup()?;
                    Ok(false)
                }
                "col" => Ok(false),
                _ => {
                    let ignore = self.last_name()? == "html";
                    self.end_tag_colgroup()?;
                    Ok(!ignore)
                }
            },
            P::InTableBody => match name {
                "tbody" | "tfoot" | "thead" => {
                    self.end_tag_table_row_group(name)?;
                    Ok(false)
                }
                "table" => self.table_body_end_tag_table(),
                "body" | "caption" | "col" | "colgroup" | "html" | "td" | "th" | "tr" => Ok(false),
                _ => self.process_end_tag(P::InTable, name),
            },
            P::InRow => match name {
                "tr" => {
                    self.end_tag_tr()?;
                    Ok(false)
                }
                "table" => {
                    let ignore = self.ignore_end_tag_tr()?;
                    self.end_tag_tr()?;
                    Ok(!ignore)
                }
                "tbody" | "tfoot" | "thead" => {
                    if self.in_scope_v(name, Scope::Table)? {
                        self.end_tag_tr()?;
                        Ok(true)
                    } else {
                        Ok(false)
                    }
                }
                "body" | "caption" | "col" | "colgroup" | "html" | "td" | "th" => Ok(false),
                _ => self.process_end_tag(P::InTable, name),
            },
            P::InCell => match name {
                "td" | "th" => {
                    self.end_tag_table_cell(name)?;
                    Ok(false)
                }
                "body" | "caption" | "col" | "colgroup" | "html" => Ok(false),
                "table" | "tbody" | "tfoot" | "thead" | "tr" => {
                    if self.in_scope_v(name, Scope::Table)? {
                        self.close_cell()?;
                        Ok(true)
                    } else {
                        Ok(false)
                    }
                }
                _ => self.process_end_tag(P::InBody, name),
            },
            P::InSelect => self.in_select_end_tag(name),
            P::InSelectInTable => match name {
                "caption" | "table" | "tbody" | "tfoot" | "thead" | "tr" | "td" | "th" => {
                    if self.in_scope_v(name, Scope::Table)? {
                        self.process_end_tag(P::InSelect, "select")?;
                        Ok(true)
                    } else {
                        Ok(false)
                    }
                }
                _ => self.process_end_tag(P::InSelect, name),
            },
            P::InForeignContent => self.foreign_end_tag(name),
            P::AfterBody => {
                if name == "html" {
                    self.phase = P::AfterAfterBody;
                    return Ok(false);
                }
                self.phase = P::InBody;
                Ok(true)
            }
            P::InFrameset => {
                if name == "frameset" {
                    if self.last_name()? != "html" {
                        self.pop()?;
                    }
                    if self.last_name()? != "frameset" {
                        self.phase = P::AfterFrameset;
                    }
                }
                Ok(false)
            }
            P::AfterFrameset => {
                if name == "html" {
                    self.phase = P::AfterAfterFrameset;
                }
                Ok(false)
            }
            P::AfterAfterBody => {
                self.phase = P::InBody;
                Ok(true)
            }
            P::AfterAfterFrameset => Ok(false),
        }
    }

    // ---- InitialPhase --------------------------------------------------

    fn initial_doctype(&mut self, token: &Doctype) {
        let name = &token.name;
        let public_id = token
            .public_id
            .as_deref()
            .map(ascii_lower)
            .unwrap_or_default();
        let system_id = token.system_id.as_deref();
        self.insert_doctype(token);
        const XHTML_401: &[&str] = &[
            "-//w3c//dtd html 4.01 frameset//",
            "-//w3c//dtd html 4.01 transitional//",
        ];
        if !token.correct
            || name != "html"
            || starts_with_any(&public_id, QUIRKS_PUBLIC_PREFIXES)
            || [
                "-//w3o//dtd w3 html strict 3.0//en//",
                "-/w3c/dtd html 4.0 transitional/en",
                "html",
            ]
            .contains(&public_id.as_str())
            || (starts_with_any(&public_id, XHTML_401) && system_id.is_none())
            || system_id.is_some_and(|s| {
                dart_lower_str(s) == "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd"
            })
        {
            self.compat_mode = CompatMode::Quirks;
        } else if starts_with_any(
            &public_id,
            &[
                "-//w3c//dtd xhtml 1.0 frameset//",
                "-//w3c//dtd xhtml 1.0 transitional//",
            ],
        ) || (starts_with_any(&public_id, XHTML_401) && system_id.is_some())
        {
            self.compat_mode = CompatMode::LimitedQuirks;
        }
        self.phase = Phase::BeforeHtml;
    }

    fn initial_anything_else(&mut self) {
        self.compat_mode = CompatMode::Quirks;
        self.phase = Phase::BeforeHtml;
    }

    // ---- BeforeHtmlPhase / BeforeHeadPhase -------------------------------

    fn insert_html_element(&mut self) {
        self.insert_root(&StartTag::new("html"));
        self.phase = Phase::BeforeHead;
    }

    fn before_head_start_tag_head(&mut self, token: &StartTag) -> Res<()> {
        self.insert_element(token)?;
        self.head_pointer = Some(self.last_open()?);
        self.phase = Phase::InHead;
        Ok(())
    }

    // ---- InHeadPhase -----------------------------------------------------

    fn in_head_start_tag(&mut self, t: &mut StartTag) -> Res<bool> {
        match t.name.as_str() {
            "html" => self.process_start_tag(Phase::InBody, t),
            "title" => {
                self.parse_rcdata_rawtext(t, false)?;
                Ok(false)
            }
            "noscript" | "noframes" | "style" => {
                self.parse_rcdata_rawtext(t, true)?;
                Ok(false)
            }
            "script" => {
                self.insert_element(t)?;
                self.tokenizer.state = State::ScriptData;
                self.original_phase = Some(self.phase);
                self.phase = Phase::Text;
                Ok(false)
            }
            "base" | "basefont" | "bgsound" | "command" | "link" | "meta" => {
                // meta：字符串输入的编码是确定的（charEncodingCertain），不走换编码。
                self.insert_element(t)?;
                self.pop()?;
                t.self_closing_acknowledged = true;
                Ok(false)
            }
            "head" => Ok(false),
            _ => {
                self.in_head_anything_else()?;
                Ok(true)
            }
        }
    }

    fn in_head_end_tag_head(&mut self) -> Res<()> {
        self.pop()?;
        self.phase = Phase::AfterHead;
        Ok(())
    }

    fn in_head_anything_else(&mut self) -> Res<()> {
        self.in_head_end_tag_head()
    }

    // ---- AfterHeadPhase --------------------------------------------------

    fn after_head_start_tag(&mut self, t: &mut StartTag) -> Res<bool> {
        match t.name.as_str() {
            "html" => self.process_start_tag(Phase::InBody, t),
            "body" => {
                self.frameset_ok = false;
                self.insert_element(t)?;
                self.phase = Phase::InBody;
                Ok(false)
            }
            "frameset" => {
                self.insert_element(t)?;
                self.phase = Phase::InFrameset;
                Ok(false)
            }
            "base" | "basefont" | "bgsound" | "link" | "meta" | "noframes" | "script" | "style"
            | "title" => {
                let head = self
                    .head_pointer
                    .ok_or(ParseFailure("TypeError: headPointer is null"))?;
                self.open.push(head);
                self.process_start_tag(Phase::InHead, t)?;
                if let Some(&node) = self.open.iter().rev().find(|&&n| self.name(n) == "head") {
                    self.open_remove(node);
                }
                Ok(false)
            }
            "head" => Ok(false),
            _ => {
                self.after_head_anything_else()?;
                Ok(true)
            }
        }
    }

    fn after_head_anything_else(&mut self) -> Res<()> {
        self.insert_element(&StartTag::new("body"))?;
        self.phase = Phase::InBody;
        self.frameset_ok = true;
        Ok(())
    }

    // ---- InBodyPhase -----------------------------------------------------

    fn in_body_start_tag(&mut self, t: &mut StartTag) -> Res<bool> {
        match t.name.as_str() {
            "html" => self.start_tag_html(t),
            "base" | "basefont" | "bgsound" | "command" | "link" | "meta" | "noframes"
            | "script" | "style" | "title" => self.process_start_tag(Phase::InHead, t),
            "body" => {
                if self.open.len() == 1 || self.name(self.open_at(1)?) != "body" {
                } else {
                    self.frameset_ok = false;
                    let body = self.open_at(1)?;
                    let body_attrs = Rc::clone(self.dom.attrs(body));
                    let entries = t.data.borrow().entries.clone();
                    for (k, v) in entries {
                        body_attrs.borrow_mut().put_if_absent(k, v);
                    }
                }
                Ok(false)
            }
            "frameset" => {
                if self.open.len() == 1 || self.name(self.open_at(1)?) != "body" {
                } else if self.frameset_ok {
                    let body = self.open_at(1)?;
                    if let Some(p) = self.dom.nodes[body].parent {
                        self.dom.remove_child(p, body);
                    }
                    while self.last_name()? != "html" {
                        self.pop()?;
                    }
                    self.insert_element(t)?;
                    self.phase = Phase::InFrameset;
                }
                Ok(false)
            }
            "address" | "article" | "aside" | "blockquote" | "center" | "details" | "dir"
            | "div" | "dl" | "fieldset" | "figcaption" | "figure" | "footer" | "header"
            | "hgroup" | "menu" | "nav" | "ol" | "p" | "section" | "summary" | "ul" => {
                self.start_tag_close_p(t)?;
                Ok(false)
            }
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                if self.in_scope_v("p", Scope::Button)? {
                    self.end_tag_p()?;
                }
                if HEADING_ELEMENTS.contains(&self.last_name()?) {
                    self.pop()?;
                }
                self.insert_element(t)?;
                Ok(false)
            }
            "pre" | "listing" => {
                if self.in_scope_v("p", Scope::Button)? {
                    self.end_tag_p()?;
                }
                self.insert_element(t)?;
                self.frameset_ok = false;
                self.drop_newline = true;
                Ok(false)
            }
            "form" => {
                if self.form_pointer.is_none() {
                    if self.in_scope_v("p", Scope::Button)? {
                        self.end_tag_p()?;
                    }
                    self.insert_element(t)?;
                    self.form_pointer = Some(self.last_open()?);
                }
                Ok(false)
            }
            "li" | "dd" | "dt" => {
                self.frameset_ok = false;
                let stop_names: &[&str] = if t.name == "li" {
                    &["li"]
                } else {
                    &["dt", "dd"]
                };
                let nodes: Vec<NodeId> = self.open.iter().rev().copied().collect();
                for node in nodes {
                    let n = self.name(node).to_string();
                    if stop_names.contains(&n.as_str()) {
                        self.process_end_tag(self.phase, &n)?;
                        break;
                    }
                    if self.is_special(node) && !["address", "div", "p"].contains(&n.as_str()) {
                        break;
                    }
                }
                if self.in_scope_v("p", Scope::Button)? {
                    self.process_end_tag(self.phase, "p")?;
                }
                self.insert_element(t)?;
                Ok(false)
            }
            "plaintext" => {
                if self.in_scope_v("p", Scope::Button)? {
                    self.end_tag_p()?;
                }
                self.insert_element(t)?;
                self.tokenizer.state = State::Plaintext;
                Ok(false)
            }
            "a" => {
                if let Some(afe_a) = self.element_in_active_formatting_elements("a") {
                    self.end_tag_formatting("a")?;
                    self.open_remove(afe_a);
                    self.afe_remove(afe_a);
                }
                self.reconstruct_active_formatting_elements()?;
                self.add_formatting_element(t)?;
                Ok(false)
            }
            "b" | "big" | "code" | "em" | "font" | "i" | "s" | "small" | "strike" | "strong"
            | "tt" | "u" => {
                self.reconstruct_active_formatting_elements()?;
                self.add_formatting_element(t)?;
                Ok(false)
            }
            "nobr" => {
                self.reconstruct_active_formatting_elements()?;
                if self.in_scope("nobr")? {
                    self.process_end_tag(Phase::InBody, "nobr")?;
                    self.reconstruct_active_formatting_elements()?;
                }
                self.add_formatting_element(t)?;
                Ok(false)
            }
            "button" => {
                if self.in_scope("button")? {
                    self.process_end_tag(Phase::InBody, "button")?;
                    Ok(true)
                } else {
                    self.reconstruct_active_formatting_elements()?;
                    self.insert_element(t)?;
                    self.frameset_ok = false;
                    Ok(false)
                }
            }
            "applet" | "marquee" | "object" => {
                self.reconstruct_active_formatting_elements()?;
                self.insert_element(t)?;
                self.afe_add(None);
                self.frameset_ok = false;
                Ok(false)
            }
            "xmp" => {
                if self.in_scope_v("p", Scope::Button)? {
                    self.end_tag_p()?;
                }
                self.reconstruct_active_formatting_elements()?;
                self.frameset_ok = false;
                self.parse_rcdata_rawtext(t, true)?;
                Ok(false)
            }
            "table" => {
                if self.compat_mode != CompatMode::Quirks && self.in_scope_v("p", Scope::Button)? {
                    self.process_end_tag(Phase::InBody, "p")?;
                }
                self.insert_element(t)?;
                self.frameset_ok = false;
                self.phase = Phase::InTable;
                Ok(false)
            }
            "area" | "br" | "embed" | "img" | "keygen" | "wbr" => {
                self.start_tag_void_formatting(t)?;
                Ok(false)
            }
            "param" | "source" | "track" => {
                self.insert_element(t)?;
                self.pop()?;
                t.self_closing_acknowledged = true;
                Ok(false)
            }
            "input" => {
                let saved = self.frameset_ok;
                self.start_tag_void_formatting(t)?;
                if t.data
                    .borrow()
                    .get_plain("type")
                    .map(ascii_lower)
                    .as_deref()
                    == Some("hidden")
                {
                    self.frameset_ok = saved;
                }
                Ok(false)
            }
            "hr" => {
                if self.in_scope_v("p", Scope::Button)? {
                    self.end_tag_p()?;
                }
                self.insert_element(t)?;
                self.pop()?;
                t.self_closing_acknowledged = true;
                self.frameset_ok = false;
                Ok(false)
            }
            "image" => {
                let mut img = StartTag::with_data("img", Rc::clone(&t.data));
                img.self_closing = t.self_closing;
                self.process_start_tag(Phase::InBody, &mut img)?;
                Ok(false)
            }
            "isindex" => {
                self.start_tag_is_index(t)?;
                Ok(false)
            }
            "textarea" => {
                self.insert_element(t)?;
                self.tokenizer.state = State::Rcdata;
                self.drop_newline = true;
                self.frameset_ok = false;
                Ok(false)
            }
            "iframe" => {
                self.frameset_ok = false;
                self.parse_rcdata_rawtext(t, true)?;
                Ok(false)
            }
            "noembed" | "noscript" => {
                self.parse_rcdata_rawtext(t, true)?;
                Ok(false)
            }
            "select" => {
                self.reconstruct_active_formatting_elements()?;
                self.insert_element(t)?;
                self.frameset_ok = false;
                use Phase as P;
                self.phase = if matches!(
                    self.phase,
                    P::InTable
                        | P::InCaption
                        | P::InColumnGroup
                        | P::InTableBody
                        | P::InRow
                        | P::InCell
                ) {
                    P::InSelectInTable
                } else {
                    P::InSelect
                };
                Ok(false)
            }
            "rp" | "rt" => {
                if self.in_scope("ruby")? {
                    self.generate_implied_end_tags(None)?;
                }
                self.insert_element(t)?;
                Ok(false)
            }
            "option" | "optgroup" => {
                if self.last_name()? == "option" {
                    self.process_end_tag(self.phase, "option")?;
                }
                self.reconstruct_active_formatting_elements()?;
                self.insert_element(t)?;
                Ok(false)
            }
            "math" => {
                self.reconstruct_active_formatting_elements()?;
                self.adjust_mathml_attributes(t);
                self.adjust_foreign_attributes(t)?;
                t.namespace = Some(MATHML);
                self.insert_element(t)?;
                if t.self_closing {
                    self.pop()?;
                    t.self_closing_acknowledged = true;
                }
                Ok(false)
            }
            "svg" => {
                self.reconstruct_active_formatting_elements()?;
                self.adjust_svg_attributes(t)?;
                self.adjust_foreign_attributes(t)?;
                t.namespace = Some(SVG);
                self.insert_element(t)?;
                if t.self_closing {
                    self.pop()?;
                    t.self_closing_acknowledged = true;
                }
                Ok(false)
            }
            "caption" | "col" | "colgroup" | "frame" | "head" | "tbody" | "td" | "tfoot" | "th"
            | "thead" | "tr" => Ok(false),
            _ => {
                self.reconstruct_active_formatting_elements()?;
                self.insert_element(t)?;
                Ok(false)
            }
        }
    }

    fn start_tag_close_p(&mut self, t: &StartTag) -> Res<()> {
        if self.in_scope_v("p", Scope::Button)? {
            self.end_tag_p()?;
        }
        self.insert_element(t)?;
        Ok(())
    }

    fn start_tag_void_formatting(&mut self, t: &mut StartTag) -> Res<()> {
        self.reconstruct_active_formatting_elements()?;
        self.insert_element(t)?;
        self.pop()?;
        t.self_closing_acknowledged = true;
        self.frameset_ok = false;
        Ok(())
    }

    fn start_tag_is_index(&mut self, t: &StartTag) -> Res<()> {
        if self.form_pointer.is_some() {
            return Ok(());
        }
        let mut form_attrs = AttrMap::default();
        if let Some(action) = t.data.borrow().get_plain("action") {
            form_attrs.set(AttrKey::Plain("action".to_string()), action.to_string());
        }
        let mut form = StartTag::with_data("form", Rc::new(RefCell::new(form_attrs)));
        self.process_start_tag(Phase::InBody, &mut form)?;
        self.process_start_tag(Phase::InBody, &mut StartTag::new("hr"))?;
        self.process_start_tag(Phase::InBody, &mut StartTag::new("label"))?;
        let mut prompt = t
            .data
            .borrow()
            .get_plain("prompt")
            .map(str::to_string)
            .unwrap_or_else(|| "This is a searchable index. Enter search keywords: ".to_string());
        self.process_characters(Phase::InBody, &mut prompt)?;
        let mut attributes = t.data.borrow().clone();
        attributes.remove(&AttrKey::Plain("action".to_string()));
        attributes.remove(&AttrKey::Plain("prompt".to_string()));
        attributes.set(AttrKey::Plain("name".to_string()), "isindex".to_string());
        let mut input = StartTag::with_data("input", Rc::new(RefCell::new(attributes)));
        input.self_closing = t.self_closing;
        self.process_start_tag(Phase::InBody, &mut input)?;
        self.process_end_tag(Phase::InBody, "label")?;
        self.process_start_tag(Phase::InBody, &mut StartTag::new("hr"))?;
        self.process_end_tag(Phase::InBody, "form")?;
        Ok(())
    }

    fn add_formatting_element(&mut self, t: &StartTag) -> Res<()> {
        self.insert_element(t)?;
        let element = self.last_open()?;
        let mut matching: Vec<NodeId> = Vec::new();
        for &node in self.afe.iter().rev() {
            let Some(node) = node else { break };
            if self.dom.ns(node) == self.dom.ns(element)
                && self.name(node) == self.name(element)
                && self
                    .dom
                    .attrs(node)
                    .borrow()
                    .equals(&self.dom.attrs(element).borrow())
            {
                matching.push(node);
            }
        }
        if matching.len() == 3 {
            self.afe_remove(*matching.last().unwrap());
        }
        self.afe_add(Some(element));
        Ok(())
    }

    fn process_space_characters_drop_newline(&mut self, data: &str) -> Res<()> {
        let mut data = data;
        self.drop_newline = false;
        if data.starts_with('\n') {
            let last_open = self.last_open()?;
            if ["pre", "listing", "textarea"].contains(&self.name(last_open))
                && self.dom.nodes[last_open].children.is_empty()
            {
                data = &data[1..];
            }
        }
        if !data.is_empty() {
            self.reconstruct_active_formatting_elements()?;
            self.insert_text(data)?;
        }
        Ok(())
    }

    fn in_body_end_tag(&mut self, name: &str) -> Res<bool> {
        match name {
            "body" => {
                self.end_tag_body()?;
                Ok(false)
            }
            "html" => {
                if self.in_scope("body")? {
                    self.end_tag_body()?;
                    return Ok(true);
                }
                Ok(false)
            }
            "address" | "article" | "aside" | "blockquote" | "button" | "center" | "details"
            | "dir" | "div" | "dl" | "fieldset" | "figcaption" | "figure" | "footer" | "header"
            | "hgroup" | "listing" | "menu" | "nav" | "ol" | "pre" | "section" | "summary"
            | "ul" => {
                if name == "pre" {
                    self.drop_newline = false;
                }
                let in_scope = self.in_scope(name)?;
                if in_scope {
                    self.generate_implied_end_tags(None)?;
                }
                self.last_open()?;
                if in_scope {
                    self.pop_open_elements_until(name)?;
                }
                Ok(false)
            }
            "form" => {
                let node = self.form_pointer.take();
                match node {
                    Some(n) if self.element_in_scope(Target::Node(n), Scope::Default)? => {
                        self.generate_implied_end_tags(None)?;
                        self.last_open()?;
                        self.open_remove(n);
                    }
                    _ => {}
                }
                Ok(false)
            }
            "p" => {
                self.end_tag_p()?;
                Ok(false)
            }
            "dd" | "dt" | "li" => {
                let variant = if name == "li" {
                    Scope::List
                } else {
                    Scope::Default
                };
                if self.in_scope_v(name, variant)? {
                    self.generate_implied_end_tags(Some(name))?;
                    self.last_open()?;
                    self.pop_open_elements_until(name)?;
                }
                Ok(false)
            }
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                for item in HEADING_ELEMENTS {
                    if self.in_scope(item)? {
                        self.generate_implied_end_tags(None)?;
                        break;
                    }
                }
                self.last_open()?;
                for item in HEADING_ELEMENTS {
                    if self.in_scope(item)? {
                        let mut node = self.pop()?;
                        while !HEADING_ELEMENTS.contains(&self.name(node)) {
                            node = self.pop()?;
                        }
                        break;
                    }
                }
                Ok(false)
            }
            "a" | "b" | "big" | "code" | "em" | "font" | "i" | "nobr" | "s" | "small"
            | "strike" | "strong" | "tt" | "u" => {
                self.end_tag_formatting(name)?;
                Ok(false)
            }
            "applet" | "marquee" | "object" => {
                if self.in_scope(name)? {
                    self.generate_implied_end_tags(None)?;
                }
                self.last_open()?;
                if self.in_scope(name)? {
                    self.pop_open_elements_until(name)?;
                    self.clear_active_formatting_elements()?;
                }
                Ok(false)
            }
            "br" => {
                self.reconstruct_active_formatting_elements()?;
                self.insert_element(&StartTag::new("br"))?;
                self.pop()?;
                Ok(false)
            }
            _ => {
                let nodes: Vec<NodeId> = self.open.iter().rev().copied().collect();
                for node in nodes {
                    if self.name(node) == name {
                        self.generate_implied_end_tags(Some(name))?;
                        self.last_open()?;
                        while self.pop()? != node {}
                        break;
                    } else if self.is_special(node) {
                        break;
                    }
                }
                Ok(false)
            }
        }
    }

    fn end_tag_p(&mut self) -> Res<()> {
        if !self.in_scope_v("p", Scope::Button)? {
            self.start_tag_close_p(&StartTag::new("p"))?;
            self.end_tag_p()
        } else {
            self.generate_implied_end_tags(Some("p"))?;
            self.last_open()?;
            self.pop_open_elements_until("p")
        }
    }

    fn end_tag_body(&mut self) -> Res<()> {
        if !self.in_scope("body")? {
            return Ok(());
        }
        self.last_open()?;
        // 其余分支只报解析错误。
        self.phase = Phase::AfterBody;
        Ok(())
    }

    /// The much-feared adoption agency algorithm（逐行对照 `endTagFormatting`）。
    fn end_tag_formatting(&mut self, name: &str) -> Res<()> {
        let mut outer_loop_counter = 0;
        while outer_loop_counter < 8 {
            outer_loop_counter += 1;

            let formatting_element = self.element_in_active_formatting_elements(name);
            let fe = match formatting_element {
                None => return Ok(()),
                Some(fe) => fe,
            };
            if self.open_contains(fe) && !self.in_scope(self.name(fe))? {
                return Ok(());
            } else if !self.open_contains(fe) {
                self.afe_remove(fe);
                return Ok(());
            }
            self.last_open()?;

            let afe_index = self.open_index_of(fe);
            let mut furthest_block = None;
            for &element in self.open.iter().skip(afe_index.max(0) as usize) {
                if self.is_special(element) {
                    furthest_block = Some(element);
                    break;
                }
            }
            let Some(furthest_block) = furthest_block else {
                let mut element = self.pop()?;
                while element != fe {
                    element = self.pop()?;
                }
                self.afe_remove(element);
                return Ok(());
            };

            let common_ancestor = self.open_at(afe_index - 1)?;

            let mut bookmark = self.afe_index_of(fe);

            let mut last_node = furthest_block;
            let mut node;
            let mut inner_loop_counter = 0;

            let mut index = self.open_index_of(furthest_block);
            while inner_loop_counter < 3 {
                inner_loop_counter += 1;

                index -= 1;
                node = self.open_at(index)?;
                if !self.afe.contains(&Some(node)) {
                    self.open_remove(node);
                    continue;
                }
                if node == fe {
                    break;
                }
                if last_node == furthest_block {
                    bookmark = self.afe_index_of(node) + 1;
                }
                let clone = self.dom.clone_element(node);
                let ai = self.afe_index_of(node);
                if ai < 0 {
                    return Err(range_error());
                }
                self.afe[ai as usize] = Some(clone);
                let oi = self.open_index_of(node);
                if oi < 0 {
                    return Err(range_error());
                }
                self.open[oi as usize] = clone;
                node = clone;

                if let Some(p) = self.dom.nodes[last_node].parent {
                    self.dom.remove_child(p, last_node);
                }
                self.dom.append(node, last_node);
                last_node = node;
            }

            if let Some(p) = self.dom.nodes[last_node].parent {
                self.dom.remove_child(p, last_node);
            }

            if TABLE_INSERT_MODE_ELEMENTS.contains(&self.name(common_ancestor)) {
                let (p, before) = self.get_table_misnested_node_position()?;
                self.dom.insert_before(p, last_node, before)?;
            } else {
                self.dom.append(common_ancestor, last_node);
            }

            let clone = self.dom.clone_element(fe);
            self.dom.reparent_children(furthest_block, clone);
            self.dom.append(furthest_block, clone);

            self.afe_remove(fe);
            let at = bookmark.min(self.afe.len() as isize);
            if at < 0 {
                return Err(range_error());
            }
            self.afe.insert(at as usize, Some(clone));

            self.open_remove(fe);
            let at = self.open_index_of(furthest_block) + 1;
            if at < 0 || at as usize > self.open.len() {
                return Err(range_error());
            }
            self.open.insert(at as usize, clone);
        }
        Ok(())
    }

    // ---- InTablePhase ----------------------------------------------------

    fn enter_table_text(&mut self) {
        let original = self.phase;
        self.phase = Phase::InTableText;
        self.table_text_original_phase = Some(original);
    }

    fn table_text_original(&self) -> Res<Phase> {
        self.table_text_original_phase
            .ok_or(ParseFailure("TypeError: null phase"))
    }

    fn clear_stack_to_table_context(&mut self) -> Res<()> {
        while !["table", "html"].contains(&self.last_name()?) {
            self.pop()?;
        }
        Ok(())
    }

    fn in_table_start_tag(&mut self, t: &mut StartTag) -> Res<bool> {
        match t.name.as_str() {
            "html" => self.start_tag_html(t),
            "caption" => {
                self.clear_stack_to_table_context()?;
                self.afe_add(None);
                self.insert_element(t)?;
                self.phase = Phase::InCaption;
                Ok(false)
            }
            "colgroup" => {
                self.start_tag_colgroup(t)?;
                Ok(false)
            }
            "col" => {
                self.start_tag_colgroup(&StartTag::new("colgroup"))?;
                Ok(true)
            }
            "tbody" | "tfoot" | "thead" => {
                self.start_tag_row_group(t)?;
                Ok(false)
            }
            "td" | "th" | "tr" => {
                self.start_tag_row_group(&StartTag::new("tbody"))?;
                Ok(true)
            }
            "table" => {
                self.process_end_tag(self.phase, "table")?;
                Ok(true)
            }
            "style" | "script" => self.process_start_tag(Phase::InHead, t),
            "input" => {
                if t.data
                    .borrow()
                    .get_plain("type")
                    .map(ascii_lower)
                    .as_deref()
                    == Some("hidden")
                {
                    self.insert_element(t)?;
                    self.pop()?;
                } else {
                    self.in_table_start_tag_other(t)?;
                }
                Ok(false)
            }
            "form" => {
                if self.form_pointer.is_none() {
                    self.insert_element(t)?;
                    self.form_pointer = Some(self.last_open()?);
                    self.pop()?;
                }
                Ok(false)
            }
            _ => {
                self.in_table_start_tag_other(t)?;
                Ok(false)
            }
        }
    }

    fn in_table_start_tag_other(&mut self, t: &mut StartTag) -> Res<()> {
        self.insert_from_table = true;
        self.process_start_tag(Phase::InBody, t)?;
        self.insert_from_table = false;
        Ok(())
    }

    fn start_tag_colgroup(&mut self, t: &StartTag) -> Res<()> {
        self.clear_stack_to_table_context()?;
        self.insert_element(t)?;
        self.phase = Phase::InColumnGroup;
        Ok(())
    }

    fn start_tag_row_group(&mut self, t: &StartTag) -> Res<()> {
        self.clear_stack_to_table_context()?;
        self.insert_element(t)?;
        self.phase = Phase::InTableBody;
        Ok(())
    }

    fn in_table_end_tag(&mut self, name: &str) -> Res<bool> {
        match name {
            "table" => {
                if self.in_scope_v("table", Scope::Table)? {
                    self.generate_implied_end_tags(None)?;
                    while self.last_name()? != "table" {
                        self.pop()?;
                    }
                    self.pop()?;
                    self.reset_insertion_mode();
                }
                Ok(false)
            }
            "body" | "caption" | "col" | "colgroup" | "html" | "tbody" | "td" | "tfoot" | "th"
            | "thead" | "tr" => Ok(false),
            _ => {
                self.insert_from_table = true;
                self.process_end_tag(Phase::InBody, name)?;
                self.insert_from_table = false;
                Ok(false)
            }
        }
    }

    // ---- InTableTextPhase ------------------------------------------------

    fn flush_characters(&mut self) -> Res<()> {
        if self.table_text_tokens.is_empty() {
            return Ok(());
        }
        let mut data: String = self.table_text_tokens.concat();
        if !all_whitespace(&data) {
            // InTablePhase.insertText
            self.insert_from_table = true;
            self.process_characters(Phase::InBody, &mut data)?;
            self.insert_from_table = false;
        } else if !data.is_empty() {
            self.insert_text(&data)?;
        }
        self.table_text_tokens = Vec::new();
        Ok(())
    }

    // ---- InCaptionPhase / InColumnGroupPhase -----------------------------

    fn ignore_end_tag_caption(&self) -> Res<bool> {
        Ok(!self.in_scope_v("caption", Scope::Table)?)
    }

    fn end_tag_caption(&mut self) -> Res<()> {
        if !self.ignore_end_tag_caption()? {
            self.generate_implied_end_tags(None)?;
            self.last_open()?;
            while self.last_name()? != "caption" {
                self.pop()?;
            }
            self.pop()?;
            self.clear_active_formatting_elements()?;
            self.phase = Phase::InTable;
        }
        Ok(())
    }

    fn end_tag_colgroup(&mut self) -> Res<()> {
        if self.last_name()? == "html" {
        } else {
            self.pop()?;
            self.phase = Phase::InTable;
        }
        Ok(())
    }

    // ---- InTableBodyPhase / InRowPhase / InCellPhase ---------------------

    fn clear_stack_to_table_body_context(&mut self) -> Res<()> {
        while !["tbody", "tfoot", "thead", "html"].contains(&self.last_name()?) {
            self.pop()?;
        }
        Ok(())
    }

    fn start_tag_tr(&mut self, t: &StartTag) -> Res<()> {
        self.clear_stack_to_table_body_context()?;
        self.insert_element(t)?;
        self.phase = Phase::InRow;
        Ok(())
    }

    fn end_tag_table_row_group(&mut self, name: &str) -> Res<()> {
        if self.in_scope_v(name, Scope::Table)? {
            self.clear_stack_to_table_body_context()?;
            self.pop()?;
            self.phase = Phase::InTable;
        }
        Ok(())
    }

    /// `InTableBodyPhase.endTagTable`（也服务 `startTagTableOther`）。
    fn table_body_end_tag_table(&mut self) -> Res<bool> {
        if self.in_scope_v("tbody", Scope::Table)?
            || self.in_scope_v("thead", Scope::Table)?
            || self.in_scope_v("tfoot", Scope::Table)?
        {
            self.clear_stack_to_table_body_context()?;
            let last = self.last_name()?.to_string();
            self.end_tag_table_row_group(&last)?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn clear_stack_to_table_row_context(&mut self) -> Res<()> {
        loop {
            let last = self.last_name()?;
            if last == "tr" || last == "html" {
                break;
            }
            self.pop()?;
        }
        Ok(())
    }

    fn ignore_end_tag_tr(&self) -> Res<bool> {
        Ok(!self.in_scope_v("tr", Scope::Table)?)
    }

    fn end_tag_tr(&mut self) -> Res<()> {
        if !self.ignore_end_tag_tr()? {
            self.clear_stack_to_table_row_context()?;
            self.pop()?;
            self.phase = Phase::InTableBody;
        }
        Ok(())
    }

    fn close_cell(&mut self) -> Res<()> {
        if self.in_scope_v("td", Scope::Table)? {
            self.end_tag_table_cell("td")
        } else if self.in_scope_v("th", Scope::Table)? {
            self.end_tag_table_cell("th")
        } else {
            Ok(())
        }
    }

    fn end_tag_table_cell(&mut self, name: &str) -> Res<()> {
        if self.in_scope_v(name, Scope::Table)? {
            self.generate_implied_end_tags(Some(name))?;
            if self.last_name()? != name {
                self.pop_open_elements_until(name)?;
            } else {
                self.pop()?;
            }
            self.clear_active_formatting_elements()?;
            self.phase = Phase::InRow;
        }
        Ok(())
    }

    // ---- InSelectPhase ---------------------------------------------------

    fn in_select_start_tag(&mut self, t: &mut StartTag) -> Res<bool> {
        match t.name.as_str() {
            "html" => self.start_tag_html(t),
            "option" => {
                if self.last_name()? == "option" {
                    self.pop()?;
                }
                self.insert_element(t)?;
                Ok(false)
            }
            "optgroup" => {
                if self.last_name()? == "option" {
                    self.pop()?;
                }
                if self.last_name()? == "optgroup" {
                    self.pop()?;
                }
                self.insert_element(t)?;
                Ok(false)
            }
            "select" => {
                self.end_tag_select()?;
                Ok(false)
            }
            "input" | "keygen" | "textarea" => {
                if self.in_scope_v("select", Scope::Select)? {
                    self.end_tag_select()?;
                    Ok(true)
                } else {
                    Ok(false)
                }
            }
            "script" => self.process_start_tag(Phase::InHead, t),
            _ => Ok(false),
        }
    }

    // 逐行对应 package:html 的 if 结构；并进 match guard 会让读者以为它会落到 `_` 分支。
    #[allow(clippy::collapsible_match)]
    fn in_select_end_tag(&mut self, name: &str) -> Res<bool> {
        match name {
            "option" => {
                if self.last_name()? == "option" {
                    self.pop()?;
                }
            }
            "optgroup" => {
                if self.last_name()? == "option" {
                    let i = self.open.len() as isize - 2;
                    if self.name(self.open_at(i)?) == "optgroup" {
                        self.pop()?;
                    }
                }
                if self.last_name()? == "optgroup" {
                    self.pop()?;
                }
            }
            "select" => self.end_tag_select()?,
            _ => {}
        }
        Ok(false)
    }

    fn end_tag_select(&mut self) -> Res<()> {
        if self.in_scope_v("select", Scope::Select)? {
            self.pop_open_elements_until("select")?;
            self.reset_insertion_mode();
        }
        Ok(())
    }

    // ---- InForeignContentPhase -------------------------------------------

    fn foreign_start_tag(&mut self, t: &mut StartTag) -> Res<bool> {
        let current = self.last_open()?;
        let breakout = BREAKOUT_ELEMENTS.contains(&t.name.as_str())
            || (t.name == "font" && {
                let d = t.data.borrow();
                d.contains_plain("color") || d.contains_plain("face") || d.contains_plain("size")
            });
        if breakout {
            loop {
                let last = self.last_open()?;
                if self.dom.ns(last) != HTML
                    && !self.is_html_integration_point(last)
                    && !self.is_mathml_text_integration_point(last)
                {
                    self.pop()?;
                } else {
                    break;
                }
            }
            return Ok(true);
        }
        let current_ns = self.dom.ns(current);
        if current_ns == MATHML {
            self.adjust_mathml_attributes(t);
        } else if current_ns == SVG {
            if let Some(&(_, r)) = SVG_TAG_REPLACEMENTS.iter().find(|(k, _)| *k == t.name) {
                t.name = r.to_string();
            }
            self.adjust_svg_attributes(t)?;
        }
        self.adjust_foreign_attributes(t)?;
        t.namespace = Some(current_ns);
        self.insert_element(t)?;
        if t.self_closing {
            self.pop()?;
            t.self_closing_acknowledged = true;
        }
        Ok(false)
    }

    fn foreign_end_tag(&mut self, name: &str) -> Res<bool> {
        let mut node_index = self.open.len() as isize - 1;
        let mut node = self.last_open()?;
        loop {
            if ascii_lower(self.name(node)) == name {
                if self.phase == Phase::InTableText {
                    self.flush_characters()?;
                    self.phase = self.table_text_original()?;
                }
                while self.pop()? != node {}
                return Ok(false);
            }
            node_index -= 1;
            node = self.open_at(node_index)?;
            if self.dom.ns(node) != HTML {
                continue;
            } else {
                return self.process_end_tag(self.phase, name);
            }
        }
    }
}
