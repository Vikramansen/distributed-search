#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  setup.sh  –  Bootstrap the SolrCloud cluster
#
#  Usage:
#    ./scripts/setup.sh
#
#  What it does:
#    1. Waits for all ZooKeeper nodes to be reachable (TCP echo ruok)
#    2. Waits for all Solr nodes to be live
#    3. Uploads the "products" configset to ZooKeeper via docker exec
#    4. Creates the "games" collection (2 shards, replication=2)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SOLR1="http://localhost:8983"
COLLECTION="games"
CONFIGSET="products"
SHARDS=2
REPLICATION=2

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

wait_solr() {
  local url="$1" label="$2" max="${3:-60}" i=0
  info "Waiting for $label ..."
  until curl -sf "$url" > /dev/null 2>&1; do
    i=$((i+1))
    [[ $i -ge $max ]] && error "Timed out waiting for $label"
    echo -n "."; sleep 2
  done
  echo ""; info "$label is up."
}

wait_zk() {
  # ZooKeeper responds to the 4-letter word "ruok" with "imok" over TCP
  local host="$1" port="${2:-2181}" label="$3" max="${4:-30}" i=0
  info "Waiting for ZooKeeper $label ($host:$port) ..."
  until (echo "ruok" | docker exec -i "$host" sh -c 'nc -w1 localhost 2181') 2>/dev/null | grep -q "imok"; do
    i=$((i+1))
    [[ $i -ge $max ]] && { warn "ZooKeeper $label TCP check timed out, continuing anyway."; return; }
    echo -n "."; sleep 2
  done
  echo ""; info "ZooKeeper $label is up."
}

# ── 1. ZooKeeper ─────────────────────────────────────────────────────────────
info "=== Phase 1: ZooKeeper Ensemble ==="
wait_zk "zoo1" 2181 "zoo1" 20
wait_zk "zoo2" 2181 "zoo2" 20
wait_zk "zoo3" 2181 "zoo3" 20

# ── 2. Solr nodes ─────────────────────────────────────────────────────────────
info "=== Phase 2: Solr Nodes ==="
wait_solr "$SOLR1/solr/admin/info/system?wt=json" "solr1 (8983)" 60
wait_solr "http://localhost:8984/solr/admin/info/system?wt=json" "solr2 (8984)" 60
wait_solr "http://localhost:8985/solr/admin/info/system?wt=json" "solr3 (8985)" 60

# ── 3. Upload configset ───────────────────────────────────────────────────────
info "=== Phase 3: Upload configset '$CONFIGSET' to ZooKeeper ==="

# Check if already exists
EXISTING=$(curl -s "$SOLR1/api/cluster/configs?wt=json" | grep -c "\"$CONFIGSET\"" || true)
if [[ $EXISTING -gt 0 ]]; then
  warn "Configset '$CONFIGSET' already exists, skipping upload."
else
  info "Using docker exec to upload configset via zkcli..."
  docker exec solr1 bash -c "
    /opt/solr/server/scripts/cloud-scripts/zkcli.sh \
      -zkhost zoo1:2181,zoo2:2181,zoo3:2181 \
      -cmd upconfig \
      -confname ${CONFIGSET} \
      -confdir /configsets/${CONFIGSET}/conf \
    && echo 'Configset uploaded OK'
  " || error "zkcli upload failed"
  info "Configset uploaded."
fi

# ── 4. Create collection ──────────────────────────────────────────────────────
info "=== Phase 4: Create collection '$COLLECTION' ==="

COLL_LIST=$(curl -s "$SOLR1/solr/admin/collections?action=LIST&wt=json")
EXISTING_COLL=$(echo "$COLL_LIST" | grep -c "\"$COLLECTION\"" || true)

if [[ $EXISTING_COLL -gt 0 ]]; then
  warn "Collection '$COLLECTION' already exists. Skipping."
else
  RESP=$(curl -s \
    "$SOLR1/solr/admin/collections?action=CREATE\
&name=${COLLECTION}\
&collection.configName=${CONFIGSET}\
&numShards=${SHARDS}\
&replicationFactor=${REPLICATION}\
&maxShardsPerNode=3\
&wt=json")
  STATUS=$(echo "$RESP" | grep -o '"status":[0-9]*' | head -1 | cut -d: -f2)
  if [[ "$STATUS" == "0" ]]; then
    info "Collection '$COLLECTION' created: $SHARDS shards x $REPLICATION replicas."
  else
    warn "Collection response: $RESP"
    error "Failed to create collection."
  fi
fi

# ── 5. Cluster status ─────────────────────────────────────────────────────────
info "=== Phase 5: Cluster Status ==="
CLUSTER=$(curl -s "$SOLR1/solr/admin/collections?action=CLUSTERSTATUS&wt=json")
echo "$CLUSTER" | grep -o '"live_nodes":\[[^]]*\]' | head -1 || true
echo ""
info "=== Setup complete! ==="
info "Solr Admin UI : $SOLR1/solr/#/"
info "Collection    : $SOLR1/solr/$COLLECTION/select?q=*:*&rows=0"
info "Next step     : ./scripts/index_data.sh"
