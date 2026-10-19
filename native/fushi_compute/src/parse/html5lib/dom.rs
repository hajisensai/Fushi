//! `dom.dart` 里解析器用得到的那部分节点语义（arena 表示）。

use std::cell::RefCell;
use std::rc::Rc;

use super::{ParseFailure, Res};

pub type NodeId = usize;

/// 元素的 `namespaceUri`。`TreeBuilder(true)` 下元素只会落在这三个命名空间。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ns {
    Html,
    MathMl,
    Svg,
}

impl Ns {
    pub fn uri(self) -> &'static str {
        match self {
            Ns::Html => "http://www.w3.org/1999/xhtml",
            Ns::MathMl => "http://www.w3.org/1998/Math/MathML",
            Ns::Svg => "http://www.w3.org/2000/svg",
        }
    }
}

/// `Node.attributes` 的键：`String` 或 `AttributeName`（只由 `adjustForeignAttributes`
/// 产生）。两类键互不相等。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AttrKey {
    Plain(String),
    Name {
        prefix: Option<&'static str>,
        name: &'static str,
        namespace: &'static str,
    },
}

impl AttrKey {
    /// `toString()`：`AttributeName` 是 `prefix:name` 或 `name`。
    pub fn label(&self) -> String {
        match self {
            AttrKey::Plain(s) => s.clone(),
            AttrKey::Name {
                prefix: Some(p),
                name,
                ..
            } => format!("{p}:{name}"),
            AttrKey::Name { name, .. } => (*name).to_string(),
        }
    }

    pub fn is_plain(&self, key: &str) -> bool {
        matches!(self, AttrKey::Plain(s) if s == key)
    }
}

/// `LinkedHashMap<Object, String>`：插入序；覆盖已有键时原位更新。
#[derive(Clone, Debug, Default)]
pub struct AttrMap {
    pub entries: Vec<(AttrKey, String)>,
}

impl AttrMap {
    fn position(&self, key: &AttrKey) -> Option<usize> {
        self.entries.iter().position(|(k, _)| k == key)
    }

    pub fn get_plain(&self, key: &str) -> Option<&str> {
        self.entries
            .iter()
            .find(|(k, _)| k.is_plain(key))
            .map(|(_, v)| v.as_str())
    }

    pub fn contains_plain(&self, key: &str) -> bool {
        self.entries.iter().any(|(k, _)| k.is_plain(key))
    }

    pub fn put_if_absent(&mut self, key: AttrKey, value: String) {
        if self.position(&key).is_none() {
            self.entries.push((key, value));
        }
    }

    /// `map[key] = value`。
    pub fn set(&mut self, key: AttrKey, value: String) {
        match self.position(&key) {
            Some(i) => self.entries[i].1 = value,
            None => self.entries.push((key, value)),
        }
    }

    pub fn remove(&mut self, key: &AttrKey) -> Option<String> {
        self.position(key).map(|i| self.entries.remove(i).1)
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// treebuilder.dart `_mapEquals` / parser.dart `isMatchingFormattingElement` 的属性比较。
    pub fn equals(&self, other: &AttrMap) -> bool {
        if self.len() != other.len() {
            return false;
        }
        self.entries
            .iter()
            .all(|(k, v)| other.position(k).is_some_and(|i| &other.entries[i].1 == v))
    }
}

/// 元素与创建它的 token 共享同一个属性表（`..attributes = token.data`）。
pub type Attrs = Rc<RefCell<AttrMap>>;

#[derive(Debug)]
pub enum NodeKind {
    Document,
    Doctype {
        name: String,
        public_id: Option<String>,
        system_id: Option<String>,
    },
    Comment(String),
    Text(String),
    Element {
        name: String,
        ns: Ns,
        attrs: Attrs,
    },
}

#[derive(Debug)]
pub struct Node {
    pub kind: NodeKind,
    /// `parentNode`：可能是陈旧的（`remove()` 不清它），见模块说明。
    pub parent: Option<NodeId>,
    pub children: Vec<NodeId>,
}

/// 整棵树（含已脱离文档的节点）；下标 0 是 Document。
#[derive(Debug)]
pub struct Dom {
    pub nodes: Vec<Node>,
}

fn range_error() -> ParseFailure {
    ParseFailure("RangeError")
}

impl Dom {
    pub(super) fn new() -> Dom {
        Dom {
            nodes: vec![Node {
                kind: NodeKind::Document,
                parent: None,
                children: Vec::new(),
            }],
        }
    }

    pub(super) fn add(&mut self, kind: NodeKind) -> NodeId {
        self.nodes.push(Node {
            kind,
            parent: None,
            children: Vec::new(),
        });
        self.nodes.len() - 1
    }

