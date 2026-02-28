"""
Video Game Search API — wraps SolrCloud with a nice REST layer.

Routes:
  /search       full-text + filters + facets + highlighting
  /suggest      autocomplete
  /similar/:id  "more like this"
  /facets       browse facet counts
  /game/:id     single doc lookup
  /health       cluster status
"""

from __future__ import annotations

import os
import urllib.parse
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# ── Config ────────────────────────────────────────────────────────────────────
SOLR_URL   = os.getenv("SOLR_URL",        "http://localhost:8983/solr")
COLLECTION = os.getenv("SOLR_COLLECTION", "games")
PORT       = int(os.getenv("PORT",        "8000"))

BASE = f"{SOLR_URL}/{COLLECTION}"

# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Video Game Search API",
    description="Distributed SolrCloud-backed video game search engine",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)

# ── Pydantic Models ───────────────────────────────────────────────────────────

class GameDoc(BaseModel):
    id: str
    title: str
    developer: str | None = None
    publisher: str | None = None
    genre: list[str] = Field(default_factory=list)
    platform: list[str] = Field(default_factory=list)
    price: float | None = None
    sale_price: float | None = None
    metacritic_score: int | None = None
    user_score: float | None = None
    esrb_rating: str | None = None
    release_date: str | None = None
    multiplayer: bool | None = None
    on_sale: bool | None = None
    featured: bool | None = None
    score: float | None = None


class SearchResponse(BaseModel):
    query: str
    total: int
    rows: int
    start: int
    results: list[GameDoc]
    facets: dict[str, Any] = Field(default_factory=dict)
    highlights: dict[str, Any] = Field(default_factory=dict)
    spellcheck: dict[str, Any] = Field(default_factory=dict)


class SuggestResponse(BaseModel):
    query: str
    suggestions: list[str]


class SimilarResponse(BaseModel):
    source_id: str
    similar: list[GameDoc]


class FacetResponse(BaseModel):
    facets: dict[str, Any]


class HealthResponse(BaseModel):
    status: str
    solr_live_nodes: int
    collection: str
    total_docs: int


# ── Helpers ───────────────────────────────────────────────────────────────────

def _build_filter_queries(
    genre: list[str] | None,
    platform: list[str] | None,
    esrb: str | None,
    on_sale: bool | None,
    multiplayer: bool | None,
    min_score: int | None,
    max_price: float | None,
    year_from: int | None,
    year_to: int | None,
) -> list[str]:
    fqs: list[str] = []
    if genre:
        fqs.append("genre:(" + " OR ".join(f'"{g}"' for g in genre) + ")")
    if platform:
        fqs.append("platform:(" + " OR ".join(f'"{p}"' for p in platform) + ")")
    if esrb:
        fqs.append(f'esrb_rating:"{esrb}"')
    if on_sale is not None:
        fqs.append(f"on_sale:{str(on_sale).lower()}")
    if multiplayer is not None:
        fqs.append(f"multiplayer:{str(multiplayer).lower()}")
    if min_score is not None:
        fqs.append(f"metacritic_score:[{min_score} TO *]")
    if max_price is not None:
        fqs.append(f"price:[* TO {max_price}]")
    if year_from or year_to:
        y0 = year_from or "*"
        y1 = year_to or "*"
        fqs.append(f"release_year:[{y0} TO {y1}]")
    return fqs


def _parse_game(doc: dict) -> GameDoc:
    return GameDoc(
        id=doc.get("id", ""),
        title=doc.get("title", ""),
        developer=doc.get("developer"),
        publisher=doc.get("publisher"),
        genre=doc.get("genre", []),
        platform=doc.get("platform", []),
        price=doc.get("price"),
        sale_price=doc.get("sale_price"),
        metacritic_score=doc.get("metacritic_score"),
        user_score=doc.get("user_score"),
        esrb_rating=doc.get("esrb_rating"),
        release_date=doc.get("release_date"),
        multiplayer=doc.get("multiplayer"),
        on_sale=doc.get("on_sale"),
        featured=doc.get("featured"),
        score=doc.get("score"),
    )


