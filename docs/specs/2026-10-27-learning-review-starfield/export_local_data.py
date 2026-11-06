"""从本机 Fushi 数据（SRS 牌组 + 主库）重建全量制卡历史 → 同目录 data.js（不入库）。

只取自己制的卡：挖词笔记类型（带 fushi / hibiki 标签最多的那一类），
预制牌组（JLPT10k、Kaishi、おにぎり文法、Basic 等）不算。

用法：python export_local_data.py --data-root "<Fushi 数据根目录>"
（数据根下应有 support/fushi.db 与 support/srs.db；app 运行中也可读，走只读 backup。）
依赖：Pillow。
"""
import sys; sys.stdout.reconfigure(encoding="utf-8")
import argparse, sqlite3, os, re, json, html, base64, io, collections
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote_plus
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument('--data-root', required=True, help='Fushi 数据根目录（含 support/）')
args = ap.parse_args()
# 输出固定写在脚本旁（.gitignore 已排除），不接受外部路径。
OUT = os.path.join(HERE, 'data.js')
SUPPORT = Path(args.data_root).resolve() / 'support'
if not SUPPORT.is_dir():
    sys.exit(f'找不到 {SUPPORT}：--data-root 应指向 Fushi 数据根目录')

def snapshot(name: str) -> sqlite3.Connection:
    """只读打开 support/<name> 并整库拷进内存：不锁正在运行的 app，WAL 里未合并的页也带上。

    库名只取固定白名单；URI 由 Path.as_uri() 生成（路径里的 ? # % 等被转义），
    外部输入拼不进 URI 参数。
    """
    if name not in ('srs.db', 'fushi.db'):
        raise ValueError(name)
    db = SUPPORT / name
    if not db.is_file():
        sys.exit(f'找不到 {db}')
    src = sqlite3.connect(db.as_uri() + '?mode=ro', uri=True)
    mem = sqlite3.connect(':memory:')
    src.backup(mem)
    src.close()
    return mem

srs = snapshot('srs.db')
app = snapshot('fushi.db')
Q = lambda c, s, a=(): c.execute(s, a).fetchall()
KINDS = ('video', 'book', 'manga', 'game', 'music', 'audiobook', 'lyrics')

def detect_mining_note_type() -> str:
    score = collections.Counter()
    for nt, tags in Q(srs, 'select note_type_id, tags_json from srs_notes_cache where deleted_at is null'):
        t = json.loads(tags or '[]')
        if 'fushi' in t or 'hibiki' in t:
            score[nt] += 1
    if not score:
        sys.exit('没找到带 fushi / hibiki 标签的挖词笔记')
    return score.most_common(1)[0][0]

NT = detect_mining_note_type()

# 字段定义 id → 名字（取最后一次改名）
defname = {}
for fk, js in Q(srs, "select field_key, json from srs_field_edits where entity_kind='notetype' and field_key like 'fieldDef/%' order by seq"):
    v = json.loads(js).get('v') or {}
    if isinstance(v, dict) and v.get('name'):
        defname[fk.split('/', 1)[1]] = v['name']

TAG_RE = re.compile(r'<[^>]+>')
def text(v) -> str:
    return html.unescape(TAG_RE.sub('', str(v or ''))).strip()

_edits = collections.defaultdict(list)
for eid, fk, js in Q(srs, "select entity_id, field_key, json from srs_field_edits where entity_kind='note' order by seq"):
    _edits[eid].append((fk, js))

def fields_of(nid: str) -> dict:
    out = {}
    for fk, js in _edits.get(nid, ()):
        v = json.loads(js).get('v')
        name = defname.get(fk[2:], fk[2:]) if fk.startswith('f/') else fk
        if v not in (None, '') or name not in out:
            out[name] = v
    return out

def ms(h, m, s) -> int:
    return (int(h) * 3600 + int(m) * 60 + int(s)) * 1000

EP_RE = re.compile(r'\s*-\s*S(\d+)E(\d+)\s*$', re.I)
YEAR_RE = re.compile(r'\s*\((\d{4})\)\s*$')
TIME_RE = re.compile(r'(\d{1,2}):(\d{2}):(\d{2})')

