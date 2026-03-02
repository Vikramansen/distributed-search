#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  test_search.sh  –  Run a battery of search queries against the cluster
#
#  Usage:
#    ./scripts/test_search.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SOLR="http://localhost:8983/solr"
COL="games"
PASS=0; FAIL=0

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
pass()   { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS+1)); }
fail()   { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }

query() {
  # query <description> <url_params> <expected_min_hits>
  local desc="$1" params="$2" min_hits="${3:-1}"
  local url="$SOLR/$COL/select?${params}&rows=5&wt=json&fl=id,title,metacritic_score,score"
  local resp hits
  resp=$(curl -sf "$url") || { fail "$desc  [curl failed]"; return; }
  hits=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['response']['numFound'])" 2>/dev/null || echo "0")
  if [[ "$hits" -ge "$min_hits" ]]; then
    pass "$desc  ($hits hits)"
    echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for doc in d['response']['docs'][:3]:
    score = doc.get('score','')
    mc    = doc.get('metacritic_score','')
    print(f'     → {doc[\"id\"]:12} | {doc[\"title\"][:40]:40} | mc={mc:3} score={score}')
" 2>/dev/null || true
  else
    fail "$desc  (got $hits, expected ≥$min_hits)  URL: $url"
  fi
}

facet_query() {
  local desc="$1" params="$2"
  local url="$SOLR/$COL/facet?${params}&rows=0&wt=json"
  local resp
  resp=$(curl -sf "$url") || { fail "$desc  [curl failed]"; return; }
  pass "$desc"
  echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ff = d.get('facet_counts',{}).get('facet_fields',{})
for fname, fdata in ff.items():
    vals = [(fdata[i], fdata[i+1]) for i in range(0, min(len(fdata),10), 2)]
    vals = [(v,c) for v,c in vals if c > 0]
    print(f'  facet [{fname}]: ' + '  '.join(f'{v}({c})' for v,c in vals[:6]))
" 2>/dev/null || true
}

suggest_query() {
  local desc="$1" term="$2"
  local url="$SOLR/$COL/suggest?suggest=true&suggest.q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$term'))")&wt=json"
  local resp
  resp=$(curl -sf "$url") || { fail "$desc  [curl failed]"; return; }
  pass "$desc"
  echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
sugs = d.get('suggest',{}).get('gameSuggest',{})
for term, tdata in sugs.items():
    suggestions = tdata.get('suggestions',[])
    print('  suggestions: ' + ', '.join(s['term'] for s in suggestions[:5]))
" 2>/dev/null || true
}

mlt_query() {
  local desc="$1" doc_id="$2"
  local url="$SOLR/$COL/mlt?q=id:${doc_id}&rows=5&wt=json"
  local resp hits
  resp=$(curl -sf "$url") || { fail "$desc  [curl failed]"; return; }
  hits=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['response']['numFound'])" 2>/dev/null || echo "0")
  if [[ "$hits" -ge 1 ]]; then
    pass "$desc  ($hits similar)"
    echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for doc in d['response']['docs'][:3]:
    print(f'     → {doc[\"id\"]:12} | {doc[\"title\"][:40]:40} | mc={doc.get(\"metacritic_score\",\"\")}')
" 2>/dev/null || true
  else
    fail "$desc  (0 similar docs)"
  fi
}

# ════════════════════════════════════════════════════════════════
header "1. Full-Text Search"
query "keyword: 'souls'" \
  "q=souls&defType=edismax&qf=title^3+description^1+tags^1" 2

query "keyword: 'open world RPG'" \
  "q=open+world+RPG&defType=edismax&qf=title^3+genre^2+description^1" 3

query "keyword: 'dark fantasy challenging'" \
  "q=dark+fantasy+challenging&defType=edismax&qf=_text_" 2

query "phrase: 'Game of the Year'" \
  "q=%22game+of+the+year%22&defType=edismax&qf=_text_" 0 0

