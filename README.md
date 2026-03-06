# distributed-search

a distributed video game search engine built on SolrCloud. shards data across multiple nodes, replicates for fault tolerance, and wraps everything in a FastAPI layer you can actually use.

i wanted to understand how search engines like solr and elasticsearch handle distributed queries under the hood — scatter/gather, shard routing, leader election, NRT indexing — so i built one from scratch with docker compose.

## how it works

```
                      you
                       |
                       v
              ┌────────────────┐
              │  FastAPI :8000  │   /search, /suggest, /similar, /facets
              └───────┬────────┘
                      |
           ┌──────────┼──────────┐
           v          v          v
       ┌───────┐  ┌───────┐  ┌───────┐
       │ solr1 │  │ solr2 │  │ solr3 │    SolrCloud cluster
       │ :8983 │  │ :8984 │  │ :8985 │    3 nodes
       └───┬───┘  └───┬───┘  └───┬───┘
           |          |          |
           └──────────┼──────────┘
                      |
           ┌──────────┼──────────┐
           v          v          v
       ┌───────┐  ┌───────┐  ┌───────┐
       │ zoo1  │  │ zoo2  │  │ zoo3  │    ZooKeeper ensemble
       │ :2181 │  │ :2182 │  │ :2183 │    quorum = 2
       └───────┘  └───────┘  └───────┘
```

when you search for "souls-like open world", the query hits any solr node. that node fans out to all shards (scatter), each shard scores its local docs, then results merge back (gather) and return ranked by relevance.

## shard layout

the `games` collection splits into **2 shards** with **replication factor 2**, so each shard lives on 2 different nodes. if a node dies, the replica takes over — no data loss.

```
  shard1                         shard2
  ┌─────────────────────┐       ┌─────────────────────┐
  │ leader  → solr1     │       │ leader  → solr2     │
  │ replica → solr2     │       │ replica → solr3     │
  └─────────────────────┘       └─────────────────────┘

  11 docs on solr1, 9 on solr2, 9 on solr3  (20 total, distributed)
```

## what the schema does

designed for a video game catalog. some highlights:

| field | type | why |
|---|---|---|
| `title` | `text_en` (stemmed) | boosted 3x in relevance scoring |
| `genre` | `string[]` | multi-value, facetable — filter by "RPG", "FPS" etc |
| `platform` | `string[]` | multi-value — PS5, PC, Switch, Xbox... |
| `metacritic_score` | `int` | range facets, sortable |
| `suggest` | `text_suggest` | EdgeNGram (2–15 chars) for autocomplete |
| `_text_` | catch-all | copyField from title + desc + genre + tags |

synonyms handle stuff like "FPS" → "first person shooter", "GTA" → "grand theft auto", "fromsoft" → "fromsoftware".

## quick start

you need docker desktop with ~3gb ram free.

```bash
# start the cluster (3 zookeeper + 3 solr + fastapi)
docker compose up -d

# wait ~30s for everything to initialize, then bootstrap
./scripts/setup.sh

# load 20 video games
./scripts/index_data.sh

# run the search tests
./scripts/test_search.sh
```

the api comes up at http://localhost:8000/docs (swagger ui) and solr admin is at http://localhost:8983/solr/#/

## demo

### full-text search

```bash
$ curl "localhost:8000/search?q=souls+like"
```
```json
{
  "total": 3,
  "results": [
    { "title": "Dark Souls III",          "metacritic_score": 89 },
    { "title": "Sekiro: Shadows Die Twice", "metacritic_score": 91 },
    { "title": "Elden Ring",              "metacritic_score": 96 }
  ],
  "facets": {
    "genre": { "Souls-like": 3, "Action RPG": 2, "Action-Adventure": 1 },
    "platform": { "PC": 3, "PS4": 3, "Xbox One": 3 }
  }
}
```

### filtered search — PS5 games on sale with 90+ metacritic

```bash
$ curl "localhost:8000/search?q=*&platform=PS5&min_score=90&on_sale=true&sort=metacritic_score+desc"
```
```
  mc=96  $39.99  Elden Ring
  mc=94  $39.99  God of War Ragnarök
  mc=93  $35.99  Resident Evil 4 Remake
  mc=93  $12.49  Hades
  mc=92  $35.99  Street Fighter 6
  mc=90  $49.99  Spider-Man 2
```

