#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  index_data.sh  –  Index video game documents into SolrCloud
#
#  Usage:
#    ./scripts/index_data.sh [--solr URL] [--collection NAME] [--data FILE]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SOLR_URL="http://localhost:8983/solr"
COLLECTION="games"
DATA_FILE="$(dirname "$0")/../data/games.json"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --solr)       SOLR_URL="$2";       shift 2 ;;
    --collection) COLLECTION="$2";    shift 2 ;;
    --data)       DATA_FILE="$2";     shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

DATA_FILE="$(realpath "$DATA_FILE")"
[[ -f "$DATA_FILE" ]] || error "Data file not found: $DATA_FILE"

# ── Count documents ──────────────────────────────────────────────────────
DOC_COUNT=$(python3 -c "import json; d=json.load(open('$DATA_FILE')); print(len(d))")
info "Indexing $DOC_COUNT documents from: $DATA_FILE"
info "Target: $SOLR_URL/$COLLECTION"

# ── POST documents ────────────────────────────────────────────────────────
HTTP_CODE=$(curl -s -o /tmp/index_response.json -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  --data-binary "@$DATA_FILE" \
  "$SOLR_URL/$COLLECTION/update/json/docs?commit=true")

if [[ "$HTTP_CODE" == "200" ]]; then
  info "Index successful (HTTP 200)."
else
  warn "HTTP $HTTP_CODE from Solr:"
  cat /tmp/index_response.json
  error "Indexing failed."
fi

# ── Verify count ──────────────────────────────────────────────────────────
sleep 1
COUNT_RESP=$(curl -s "$SOLR_URL/$COLLECTION/select?q=*:*&rows=0&wt=json")
INDEXED=$(echo "$COUNT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['response']['numFound'])")
info "Documents now in '$COLLECTION': $INDEXED"

# ── Print shard distribution ──────────────────────────────────────────────
info "Shard distribution:"
for PORT in 8983 8984 8985; do
  NODE_COUNT=$(curl -s "http://localhost:$PORT/solr/$COLLECTION/select?q=*:*&rows=0&distrib=false&wt=json" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['response']['numFound'])" 2>/dev/null || echo "N/A")
  info "  solr (port $PORT): $NODE_COUNT docs (local shards only)"
done

info "Done. Run ./scripts/test_search.sh to verify queries."
