"""Quick smoke-test for the FastAPI search endpoints."""
import urllib.request
import urllib.parse
import json, sys

BASE = "http://localhost:8000"

def get(path):
    with urllib.request.urlopen(BASE + path, timeout=10) as r:
        return json.load(r)

def section(title):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print('='*60)

# ── /health ───────────────────────────────────────────────────
section("GET /health")
h = get("/health")
print(f"  status         : {h['status']}")
print(f"  live Solr nodes: {h['solr_live_nodes']}")
print(f"  collection     : {h['collection']}")
print(f"  total docs     : {h['total_docs']}")

# ── /search ───────────────────────────────────────────────────
section("GET /search?q=souls+like&facets=true")
d = get("/search?q=souls+like&facets=true")
print(f"  Total hits: {d['total']}")
for r in d['results']:
    print(f"    {r['id']:12} mc={str(r.get('metacritic_score','')):3}  {r['title']}")
print(f"  Facets (genre): {dict(list(d['facets'].get('genre',{}).items())[:4])}")

section("GET /search  [PS5 + score>=90 + on_sale]")
d = get("/search?q=*&platform=PS5&min_score=90&on_sale=true&sort=metacritic_score+desc&facets=false")
print(f"  Total hits: {d['total']}")
for r in d['results']:
    print(f"    mc={r.get('metacritic_score',''):3}  ${r.get('sale_price',''):5}  {r['title']}")

# ── /suggest ──────────────────────────────────────────────────
section("GET /suggest?q=Eld")
s = get("/suggest?q=Eld")
print(f"  Suggestions: {s['suggestions']}")

section("GET /suggest?q=Dark")
s = get("/suggest?q=Dark")
print(f"  Suggestions: {s['suggestions']}")

# ── /similar ──────────────────────────────────────────────────
section("GET /similar/game-001  (Elden Ring)")
m = get("/similar/game-001")
print(f"  Source: {m['source_id']}")
for r in m['similar']:
    print(f"    {r['id']:12} mc={str(r.get('metacritic_score','')):3}  {r['title']}")

# ── /facets ───────────────────────────────────────────────────
section("GET /facets")
f = get("/facets")
for k, v in f['facets'].items():
    if isinstance(v, dict) and v:
        preview = dict(list(v.items())[:5])
        print(f"  {k:25}: {preview}")

# ── /game/:id ─────────────────────────────────────────────────
section("GET /game/game-006  (Baldur's Gate 3)")
g = get("/game/game-006")
print(f"  Title      : {g['title']}")
print(f"  Developer  : {g['developer']}")
print(f"  Genre      : {g['genre']}")
print(f"  Platforms  : {g['platform']}")
print(f"  Metacritic : {g['metacritic_score']}")
print(f"  Price      : ${g['price']}")
print(f"  Multiplayer: {g['multiplayer']}")

print("\n" + "="*60)
print("  All endpoints OK")
print("="*60)
print(f"\n  Swagger UI  : {BASE}/docs")
print(f"  Solr Admin  : http://localhost:8983/solr/#/")