### autocomplete

```bash
$ curl "localhost:8000/suggest?q=El"    →  ["Elden Ring"]
$ curl "localhost:8000/suggest?q=Star"  →  ["Stardew Valley", "Starfield"]
$ curl "localhost:8000/suggest?q=Re"    →  ["Red Dead Redemption 2", "Resident Evil 4 Remake"]
```

### similar games (more-like-this)

```bash
$ curl "localhost:8000/similar/game-001"   # elden ring
```
```
  Dark Souls III           mc=89
  Sekiro: Shadows Die Twice mc=91
  Cyberpunk 2077           mc=86
  Red Dead Redemption 2    mc=97
  God of War Ragnarök      mc=94
  Baldur's Gate 3          mc=96
```

### facet browsing

```bash
$ curl "localhost:8000/facets"
```
```
  genre:       Action-Adventure(8)  Open World(6)  Action RPG(5)  Souls-like(3)
  platform:    PC(18)  PS4(14)  PS5(12)  Xbox One(11)  Xbox Series X(10)
  esrb_rating: M(12)  T(4)  E10+(3)  E(1)
  release_year: 2023(8)  2022(3)  2020(2)  2017(2)  2016(2)
```

### distributed query routing

each node only holds a subset of docs (shards), but every node can answer a full query by fanning out:

```bash
$ curl "localhost:8983/solr/games/select?q=*:*&rows=0"   →  20 hits (distributed)
$ curl "localhost:8983/solr/games/select?q=*:*&rows=0&distrib=false"  →  11 hits (local shard only)
$ curl "localhost:8984/solr/games/select?q=*:*&rows=0&distrib=false"  →  9 hits
$ curl "localhost:8985/solr/games/select?q=*:*&rows=0&distrib=false"  →  9 hits
```

## api reference

| endpoint | description | example |
|---|---|---|
| `GET /search` | full-text search with filters, facets, highlighting | `?q=RPG&platform=PS5&min_score=80` |
| `GET /suggest` | autocomplete prefix matching | `?q=Eld` |
| `GET /similar/:id` | more-like-this recommendations | `/similar/game-001` |
| `GET /facets` | facet counts for browse/filter UI | `?q=*` |
| `GET /game/:id` | fetch single game | `/game/game-006` |
| `GET /health` | cluster health + doc count | — |

search supports these filters: `genre`, `platform`, `esrb`, `on_sale`, `multiplayer`, `min_score`, `max_price`, `year_from`, `year_to`

## what i learned building this

- **SolrCloud's scatter-gather** is clean but the suggest component doesn't love distributed mode — had to build the suggester per-core with `distrib=false`
- **ZooKeeper quorum math**: 3 nodes = survives 1 failure (quorum = 2). 5 nodes = survives 2. always odd numbers.
- **eDisMax** is the way to go for user-facing search — field boosts (`title^3 developer^2`), phrase boosts, minimum-should-match all configurable
- **EdgeNGram** at index time + normal tokenization at query time = fast prefix autocomplete without wildcard queries
- **NRT (near-real-time)**: soft commits every 1s give you sub-second search visibility without the cost of a full hard commit
- the gap between "my data is in solr" and "my search is actually good" is entirely in the schema design and request handler config

## project structure

```
distributed-search/
├── docker-compose.yml           # the whole cluster
├── solr/configsets/products/
│   └── conf/
│       ├── managed-schema.xml   # fields, types, copy fields
│       ├── solrconfig.xml       # request handlers, caches, suggest
│       └── lang/
│           ├── stopwords_en.txt
│           └── synonyms.txt     # fps = first person shooter, etc
├── data/
│   └── games.json               # 20 video games
├── scripts/
│   ├── setup.sh                 # bootstrap cluster
│   ├── index_data.sh            # load docs
│   ├── test_search.sh           # query test suite
│   └── test_api.py              # fastapi smoke test
├── api/
│   ├── main.py                  # fastapi app
│   ├── requirements.txt
│   └── Dockerfile
└── README.md
```

## teardown

```bash
docker compose down        # stop, keep data
docker compose down -v     # nuke everything
```