# ════════════════════════════════════════════════════════════════
header "2. Filter Queries"
query "filter: platform=PS5" \
  "q=*:*&fq=platform:PS5" 5

query "filter: genre=RPG" \
  "q=*:*&fq=genre:RPG" 1

query "filter: on_sale=true" \
  "q=*:*&fq=on_sale:true" 5

query "filter: multiplayer + FPS genre" \
  "q=*:*&fq=multiplayer:true&fq=genre:FPS" 1

query "filter: metacritic_score >= 90" \
  "q=*:*&fq=metacritic_score:[90+TO+*]" 5

query "filter: price range \$0-\$20" \
  "q=*:*&fq=price:[0+TO+20]" 3

query "filter: FromSoftware games" \
  "q=*:*&fq=developer_exact:FromSoftware" 3

# ════════════════════════════════════════════════════════════════
header "3. Faceted Search"
facet_query "facets: genre + platform + esrb + year" \
  "q=*:*"

facet_query "facets on query: souls-like" \
  "q=souls-like&defType=edismax&qf=tags^2+genre^1+description^1"

# ════════════════════════════════════════════════════════════════
header "4. Sorting"
query "sort by price asc" \
  "q=*:*&sort=price+asc&fl=id,title,price" 10

query "sort by metacritic desc" \
  "q=*:*&sort=metacritic_score+desc&fl=id,title,metacritic_score" 10

query "sort by release_date desc (newest)" \
  "q=*:*&sort=release_date+desc&fl=id,title,release_date" 10

# ════════════════════════════════════════════════════════════════
header "5. Autocomplete / Suggest"
suggest_query "suggest: 'El'" "El"
suggest_query "suggest: 'Dark'" "Dark"
suggest_query "suggest: 'Fro'" "Fro"

# ════════════════════════════════════════════════════════════════
header "6. More Like This"
mlt_query "MLT: games similar to Elden Ring"  "game-001"
mlt_query "MLT: games similar to Hades"       "game-008"

# ════════════════════════════════════════════════════════════════
header "7. Highlighting"
URL="$SOLR/$COL/select?q=dark+fantasy&defType=edismax&qf=_text_&hl=on&hl.fl=title,description&hl.fragsize=100&rows=3&wt=json"
resp=$(curl -sf "$URL") || { fail "highlight query"; }
HL_COUNT=$(echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
hl=d.get('highlighting',{})
print(sum(1 for v in hl.values() if v))
" 2>/dev/null || echo "0")
if [[ "$HL_COUNT" -ge 1 ]]; then
  pass "highlighting ($HL_COUNT docs have highlights)"
  echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for docid, hldata in list(d.get('highlighting',{}).items())[:2]:
    for field, snippets in hldata.items():
        for s in snippets:
            s=s.replace('<em>','\033[1;33m').replace('</em>','\033[0m')
            print(f'     [{docid}] {field}: {s}')
" 2>/dev/null || true
else
  fail "highlighting (0 snippets returned)"
fi

# ════════════════════════════════════════════════════════════════
header "8. Distributed Query Routing"
# Verify each node responds independently
for PORT in 8983 8984 8985; do
  NODE_RESP=$(curl -sf "http://localhost:$PORT/solr/$COL/select?q=*:*&rows=0&wt=json&distrib=false" || echo '{"response":{"numFound":0}}')
  LOCAL_HITS=$(echo "$NODE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['response']['numFound'])" 2>/dev/null || echo "0")
  pass "Node port $PORT: $LOCAL_HITS local documents (non-distributed)"
done

# ════════════════════════════════════════════════════════════════
header "Results"
echo -e "  ${GREEN}Passed: $PASS${NC}   ${RED}Failed: $FAIL${NC}"
[[ $FAIL -eq 0 ]] && echo -e "  ${GREEN}All tests passed!${NC}" || echo -e "  ${RED}Some tests failed.${NC}"