async def _solr_get(params: dict) -> dict:
    params.setdefault("wt", "json")
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(f"{BASE}/select", params=params)
    if resp.status_code != 200:
        raise HTTPException(502, f"Solr error {resp.status_code}: {resp.text[:300]}")
    return resp.json()


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.get("/search", response_model=SearchResponse, summary="Full-text game search")
async def search(
    q: str = Query("*:*", description="Search query (e.g. 'souls-like open world')"),
    rows: int = Query(20, ge=1, le=100, description="Results per page"),
    start: int = Query(0, ge=0, description="Pagination offset"),
    sort: str = Query("score desc", description="Sort field and direction"),
    genre: list[str] | None = Query(None, description="Filter by genre(s)"),
    platform: list[str] | None = Query(None, description="Filter by platform(s)"),
    esrb: str | None = Query(None, description="Filter by ESRB rating"),
    on_sale: bool | None = Query(None, description="Only on-sale games"),
    multiplayer: bool | None = Query(None, description="Only multiplayer games"),
    min_score: int | None = Query(None, ge=0, le=100, description="Minimum Metacritic score"),
    max_price: float | None = Query(None, ge=0, description="Maximum price"),
    year_from: int | None = Query(None, description="Release year from"),
    year_to: int | None = Query(None, description="Release year to"),
    facets: bool = Query(True, description="Include facet counts"),
    highlight: bool = Query(True, description="Include search highlighting"),
):
    params: dict[str, Any] = {
        "q": q,
        "rows": rows,
        "start": start,
        "sort": sort,
        "defType": "edismax",
        "qf": "title^3 developer^2 publisher^1.5 description^1 genre^1 tags^2",
        "pf": "title^5",
        "mm": "2<-1 5<80%",
        "fl": "id,title,developer,publisher,genre,platform,price,sale_price,"
              "metacritic_score,user_score,esrb_rating,release_date,"
              "multiplayer,on_sale,featured,score",
    }

    # Filter queries
    fqs = _build_filter_queries(
        genre, platform, esrb, on_sale, multiplayer,
        min_score, max_price, year_from, year_to,
    )
    if fqs:
        params["fq"] = fqs

    # Facets
    if facets:
        params.update({
            "facet": "true",
            "facet.field": ["genre", "platform", "esrb_rating", "release_year"],
            "facet.range": ["price", "metacritic_score"],
            "f.price.facet.range.start": 0,
            "f.price.facet.range.end": 80,
            "f.price.facet.range.gap": 20,
            "f.metacritic_score.facet.range.start": 0,
            "f.metacritic_score.facet.range.end": 100,
            "f.metacritic_score.facet.range.gap": 10,
            "facet.mincount": 1,
        })

    # Highlighting
    if highlight:
        params.update({
            "hl": "true",
            "hl.fl": "title,description",
            "hl.fragsize": 150,
            "hl.snippets": 2,
        })

    data = await _solr_get(params)
    resp = data["response"]
    results = [_parse_game(d) for d in resp.get("docs", [])]

    # Parse facets
    facet_data: dict[str, Any] = {}
    if facets and "facet_counts" in data:
        fc = data["facet_counts"]
        # Field facets → dict of value→count
        for fname, fvals in fc.get("facet_fields", {}).items():
            facet_data[fname] = {
                fvals[i]: fvals[i + 1] for i in range(0, len(fvals), 2) if fvals[i + 1] > 0
            }
        # Range facets
        for fname, fdata in fc.get("facet_ranges", {}).items():
            facet_data[f"{fname}_range"] = fdata.get("counts", {})

    return SearchResponse(
        query=q,
        total=resp["numFound"],
        rows=rows,
        start=start,
        results=results,
        facets=facet_data,
        highlights=data.get("highlighting", {}),
        spellcheck=data.get("spellcheck", {}),
    )