    pub(super) fn new_element(&mut self, name: String, ns: Ns, attrs: Attrs) -> NodeId {
        self.add(NodeKind::Element { name, ns, attrs })
    }

    /// 元素的 `localName`（非元素返回空串；解析器只对元素调用）。
    pub fn local_name(&self, id: NodeId) -> &str {
        match &self.nodes[id].kind {
            NodeKind::Element { name, .. } => name,
            _ => "",
        }
    }

    pub fn ns(&self, id: NodeId) -> Ns {
        match &self.nodes[id].kind {
            NodeKind::Element { ns, .. } => *ns,
            _ => Ns::Html,
        }
    }

    pub fn attrs(&self, id: NodeId) -> &Attrs {
        match &self.nodes[id].kind {
            NodeKind::Element { attrs, .. } => attrs,
            _ => unreachable!("attrs() on a non-element"),
        }
    }

    /// `Element.clone(false)`：同名同命名空间、属性表复制一份。
    pub(super) fn clone_element(&mut self, id: NodeId) -> NodeId {
        let (name, ns, attrs) = match &self.nodes[id].kind {
            NodeKind::Element { name, ns, attrs } => (
                name.clone(),
                *ns,
                Rc::new(RefCell::new(attrs.borrow().clone())),
            ),
            _ => unreachable!("clone_element() on a non-element"),
        };
        self.new_element(name, ns, attrs)
    }

    /// `Node.remove()`：`parentNode?.nodes.remove(this)`——摘掉父列表里的第一次出现，
    /// **不**清 `parentNode`。
    pub(super) fn detach(&mut self, id: NodeId) {
        if let Some(p) = self.nodes[id].parent {
            let list = &mut self.nodes[p].children;
            if let Some(i) = list.iter().position(|&c| c == id) {
                list.remove(i);
            }
        }
    }

    /// `parent.nodes.remove(node)`（`ListProxy.remove`：第一次出现，不动 `parentNode`）。
    pub(super) fn remove_child(&mut self, parent: NodeId, id: NodeId) {
        let list = &mut self.nodes[parent].children;
        if let Some(i) = list.iter().position(|&c| c == id) {
            list.remove(i);
        }
    }

    /// `NodeList._setParent`。
    fn set_parent(&mut self, id: NodeId, parent: NodeId) {
        self.detach(id);
        self.nodes[id].parent = Some(parent);
    }

    /// `parent.nodes.add(node)`。
    pub(super) fn append(&mut self, parent: NodeId, id: NodeId) {
        self.set_parent(id, parent);
        self.nodes[parent].children.push(id);
    }

    /// `parent.nodes.insert(index, node)`：下标已先算好，节点从旧父摘下后再按它插入。
    pub(super) fn insert_at(&mut self, parent: NodeId, index: isize, id: NodeId) -> Res<()> {
        self.set_parent(id, parent);
        let list = &mut self.nodes[parent].children;
        if index < 0 || index as usize > list.len() {
            return Err(range_error());
        }
        list.insert(index as usize, id);
        Ok(())
    }

    pub(super) fn index_of_child(&self, parent: NodeId, id: NodeId) -> isize {
        self.nodes[parent]
            .children
            .iter()
            .position(|&c| c == id)
            .map_or(-1, |i| i as isize)
    }

    /// `Node.insertBefore(node, refNode)`。
    pub(super) fn insert_before(
        &mut self,
        parent: NodeId,
        id: NodeId,
        before: Option<NodeId>,
    ) -> Res<()> {
        match before {
            None => {
                self.append(parent, id);
                Ok(())
            }
            Some(r) => {
                let index = self.index_of_child(parent, r);
                self.insert_at(parent, index, id)
            }
        }
    }

    /// `Node.reparentChildren(newParent)`：`newParent.nodes.addAll(nodes); nodes.clear()`。
    pub(super) fn reparent_children(&mut self, from: NodeId, to: NodeId) {
        let list = self.nodes[from].children.clone();
        for &n in list.iter().rev() {
            self.set_parent(n, to);
        }
        self.nodes[to].children.extend_from_slice(&list);
        let rest = std::mem::take(&mut self.nodes[from].children);
        for n in rest {
            self.nodes[n].parent = None;
        }
    }

    pub(super) fn is_text(&self, id: NodeId) -> bool {
        matches!(self.nodes[id].kind, NodeKind::Text(_))
    }

    pub(super) fn append_text_data(&mut self, id: NodeId, data: &str) {
        if let NodeKind::Text(t) = &mut self.nodes[id].kind {
            t.push_str(data);
        }
    }
}