def parse_link(misc: str) -> dict | None:
    m = re.search(r'href="(fushi://source\?[^"]+)"', misc or '')
    if not m:
        return None
    qs = parse_qs(urlparse(html.unescape(m.group(1))).query)
    return {k: unquote_plus(v[0]) for k, v in qs.items()}

# 视频库：uid → (路径, 封面)；书库：bookKey/uid → (标题, 封面)
videos = {u: (p, cv) for u, p, cv in Q(app, 'select book_uid, video_path, cover_path from video_books')}
ecols = [r[1] for r in Q(app, 'pragma table_info(epub_books)')]
books = {}
for row in Q(app, 'select * from epub_books'):
    r = dict(zip(ecols, row))
    for k in ('uid', 'book_key', 'title'):
        if r.get(k): books[r[k]] = r

def clean_title(t: str) -> str:
    t = t.replace('_', ' ')
    t = re.sub(r'\s*播放列表$', '', t)
    t = re.sub(r'\s+\d{1,2}:\d{2}:\d{2}.*$', '', t)
    t = YEAR_RE.sub('', EP_RE.sub('', t)).strip()
    return t

def series_from_path(vp: str | None) -> str | None:
    if not vp: return None
    d = os.path.dirname(vp)
    if re.match(r'(?i)^(season|s)\s*\d+$', os.path.basename(d)): d = os.path.dirname(d)
    return os.path.basename(d) or None

watch = Q(app, "select timestamp_ms, duration_ms, media_key from activity_events where media_type='video' and event_type!='added' and media_key is not null")
notes = Q(srs, "select id, tags_json, created_at from srs_notes_cache where note_type_id=? and deleted_at is null order by created_at", (NT,))
stab = {n: (s, r) for n, s, r in Q(srs, 'select note_id, max(stability), max(reps) from srs_cards_cache group by note_id')}

works, cards = {}, []
unresolved = collections.Counter()
for nid, tags_json, created in notes:
    tags = json.loads(tags_json or '[]')
    f = fields_of(nid)
    word = text(f.get('Expression'))
    if not word:
        continue
    misc_raw = str(f.get('MiscInfo') or '')
    misc = text(misc_raw)
    link = parse_link(misc_raw)
    src = f.get('source') if isinstance(f.get('source'), dict) else None
    kind = (link or {}).get('kind') or (src or {}).get('kind') or next((t for t in tags if t in KINDS), None)
    uid = (link or {}).get('uid')
    start = (link or {}).get('startMs') or (src or {}).get('startMs')
    title = None; ep = None
    if uid and uid.startswith('video/'):
        base = uid.split('/', 1)[1]
        mm = EP_RE.search(base)
        if mm: ep = f'S{int(mm.group(1)):02d}E{int(mm.group(2)):02d}'
        title = YEAR_RE.sub('', EP_RE.sub('', base)).strip()
        if not title or EP_RE.match(' - ' + base):
            title = series_from_path(videos.get(uid, (None, None))[0]) or title
    elif link and link.get('bookKey') and not link['bookKey'].startswith('interconnect-'):
        title = link['bookKey']
    elif src and src.get('title'):
        title = YEAR_RE.sub('', EP_RE.sub('', src['title'])).strip()
    if not title:
        # 旧格式 MiscInfo：「作品 (年) - 集名 00:05:39 - 00:05:41」或书名
        head = misc.split(' - ')[0] if misc else ''
        series_tag = next((t for t in tags if re.search(r'_\(\d{4}\)$', t)), None)
        cand = head or (series_tag or '').replace('_', ' ')
        if not cand:
            cand = next((t.replace('_', ' ') for t in tags if t not in KINDS and t not in ('fushi', 'hibiki')), '')
        title = YEAR_RE.sub('', EP_RE.sub('', cand)).strip() or '（无出处）'
    if start is None:
        tm = TIME_RE.search(misc)
        if tm: start = ms(*tm.groups())
    if not kind:
        kind = 'video' if TIME_RE.search(misc) else 'book'
        unresolved[kind] += 1
    loc = []
    if ep: loc.append(ep)
    if start is not None:
        s = int(start) // 1000; loc.append(f'{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}' if s >= 3600 else f'{s // 60}:{s % 60:02d}')
    if link and (link.get('bookKey') or '').startswith(('mihon-', 'interconnect-')):
        am = re.search(r'>([^<]+)</a>', misc_raw)
        if am: title = html.unescape(am.group(1))
    if re.fullmatch(r'S\d+E\d+', (title or '').strip()) and kind == 'video':
        # 只剩集号：按制卡时刻落在哪段观看会话里反推作品
        hit = next((mk for ts, dur, mk in watch if ts - (dur or 0) - 600_000 <= int(created) <= ts + 600_000), None)
        if hit:
            if not ep: ep = title.strip()
            title = hit.split('/', 1)[-1]
    title = clean_title(title) or '（无出处）'
    if re.fullmatch(r'S\d+E\d+', title):
        if not ep: ep = title
        title = '出处不明（卡上只记了集号）'
    L = link or {}
    if kind in ('book', 'manga') and start is not None and 'chapterIndex' in L:
        loc = []  # 书的 startMs 是有声书对齐时间，位置以章节+字偏移为准
    if 'chapterIndex' in L: loc.append(f'第 {int(L["chapterIndex"]) + 1} 章 · 第 {L.get("charOffset", "?")} 字')
    if 'pageIndex' in L: loc.append(f'p.{int(L["pageIndex"]) + 1}')
    key = (kind, title)
    w = works.get(key)
    if w is None:
        w = works[key] = {'id': len(works), 'title': title, 'kind': kind, 'n': 0, 'uid': None}
    w['n'] += 1
    if uid and not w['uid']: w['uid'] = uid
    st, reps = stab.get(nid, (None, 0))
    cards.append({'w': w['id'], 'word': word, 'reading': text(f.get('ExpressionReading')),
                  'loc': ' '.join(loc), 'ep': misc[:80] if not link else '', 'sent': text(f.get('Sentence')),
                  't': int(created), 'stab': st, 'reps': reps or 0})