@app.get("/suggest", response_model=SuggestResponse, summary="Autocomplete suggestions")
async def suggest(
    q: str = Query(..., min_length=1, description="Prefix to autocomplete"),
    count: int = Query(10, ge=1, le=25),
):
    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.get(
            f"{BASE}/suggest",
            params={"suggest": "true", "suggest.q": q, "suggest.count": count, "wt": "json"},
        )
    if resp.status_code != 200:
        raise HTTPException(502, f"Solr suggest error: {resp.status_code}")

    data = resp.json()
    suggestions: list[str] = []
    for _term, tdata in data.get("suggest", {}).get("gameSuggest", {}).items():
        for s in tdata.get("suggestions", []):
            if s["term"] not in suggestions:
                suggestions.append(s["term"])

    return SuggestResponse(query=q, suggestions=suggestions[:count])


@app.get("/similar/{game_id}", response_model=SimilarResponse, summary="More Like This")
async def similar(game_id: str, rows: int = Query(6, ge=1, le=20)):
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(
            f"{BASE}/mlt",
            params={
                "q": f"id:{game_id}",
                "mlt.fl": "title,description,genre,tags",
                "mlt.mindf": 1,
                "mlt.mintf": 1,
                "rows": rows,
                "fl": "id,title,developer,genre,platform,metacritic_score,price,score",
                "wt": "json",
            },
        )
    if resp.status_code != 200:
        raise HTTPException(502, f"Solr MLT error: {resp.status_code}")

    data = resp.json()
    docs = data["response"].get("docs", [])
    return SimilarResponse(source_id=game_id, similar=[_parse_game(d) for d in docs])


@app.get("/facets", response_model=FacetResponse, summary="Facet counts for browsing")
async def facets(q: str = Query("*:*")):
    params = {
        "q": q,
        "rows": 0,
        "defType": "edismax",
        "qf": "_text_",
        "facet": "true",
        "facet.field": ["genre", "platform", "esrb_rating", "release_year"],
        "facet.range": ["price", "metacritic_score"],
        "f.price.facet.range.start": 0,
        "f.price.facet.range.end": 80,
        "f.price.facet.range.gap": 20,
        "f.metacritic_score.facet.range.start": 0,
        "f.metacritic_score.facet.range.end": 100,
        "f.metacritic_score.facet.range.gap": 10,
        "facet.mincount": 1,
    }
    data = await _solr_get(params)
    fc = data.get("facet_counts", {})
    result: dict[str, Any] = {}
    for fname, fvals in fc.get("facet_fields", {}).items():
        result[fname] = {fvals[i]: fvals[i + 1] for i in range(0, len(fvals), 2) if fvals[i + 1] > 0}
    for fname, fdata in fc.get("facet_ranges", {}).items():
        result[f"{fname}_range"] = fdata.get("counts", {})
    return FacetResponse(facets=result)


@app.get("/game/{game_id}", response_model=GameDoc, summary="Fetch a single game by ID")
async def get_game(game_id: str):
    data = await _solr_get({"q": f"id:{game_id}", "rows": 1})
    docs = data["response"].get("docs", [])
    if not docs:
        raise HTTPException(404, f"Game '{game_id}' not found")
    return _parse_game(docs[0])


@app.get("/health", response_model=HealthResponse, summary="Cluster health check")
async def health():
    async with httpx.AsyncClient(timeout=5.0) as client:
        # Cluster status
        cluster_resp = await client.get(
            f"{SOLR_URL}/admin/collections",
            params={"action": "CLUSTERSTATUS", "wt": "json"},
        )
        # Doc count
        count_resp = await client.get(
            f"{BASE}/select",
            params={"q": "*:*", "rows": 0, "wt": "json"},
        )

    if cluster_resp.status_code != 200:
        raise HTTPException(503, "Solr cluster unreachable")

    cluster = cluster_resp.json().get("cluster", {})
    live_nodes = len(cluster.get("live_nodes", []))
    total_docs = count_resp.json()["response"]["numFound"] if count_resp.status_code == 200 else -1

    return HealthResponse(
        status="healthy" if live_nodes >= 2 else "degraded",
        solr_live_nodes=live_nodes,
        collection=COLLECTION,
        total_docs=total_docs,
    )


@app.get("/", include_in_schema=False)
async def root():
    return {
        "service": "Video Game Search API",
        "docs": "/docs",
        "health": "/health",
        "search_example": "/search?q=souls+like&platform=PS5&facets=true",
    }