def find_poster(w):
    if w['title'].startswith('出处不明') or w['title'] == '（无出处）':
        return None
    vp = None
    if w['uid'] and w['uid'] in videos:
        vp, cover = videos[w['uid']]
    else:
        cover = None
        for u, (p, cv) in videos.items():
            if w['title'] and w['title'] in u:
                vp, cover = p, cv; break
    if vp:
        d = os.path.dirname(vp)
        for _ in range(3):
            for n in ('poster.jpg', 'poster.png', 'folder.jpg', 'cover.jpg'):
                if os.path.isfile(os.path.join(d, n)): return os.path.join(d, n)
            d = os.path.dirname(d)
    if cover and os.path.isfile(cover): return cover
    b = books.get(w['title']) or next((r for t, r in books.items() if isinstance(t, str) and w['title'] and (t.startswith(w['title']) or w['title'].startswith(t)) and len(t) > 2), None)
    if b and b.get('cover_path'):
        for base in (b.get('extract_dir') or '', ''):
            p = os.path.join(base, b['cover_path'])
            if os.path.isfile(p): return p
    return None

def encode(path):
    im = Image.open(path).convert('RGB'); W, H = 320, 480
    r = max(W / im.width, H / im.height); im = im.resize((round(im.width * r), round(im.height * r)), Image.LANCZOS)
    l, t = (im.width - W) // 2, (im.height - H) // 2; im = im.crop((l, t, l + W, t + H))
    buf = io.BytesIO(); im.save(buf, 'JPEG', quality=80)
    return 'data:image/jpeg;base64,' + base64.b64encode(buf.getvalue()).decode()

out_works = []
for w in sorted(works.values(), key=lambda x: x['id']):
    p = find_poster(w)
    out_works.append({'id': w['id'], 'title': w['title'], 'kind': w['kind'], 'n': w['n'], 'img': encode(p) if p else None})
for w in sorted(out_works, key=lambda x: -x['n']):
    print(f"{w['n']:4d} {w['kind']:6s} {'img ' if w['img'] else '--- '}{w['title']}")
print('cards', len(cards), 'works', len(out_works), 'kind guessed', dict(unresolved))
with open(OUT, 'w', encoding='utf-8') as fh:
    fh.write('window.STARFIELD_DATA=' + json.dumps({'works': out_works, 'cards': cards, 'source': 'srs'}, ensure_ascii=False) + ';')
