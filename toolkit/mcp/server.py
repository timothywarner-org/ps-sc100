#!/usr/bin/env python3
"""
server.py -- the SC-100 study knowledge MCP server.

WHAT IT DOES
------------
It lets an AI assistant answer your SC-100 questions from Microsoft's own training
text, with a citation on every passage. Four tools, one store:

    sc100_search_learn         search the Learn corpus; every passage carries a source_url
    sc100_objective_coverage   how deeply Learn covers one exam objective
    sc100_coverage_sweep       which objectives Learn covers thinly (study those harder)
    sc100_check_currency       retired product names and lifecycle language in the corpus

The store is a local Chroma collection (`sc100_learn`, built by tools/ingest_local.py)
at zero cost and with no `az login`. Set SC100_BACKEND=azure to read the optional Azure
AI Search index instead (see infra/ and tools/ingest_azure.py).

CITABILITY IS THE CONTRACT
--------------------------
Every passage the server returns carries its full text AND a `source_url` you can open.
That only happens because the Chroma query asks for document text explicitly:

    include=["documents", "metadatas", "distances"]

Leaving "documents" out would fail SILENTLY: retrieval would still return plausible
hits, just with empty `text` and nothing to quote. So the include list is named once
(LEARN_INCLUDE), and --self-test asserts it still requests documents.

FOUR TOOLS, NOT FIVE
--------------------
An earlier design had a separate `find_gaps` tool. It answered the same question as
objective coverage with different defaults, so it became sc100_coverage_sweep, the
batch form of the same measurement. Two tools that overlap are the most common cause of
wrong tool selection: the model picks one, gets a partial answer, and never learns the
other existed.

PROTOCOL AND SDK
----------------
Targets MCP specification revision **2026-07-28** on the Python SDK's 2.x line
(`mcp >= 2.0.0`). That is a breaking change from 1.x and worth stating plainly, because
the failure is abrupt rather than gradual:

    1.x   from mcp.server.fastmcp import FastMCP
    2.x   from mcp.server import MCPServer          # fastmcp module removed entirely

The 2.x line negotiates protocol version per connection, so an older client is not
locked out. `--self-test` prints the negotiated set so you can see exactly what this
build supports rather than trusting this comment.

RUN
---
    uv run python mcp/server.py --self-test      # verify configuration and tools, then exit
    uv run python mcp/server.py                  # stdio transport, for an MCP host

Register it with an MCP host (Claude Desktop, Claude Code, VS Code): see README.md.
"""

from __future__ import annotations

import argparse
import functools
import json
import os
import pathlib
import re
import sys

# tools/ holds the shared paths and auth helpers. Adding it to the path keeps one
# implementation of "where does the index live" rather than a second copy that drifts.
TOOLKIT_ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLKIT_ROOT / "tools"))

from _common import CHROMA_DIR, OBJECTIVES_FILE, load_env, resolve_path  # noqa: E402
from pydantic import BaseModel, Field  # noqa: E402

# ---------------------------------------------------------------------------
# Product currency: the do-not-say table
#
# Training data, older books, and older courses confidently supply product names that
# were correct for years and are now retired or renamed. Microsoft Entra Permissions
# Management is the canonical trap: correct for years, now retired, and the current
# answer on the exam is CIEM in Microsoft Defender for Cloud.
#
# This table is deliberately SHORT and sourced, not a guess-list. Extend it only from
# Microsoft's own lifecycle pages, never from memory.
# ---------------------------------------------------------------------------

DO_NOT_SAY = {
    "Microsoft Entra Permissions Management": (
        "Retired. Do not treat it as an available product. The current answer: "
        "permissions management (CIEM) in Microsoft Defender for Cloud. Objective 2.3."
    ),
    "Azure AI Foundry": (
        "Renamed. The current name is Microsoft Foundry. Current docs distinguish Microsoft "
        "Foundry from 'Microsoft Foundry (classic)'. Objectives 1.3, 3.3, 4.3."
    ),
    "Secure Service Edge": (
        "Never was 'Secure'. The correct name is Security Service Edge (SSE), which is the "
        "skills-measured outline's own wording for the functional group. Objective 3.4."
    ),
    "Legacy Microsoft LAPS": (
        "Deprecated as of Windows 11 23H2; the legacy MSI is blocked on newer OS "
        "versions. The current answer: Windows LAPS. Objective 3.2."
    ),
    "Azure Disk Encryption": (
        "Scheduled for retirement and not for new deployments. The current answer: "
        "managed-disk encryption with platform- or customer-managed keys, with Key Vault or "
        "Managed HSM for key management. Correct only when contrasting with a legacy "
        "estate. Objective 4.3."
    ),
    "Azure Policy guest configuration": (
        "Renamed. The current name is Azure Machine Configuration. Comes up when "
        "discussing baseline auditing on Azure Arc-connected servers. Objectives 1.3, 2.4, 3.1."
    ),
    "NSG flow logs": (
        "New NSG flow logs could not be created after 30 June 2025; full retirement "
        "30 September 2027. The current answer: virtual network flow logs. Correct only when "
        "describing an existing deployment being migrated. Objective 3.4."
    ),
    "Defender for IoT on-premises management console": (
        "No longer supported. The current answer: API and syslog integration with existing "
        "IT infrastructure; current guidance integrates air-gapped sensors directly. "
        "Objective 3.2."
    ),
}
"""Retired or renamed product names, each with the name to learn instead.

Keep this in step with ../docs/SC-100-Names-and-Status.md in this repository. Two
entries (Azure Disk Encryption, NSG flow logs) name products that still exist but must
not be recommended for new designs, so their guidance says when the name is still
legitimate rather than banning it outright.
"""

LIFECYCLE_LANGUAGE = re.compile(
    r"\b(retir(?:ed|ing|ement)|deprecat(?:ed|ing|ion)|end[- ]of[- ](?:life|support)|"
    r"no longer (?:available|supported)|legacy|will be removed|sunset)\b",
    re.IGNORECASE,
)

PREVIEW_LANGUAGE = re.compile(r"\b(preview|public preview|private preview|not generally available)\b", re.IGNORECASE)

SERVER_VERSION = "2.0.0"

COLLECTION_NAME = "sc100_learn"
"""The Chroma collection, written by tools/ingest_local.py. Change both or neither."""

DEFAULT_BACKEND = "local"
"""Retrieval reads local Chroma unless SC100_BACKEND says otherwise.

`local` is the default because the index exists to GROUND your study, and a local
collection answers that at zero cost. `azure` switches to the Azure AI Search path,
which adds BM25 and the semantic ranker but costs money and needs `az login`."""

# The spec revision this server was written against. Reported by --self-test alongside
# what the installed SDK actually negotiates, so a drift between the two is visible
# rather than assumed away.
TARGET_SPEC_REVISION = "2026-07-28"


# ---------------------------------------------------------------------------
# Output models
#
# Every tool declares one. Structured output means the client gets typed data instead
# of a wall of prose it has to re-parse.
# ---------------------------------------------------------------------------


class LearnPassage(BaseModel):
    """One Learn passage: quotable, and always citable."""

    chunk_id: str
    text: str = Field(description="The passage, in Microsoft's words. Quote or paraphrase it, and cite source_url.")
    source_url: str = Field(description="Canonical Microsoft Learn URL. Cite this whenever the passage informs an answer.")
    unit_title: str
    section_title: str | None = None
    module_title: str | None = None
    exam_domain: int = Field(description="Exam study-guide domain 1-4, already corrected for the Learn-path inversion.")
    learning_path: str | None = None
    content_type: str | None = None
    score: float | None = Field(default=None, description="Relevance on a 0-4 scale, higher is better.")


class LearnUnit(BaseModel):
    """A parent Learn unit, assembled by rolling up its matching sections.

    This is the 'big' half of ADR-002's small-to-big retrieval: matching happens on
    precise sections, answering happens on the coherent unit.
    """

    unit_id: str
    unit_title: str
    module_title: str | None = None
    exam_domain: int
    source_url: str
    matched_sections: int
    text: str = Field(description="The matching sections of this unit, concatenated in document order.")


class SearchLearnResult(BaseModel):
    query: str
    hit_count: int
    passages: list[LearnPassage]
    units: list[LearnUnit] = Field(description="Section hits rolled up to their parent units. Prefer these when explaining a topic.")


class ObjectiveCoverage(BaseModel):
    """How deeply Microsoft Learn covers one exam objective."""

    objective: str
    exam_domain: int | None = None
    passage_count: int
    passages: list[LearnPassage]
    assessment: str = Field(description="thin | adequate | strong, stated in words. Thin means the free training covers it lightly.")


class CoverageSweep(BaseModel):
    """Many objectives at once: the thinly covered ones are where to study harder."""

    objectives_checked: int
    thin_coverage: list[ObjectiveCoverage] = Field(description="Objectives where the free Learn training is thinnest.")
    summary: str


class CurrencyFinding(BaseModel):
    chunk_id: str
    source_url: str
    unit_title: str
    finding: str = Field(description="What was matched: a do-not-say product, lifecycle language, or preview language.")
    severity: str = Field(description="blocking | review | informational, stated in words, never by colour.")
    excerpt: str


class CurrencyReport(BaseModel):
    scanned: str
    finding_count: int
    findings: list[CurrencyFinding]
    guidance: str


# ---------------------------------------------------------------------------
# Lazily-built clients
#
# Built on first use rather than at import, so --self-test and `--help` work with no
# index present and no credential prompt.
# ---------------------------------------------------------------------------

_state: dict = {}


def _cfg() -> dict[str, str]:
    if "cfg" not in _state:
        _state["cfg"] = load_env(required=False)
    return _state["cfg"]


def _setting(key: str, default: str) -> str:
    """Read one setting from the process environment first, then .env, then a default.

    load_env() applies os.environ on top of the file, but only for keys the FILE already
    contains. That is wrong for a switch you want to flip for one run on a machine with
    no .env at all, which is exactly how SC100_BACKEND is meant to be used. So the
    environment is consulted directly here.

    Args:
        key: The setting name.
        default: Value to use when neither the environment nor .env supplies one.

    Returns:
        The setting value, stripped. Never empty: an empty value yields the default.
    """
    for candidate in (os.environ.get(key), _cfg().get(key)):
        if candidate and candidate.strip():
            return candidate.strip()
    return default


def _backend() -> str:
    """Return the configured backend, normalised to 'local' or 'azure'.

    Anything unrecognised is a configuration typo, and a typo that silently fell back
    to the default is the kind of bug you only notice when an answer arrives from the
    wrong store. So it raises.

    Raises:
        ValueError: If SC100_BACKEND holds anything else.
    """
    raw = _setting("SC100_BACKEND", DEFAULT_BACKEND).lower()
    if raw not in ("local", "azure"):
        raise ValueError(
            f"SC100_BACKEND must be 'local' or 'azure', got {raw!r}. "
            "Leave it unset for the local Chroma default."
        )
    return raw


def _chroma_path() -> pathlib.Path:
    """Resolve the Chroma directory. A relative .env value is relative to the toolkit root.

    The MCP host launches this server from ITS working directory, not yours, so a path
    relative to the current directory would point somewhere arbitrary. Resolving
    against the toolkit root is what makes the server portable.
    """
    raw = _setting("SC100_CHROMA_PATH", "")
    return resolve_path(None, raw or None, CHROMA_DIR)


def _collection():
    """Open the local Chroma collection, building the client on first use.

    Raises:
        RuntimeError: If the persistence directory or the collection is missing.
    """
    if "collection" in _state:
        return _state["collection"]
    import chromadb

    path = _chroma_path()
    if not path.exists():
        raise RuntimeError(
            f"No index found at {path}. "
            "Run tools/chunk_learn.py, then tools/ingest_local.py, first."
        )
    client = chromadb.PersistentClient(path=str(path))
    try:
        _state["collection"] = client.get_collection(COLLECTION_NAME)
    except (ValueError, KeyError) as exc:
        # Chroma raises ValueError (older) or a NotFoundError deriving from it for a
        # missing collection. Catching the specific pair keeps a genuine corruption
        # error visible instead of being reworded into a "run the ingest" hint.
        raise RuntimeError(
            f"Collection '{COLLECTION_NAME}' does not exist at {path}. "
            "Run tools/ingest_local.py to build it."
        ) from exc
    return _state["collection"]


def _search_client():
    """Build the Azure AI Search client for the optional azure backend.

    Imports are inside the function on purpose: the local path must keep working on a
    machine where azure-search-documents was never installed.

    Raises:
        RuntimeError: If AZURE_SEARCH_ENDPOINT is not configured.
    """
    if "search" in _state:
        return _state["search"]
    from _common import get_credential
    from azure.search.documents import SearchClient

    cfg = _cfg()
    endpoint = cfg.get("AZURE_SEARCH_ENDPOINT")
    index = cfg.get("AZURE_SEARCH_INDEX", "sc100-learn")
    if not endpoint:
        raise RuntimeError(
            "SC100_BACKEND is 'azure' but AZURE_SEARCH_ENDPOINT is missing from .env. "
            "Either run infra/deploy.ps1, tools/create_index.py, and tools/ingest_azure.py, "
            "or unset SC100_BACKEND to use local Chroma."
        )
    _state["search"] = SearchClient(endpoint=endpoint, index_name=index, credential=get_credential())
    return _state["search"]


def _rollup(passages: list[LearnPassage]) -> list[LearnUnit]:
    """Roll section hits up to their parent units: ADR-002's small-to-big step.

    Sections are precise enough to match on and too thin to answer from. The unit is
    the coherent envelope, so the assistant explaining a topic gets whole ideas rather
    than a pile of fragments.
    """
    by_unit: dict[str, list[LearnPassage]] = {}
    order: list[str] = []
    for p in passages:
        key = p.source_url  # the unit's canonical address; sections share it
        if key not in by_unit:
            by_unit[key] = []
            order.append(key)
        by_unit[key].append(p)

    units: list[LearnUnit] = []
    for key in order:
        group = by_unit[key]
        first = group[0]
        units.append(
            LearnUnit(
                unit_id=first.chunk_id.split("-")[0],
                unit_title=first.unit_title,
                module_title=first.module_title,
                exam_domain=first.exam_domain,
                source_url=key,
                matched_sections=len(group),
                text="\n\n".join(p.text for p in group),
            )
        )
    return units


def _to_passage(r: dict) -> LearnPassage:
    """Adapt one flat retrieval record onto the output model.

    Both backends normalise into the same flat dict shape before reaching here, so this
    stays backend-agnostic and there is exactly one place deciding what a passage is.
    """
    return LearnPassage(
        chunk_id=r.get("chunk_id", ""),
        text=r.get("text", ""),
        source_url=r.get("source_url", ""),
        unit_title=r.get("unit_title", ""),
        section_title=r.get("section_title"),
        module_title=r.get("module_title"),
        exam_domain=r.get("exam_domain", 0),
        learning_path=r.get("learning_path"),
        content_type=r.get("content_type"),
        score=r.get("score") or r.get("@search.reranker_score") or r.get("@search.score"),
    )


SELECT_FIELDS = [
    "chunk_id", "text", "source_url", "unit_title", "section_title",
    "module_title", "exam_domain", "learning_path", "content_type",
]

# The Chroma include list, named once so it is a declaration rather than a coincidence
# repeated at several call sites. "documents" IS PRESENT AND MUST STAY PRESENT: a passage
# with no text cannot ground an answer, and dropping it would not raise. Retrieval would
# keep returning plausible-looking hits with an empty text field.
LEARN_INCLUDE = ["documents", "metadatas", "distances"]


HNSW_SPACE = "l2"
"""The distance metric the collection was actually BUILT with.

Not a preference: a fact about the store on disk, asserted by --self-test. The
collection is created by tools/ingest_local.py without an `hnsw:space` setting, so
Chroma applies its default, `l2`. Changing this constant does not change the store;
re-ingesting does. If the two ever disagree the self-test fails, rather than letting
the score formula silently misread every distance.
"""


def _distance_to_score(distance: float | None) -> float | None:
    """Map a Chroma distance onto the 0-4 ascending scale the assessments expect.

    WHAT CHROMA ACTUALLY RETURNS HERE, WHICH IS NOT WHAT IT LOOKS LIKE

    The collection uses `hnsw:space = "l2"` (Chroma's default, never overridden at
    ingest), and the default sentence transformer emits UNIT-NORMALIZED vectors
    (verified: every stored norm is 1.0). For unit vectors, squared L2 distance is:

        d = |a-b|^2 = 2 - 2*cos = 2 * (1 - cos)

    which is exactly DOUBLE the cosine distance. Verified against live queries to five
    decimal places.

    An earlier formula was `4 * (1 - d)`, written on the belief that d was cosine
    distance. It never was. That deflated every score by a penalty that GROWS as
    relevance drops, so it compressed and distorted the scale rather than merely
    shifting it. A passage at cos 0.73 scored 1.83 instead of 2.92.

    Recovering cosine and scaling to the same 0-4 range Azure's semantic reranker uses
    gives `4 * cos`, which is what this returns.

    Args:
        distance: The distance Chroma returned, or None if unavailable.

    Returns:
        A score ascending in quality, 0-4, or None when there was no distance.
    """
    if distance is None:
        return None
    cosine_similarity = 1.0 - (float(distance) / 2.0)
    return round(4.0 * cosine_similarity, 4)


# ---------------------------------------------------------------------------
# Query expansion for objective-shaped queries
#
# The ingest side prefixes every chunk with its module/unit context before embedding
# (tools/ingest_local.py, document_text()). The query side originally did not, and that
# asymmetry was a real bug: exam objectives are written in abstract product-neutral
# language ("Specify security requirements for web workloads") while the corpus is
# concrete (Azure Front Door, App Service, WAF). That objective scored 0.19 against a
# corpus holding 152 chunks that mention WAF. The content was never missing; the query
# could not reach it.
#
# Measured over all 81 objectives, mean top score and count graded thin:
#
#     statement alone (baseline)      1.833   11 thin
#     boilerplate verbs stripped      1.628   17 thin   <- WORSE, do not do this
#     domain title prepended          1.918    5 thin
#     group title prepended           2.143    5 thin   <- best, and used below
#
# NOT applied to sc100_search_learn: that tool passes your words through verbatim,
# because someone asking for "Microsoft Entra Private Access" has already supplied the
# context.
# ---------------------------------------------------------------------------


def _expand_objective_query(objective: str) -> str:
    """Prepend the functional-group title to an objective statement before embedding.

    Mirrors what ingest does to each chunk, so both sides of the comparison carry
    subject-matter context instead of only one.

    Returns:
        The query to embed, unchanged when the statement is not in the outline so
        retrieval degrades to the plain behaviour rather than failing.
    """
    objective = (objective or "").strip()
    group = _objective_groups().get(objective.lower(), "")
    if not group or objective.lower().startswith(group.lower()):
        return objective
    return f"{group} {objective}"


@functools.lru_cache(maxsize=1)
def _objective_groups() -> dict[str, str]:
    """Map objective statement (lowercased) -> functional-group title.

    Read once from index/objectives.json, which tools/extract_objectives.py writes. A
    missing or malformed file yields an empty map, which makes expansion a no-op rather
    than an error.
    """
    try:
        data = json.loads(OBJECTIVES_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {
        rec["text"].strip().lower(): rec.get("group_title", "").strip()
        for rec in data.get("objectives", [])
        if rec.get("text") and rec.get("group_title")
    }


def _objective_passages(
    objective: str,
    depth: int,
    exam_domain: int | None = None,
) -> list[LearnPassage]:
    """Retrieve passages for an objective, merging the plain and expanded queries.

    WHY BOTH, MEASURED OVER ALL 81 OBJECTIVES:

        plain query only        11 thin
        expanded query only      5 thin
        best of both             4 thin   <- this function

    Expansion is a clear net win (helps 54, hurts 23, mean top score +0.310), so it
    stays. But it is not free: prepending the functional-group title pulls a query
    toward whatever chunk best matches the GROUP, which is often the module
    introduction that lists every objective in that group at once.

    Running both and keeping each chunk's better score costs one extra query and
    removes the trade-off. A chunk is only as irrelevant as its best evidence suggests.

    Returns:
        Up to `depth` passages, best score first.
    """
    expanded = _expand_objective_query(objective)

    rows = _search(objective, depth, exam_domain)
    if expanded != objective:
        rows = rows + _search(expanded, depth, exam_domain)

    best: dict[str, LearnPassage] = {}
    for row in rows:
        passage = _to_passage(row)
        seen = best.get(passage.chunk_id)
        if seen is None or (passage.score or 0) > (seen.score or 0):
            best[passage.chunk_id] = passage

    return sorted(best.values(), key=lambda p: -(p.score or 0))[:depth]


# ---------------------------------------------------------------------------
# Coverage assessment thresholds
#
# WHY THESE ARE SCORE-BASED AND NOT COUNT-BASED
#
# The first rule graded on len(passages). That cannot work over a dense-vector store:
# a similarity search returns `depth` results whenever the collection holds at least
# that many chunks, because SOMETHING is always nearest. So "thin" was unreachable, and
# a tool whose whole purpose is finding weak coverage reported zero weak spots.
#
# CALIBRATION, over the same 81 objectives at depth 5, 405 scores on the corrected
# scale: min 2.191, p25 2.782, median 2.938, max 3.590. Cosine similarity bunches up at
# the top, so the distribution is tight.
#
#     floor 2.40 ->  2 thin
#     floor 2.50 ->  4 thin   <- chosen: 3.2.1, 4.2.4, 4.2.5, 4.2.7
#     floor 2.60 ->  7 thin
#     floor 2.70 -> 13 thin
#
# 2.50 sits where small calibration drift does not swing the verdict. Retune only
# against a fresh distribution, never by feel, and re-run the calibration whenever the
# corpus is downloaded again or the embedding model changes. Objective IDs are
# positional, so the four listed above refer to the outline the calibration ran on.
# ---------------------------------------------------------------------------

RELEVANCE_FLOOR = 2.50
"""Below this score a passage is a weak match and does not count toward coverage."""

STRONG_SCORE = 3.0
"""A passage at or above this score genuinely addresses the objective."""


def _assess_coverage(passages: list[LearnPassage]) -> str:
    """Grade coverage of one objective as thin, adequate, or strong.

    Grades on how many passages actually MATCH, not how many came back. See the
    threshold commentary above for why that distinction is the whole point.

    Returns:
        "strong", "adequate", or "thin", stated in words, never by colour.
    """
    relevant = sum(1 for p in passages if (p.score or 0) >= RELEVANCE_FLOOR)
    strong = sum(1 for p in passages if (p.score or 0) >= STRONG_SCORE)

    if relevant >= 4 and strong >= 2:
        return "strong"
    if relevant >= 2:
        return "adequate"
    return "thin"


def _where(exam_domain: int | None = None, content_type: str | None = None) -> dict | None:
    """Build a Chroma where clause from the same filters the Azure path takes.

    Chroma wants a dict of operators rather than the OData string Azure AI Search
    parses, and it rejects a single-key `$and`. Both cases are handled here so the tool
    bodies stay free of backend syntax.
    """
    clauses: list[dict] = []
    if exam_domain is not None:
        clauses.append({"exam_domain": {"$eq": exam_domain}})
    if content_type:
        clauses.append({"content_type": {"$eq": content_type}})
    if not clauses:
        return None
    if len(clauses) == 1:
        return clauses[0]
    return {"$and": clauses}


def _local_search(query: str, top: int, where: dict | None = None) -> list[dict]:
    """Query the local Chroma collection and flatten the result.

    Dense-vector only. Chroma's default embedding function runs a small sentence
    transformer locally via ONNX (the same one ingest_local.py embedded with), so query
    and document vectors come from one model with no network call.

    Returns:
        Flat records shaped for _to_passage(), each carrying its text and source_url.
    """
    collection = _collection()
    hits = collection.query(
        query_texts=[query],
        n_results=top,
        where=where,
        include=LEARN_INCLUDE,  # must request "documents"; see LEARN_INCLUDE
    )

    ids = (hits.get("ids") or [[]])[0]
    docs = (hits.get("documents") or [[]])[0]
    metas = (hits.get("metadatas") or [[]])[0]
    dists = (hits.get("distances") or [[]])[0]

    rows: list[dict] = []
    for pos, chunk_id in enumerate(ids):
        meta = dict(metas[pos]) if pos < len(metas) and metas[pos] else {}
        document = docs[pos] if pos < len(docs) else ""
        distance = dists[pos] if pos < len(dists) else None

        # The stored document is "context_prefix\n\n<Microsoft prose>". Splitting the
        # prefix back off matters for citation: when you quote a passage, the quoted
        # words must be Microsoft's, not scaffolding the ingest invented.
        text = (document or "").split("\n\n", 1)[-1].strip()

        row: dict = {k: meta.get(k) for k in SELECT_FIELDS if k != "text"}
        row["chunk_id"] = str(chunk_id)
        row["text"] = text
        row["score"] = _distance_to_score(distance)
        rows.append(row)
    return rows


def _azure_hybrid_search(query: str, top: int, filter_expr: str | None = None) -> list[dict]:
    """One hybrid + semantic query against Azure AI Search. The optional backend.

    Three signals: BM25 over the English analyzer, HNSW cosine over the vectors, fused
    by Reciprocal Rank Fusion, then re-ordered by the semantic ranker. The vector half
    is produced by the index's own query-time vectorizer, so no embedding client is
    needed here and no key travels with the request.
    """
    from azure.search.documents.models import VectorizableTextQuery

    client = _search_client()
    results = client.search(
        search_text=query,
        vector_queries=[
            VectorizableTextQuery(text=query, k_nearest_neighbors=top * 3, fields="text_vector")
        ],
        query_type="semantic",
        semantic_configuration_name="sc100-semantic",
        select=SELECT_FIELDS,
        filter=filter_expr,
        top=top,
    )
    return list(results)


def _search(
    query: str,
    top: int,
    exam_domain: int | None = None,
    content_type: str | None = None,
) -> list[dict]:
    """Retrieve records from whichever backend is configured.

    One entry point for every tool, so the backend choice is made in exactly one place
    and no tool body ever learns which store answered.

    Raises:
        ValueError: If SC100_BACKEND holds an unrecognised value.
        RuntimeError: If the configured backend is not available.
    """
    if _backend() == "azure":
        filters: list[str] = []
        if exam_domain is not None:
            filters.append(f"exam_domain eq {exam_domain}")
        if content_type:
            filters.append(f"content_type eq '{content_type}'")
        return _azure_hybrid_search(query, top, " and ".join(filters) if filters else None)
    return _local_search(query, top, _where(exam_domain, content_type))


def build_server():
    """Construct the server and register the tools.

    MCPServer is the 2.x replacement for 1.x's FastMCP. Same decorator ergonomics,
    different import path and a typed ToolAnnotations model instead of a raw dict.
    """
    from mcp.types import ToolAnnotations

    from mcp.server import MCPServer

    mcp = MCPServer(
        name="sc100-knowledge",
        title="SC-100 Study Knowledge Base",
        version=SERVER_VERSION,
        instructions=(
            "Grounded retrieval over Microsoft Learn's free training for Exam SC-100: "
            "Microsoft Cybersecurity Architect, downloaded to the user's machine for "
            "personal study.\n\n"
            "Every passage carries its text and a source_url. When a passage informs an "
            "answer, cite that source_url so the user can read Microsoft's own page.\n\n"
            "exam_domain filters use the EXAM domain (1-4) from the study guide, not the "
            "Learn learning-path number: Learn path 03 is exam Domain 4, and Learn path 04 "
            "is exam Domain 3.\n\n"
            "Retrieval is dense-vector similarity by default, so near-identical product "
            "names (Microsoft Entra Internet Access and Microsoft Entra Private Access) sit "
            "close together. Search for the specific product by name and read the "
            "source_url before quoting. The corpus is a dated snapshot of training modules, "
            "not live product documentation: run sc100_check_currency before trusting a "
            "product name, and never present a preview feature as generally available."
        ),
    )

    @mcp.tool(
        annotations=ToolAnnotations(
            title="Search Microsoft Learn (SC-100)",
            read_only_hint=True,
            destructive_hint=False,
            idempotent_hint=True,
            open_world_hint=False,
        ),
        structured_output=True,
    )
    def sc100_search_learn(
        query: str,
        top: int = 8,
        exam_domain: int | None = None,
        content_type: str | None = None,
    ) -> SearchLearnResult:
        """Search Microsoft Learn's SC-100 training. Returns quotable passages, each with a source_url to cite.

        Use this to ground any factual answer about Microsoft security products,
        frameworks, or exam objectives. Every passage carries a source_url: cite it.

        Retrieval is dense-vector similarity over a local store by default. Near-identical
        product names such as Microsoft Entra Internet Access and Microsoft Entra Private
        Access sit close together in that space, so ask for the specific product by name
        and read the source_url before quoting.

        Args:
            query: What to look for. Specific product names work best.
            top: Maximum passages to return (1-50).
            exam_domain: Restrict to exam study-guide domain 1-4. This is the EXAM
                domain, not the Learn learning-path number; they differ for domains 3 and 4.
            content_type: Restrict to concept, case_study, module_intro, or module_summary.
        """
        top = max(1, min(top, 50))
        if exam_domain is not None and exam_domain not in (1, 2, 3, 4):
            raise ValueError("exam_domain must be 1, 2, 3, or 4.")

        rows = _search(query, top, exam_domain, content_type)
        passages = [_to_passage(r) for r in rows]
        return SearchLearnResult(
            query=query,
            hit_count=len(passages),
            passages=passages,
            units=_rollup(passages),
        )

    @mcp.tool(
        annotations=ToolAnnotations(
            title="How well Learn covers one exam objective",
            read_only_hint=True,
            destructive_hint=False,
            idempotent_hint=True,
            open_world_hint=False,
        ),
        structured_output=True,
    )
    def sc100_objective_coverage(
        objective: str,
        exam_domain: int | None = None,
        depth: int = 6,
    ) -> ObjectiveCoverage:
        """Measure how deeply Microsoft Learn's free SC-100 training covers one exam objective.

        Use this to decide how much study time an objective deserves. A "thin" assessment
        means the free Learn path covers it lightly, so plan to study that objective from
        the product documentation as well. The passages that come back are the best
        place to start, each with its source_url.

        Args:
            objective: The objective statement, quoted from the exam study guide.
            exam_domain: Optional restriction to domain 1-4.
            depth: How many passages to inspect (1-20).
        """
        depth = max(1, min(depth, 20))
        if exam_domain is not None and exam_domain not in (1, 2, 3, 4):
            raise ValueError("exam_domain must be 1, 2, 3, or 4.")
        passages = _objective_passages(objective, depth, exam_domain)

        return ObjectiveCoverage(
            objective=objective,
            exam_domain=exam_domain,
            passage_count=len(passages),
            passages=passages,
            assessment=_assess_coverage(passages),
        )

    @mcp.tool(
        annotations=ToolAnnotations(
            title="Find the objectives Learn covers thinly",
            read_only_hint=True,
            destructive_hint=False,
            idempotent_hint=True,
            open_world_hint=False,
        ),
        structured_output=True,
    )
    def sc100_coverage_sweep(objectives: list[str], depth: int = 5) -> CoverageSweep:
        """Run objective coverage across many objectives and return the thinly covered ones.

        This is the batch form of sc100_objective_coverage. Feed it objective statements
        from the exam study guide to find where the free Learn training is weakest. Those
        are the likeliest exam surprises for someone who studied only the free path, so
        they deserve extra time with the product documentation.

        Args:
            objectives: Objective statements, quoted verbatim from the study guide.
            depth: Passages to inspect per objective (1-20).
        """
        if not objectives:
            raise ValueError("Provide at least one objective statement.")
        if len(objectives) > 100:
            raise ValueError("Provide at most 100 objectives per sweep.")

        thin: list[ObjectiveCoverage] = []
        for obj in objectives:
            cov = sc100_objective_coverage(obj, None, depth)
            if cov.assessment == "thin":
                thin.append(cov)

        return CoverageSweep(
            objectives_checked=len(objectives),
            thin_coverage=thin,
            summary=(
                f"{len(thin)} of {len(objectives)} objectives have thin coverage in the free "
                "Learn training. Study these from the product documentation as well, because "
                "a learner who studied only the free path arrives underprepared on them."
            ),
        )

    @mcp.tool(
        annotations=ToolAnnotations(
            title="Check product currency",
            read_only_hint=True,
            destructive_hint=False,
            idempotent_hint=True,
            open_world_hint=False,
        ),
        structured_output=True,
    )
    def sc100_check_currency(topic: str, top: int = 20) -> CurrencyReport:
        """Scan Learn passages about a topic for retired products, lifecycle language, and preview features.

        Run this before trusting a product name you picked up from an older book, course,
        or model. Training data confidently supplies historically-correct-but-retired
        names, and the exam tests the current ones. Findings are labelled blocking,
        review, or informational, in words, never by colour.

        Args:
            topic: The area you are studying, e.g. "cloud infrastructure entitlement management".
            top: Passages to scan (1-50).
        """
        top = max(1, min(top, 50))
        rows = _search(topic, top)
        findings: list[CurrencyFinding] = []

        for r in rows:
            text = r.get("text", "")

            for product, note in DO_NOT_SAY.items():
                if product.lower() in text.lower():
                    idx = text.lower().index(product.lower())
                    findings.append(CurrencyFinding(
                        chunk_id=r.get("chunk_id", ""),
                        source_url=r.get("source_url", ""),
                        unit_title=r.get("unit_title", ""),
                        finding=f"Retired or renamed product '{product}'. {note}",
                        severity="blocking",
                        excerpt=text[max(0, idx - 90): idx + 150].strip(),
                    ))

            for m in LIFECYCLE_LANGUAGE.finditer(text):
                findings.append(CurrencyFinding(
                    chunk_id=r.get("chunk_id", ""),
                    source_url=r.get("source_url", ""),
                    unit_title=r.get("unit_title", ""),
                    finding=f"Lifecycle language: '{m.group(0)}'. Check current status in the product documentation.",
                    severity="review",
                    excerpt=text[max(0, m.start() - 90): m.end() + 150].strip(),
                ))

            for m in PREVIEW_LANGUAGE.finditer(text):
                findings.append(CurrencyFinding(
                    chunk_id=r.get("chunk_id", ""),
                    source_url=r.get("source_url", ""),
                    unit_title=r.get("unit_title", ""),
                    finding=f"Preview language: '{m.group(0)}'. Never treat a preview feature as generally available.",
                    severity="informational",
                    excerpt=text[max(0, m.start() - 90): m.end() + 150].strip(),
                ))

        return CurrencyReport(
            scanned=topic,
            finding_count=len(findings),
            findings=findings,
            guidance=(
                "Blocking findings name a retired or renamed product: learn the current name "
                "instead. Review findings need a check against current Microsoft documentation. "
                "This scan reads your downloaded snapshot of the training, so it is only as "
                "current as your last download."
            ),
        )

    return mcp


def self_test() -> int:
    """Verify the configuration, the citability contract, the scoring, and the tool surface.

    Contacts no Azure resource and spends nothing. Checks that need a built index are
    SKIPPED, not failed, when the index is absent, so a fresh clone can still gate.

    Returns:
        0 when every check passed, 1 when any failed.
    """
    print("sc100-knowledge MCP server self-test\n")
    ok_all = True

    print("  [test] the Chroma include= REQUESTS 'documents' (passages must return text)")
    good = "documents" in LEARN_INCLUDE
    ok_all &= good
    print(f"         LEARN_INCLUDE = {LEARN_INCLUDE}  [{'pass' if good else 'FAIL'}]")

    print("\n  [test] the passage model carries text and source_url")
    fields = set(LearnPassage.model_json_schema().get("properties", {}).keys())
    good = {"text", "source_url"} <= fields
    ok_all &= good
    print(f"         LearnPassage fields include text and source_url  [{'pass' if good else 'FAIL'}]")

    print("\n  [test] the backend defaults to local, no Azure required")
    try:
        backend = _backend()
        good = backend in ("local", "azure")
        ok_all &= good
        print(f"         SC100_BACKEND resolves to '{backend}' "
              f"(default '{DEFAULT_BACKEND}')  [{'pass' if good else 'FAIL'}]")
    except ValueError as exc:
        ok_all = False
        print(f"         FAIL: {exc}")

    print("\n  [test] index paths resolve against the toolkit root, not the cwd")
    resolved = _chroma_path()
    configured = _setting("SC100_CHROMA_PATH", "")
    # Only assert the default resolution when the default is in use; pointing
    # SC100_CHROMA_PATH elsewhere is a choice, not a failure.
    good = resolved == CHROMA_DIR.resolve() if not configured else resolved.is_absolute()
    ok_all &= good
    print(f"         {resolved}  [{'pass' if good else 'FAIL'}]")

    print("\n  [test] the where-clause builder speaks Chroma, not OData")
    cases = [
        (_where(None, None), None),
        (_where(2, None), {"exam_domain": {"$eq": 2}}),
        (_where(None, "concept"), {"content_type": {"$eq": "concept"}}),
        (_where(2, "concept"),
         {"$and": [{"exam_domain": {"$eq": 2}}, {"content_type": {"$eq": "concept"}}]}),
    ]
    good = all(actual == want for actual, want in cases)
    ok_all &= good
    print(f"         4 filter shapes, single clause never wrapped in $and  "
          f"[{'pass' if good else 'FAIL'}]")

    print("\n  [test] distance-to-score inverts direction (lower distance, higher score)")
    good = (
        _distance_to_score(None) is None
        # Squared L2 over unit vectors: 0 is identical, 2 is opposite.
        and _distance_to_score(0.0) == 4.0
        and _distance_to_score(2.0) == 0.0
        and _distance_to_score(1.0) == 2.0
        and _distance_to_score(0.4) > _distance_to_score(0.9)
    )
    ok_all &= good
    print(f"         d=0.0 -> {_distance_to_score(0.0)}, d=0.6 -> {_distance_to_score(0.6)}, "
          f"d=1.0 -> {_distance_to_score(1.0)}  [{'pass' if good else 'FAIL'}]")

    # REGRESSION GUARD. The first rule graded on len(passages), which a dense-vector
    # search always satisfies, so "thin" was unreachable. The five-weak-passages case
    # below is the exact shape that used to grade "adequate".
    print("\n  [test] coverage grades on relevance, not result count")

    class _S:
        def __init__(self, score):
            self.score = score

    weak_five = [_S(2.4), _S(2.3), _S(2.2), _S(2.2), _S(2.1)]
    cases = [
        (_assess_coverage(weak_five), "thin"),
        (_assess_coverage([_S(3.3), _S(3.2), _S(3.1), _S(3.0), _S(2.9)]), "strong"),
        (_assess_coverage([_S(2.9), _S(2.6), _S(2.4)]), "adequate"),
        (_assess_coverage([_S(2.9), _S(2.4), _S(2.3)]), "thin"),
        (_assess_coverage([]), "thin"),
        (_assess_coverage([_S(None), _S(None)]), "thin"),
    ]
    good = all(actual == want for actual, want in cases)
    ok_all &= good
    print(f"         five below-floor passages (top 2.4) grade "
          f"{_assess_coverage(weak_five)!r}, not 'adequate'  "
          f"[{'pass' if good else 'FAIL'}]")
    print(f"         floor={RELEVANCE_FLOOR} strong={STRONG_SCORE}, "
          f"{len(cases)} shapes checked")

    print("\n  [test] the do-not-say table carries guidance for every entry")
    good = len(DO_NOT_SAY) >= 8 and all(v.strip() for v in DO_NOT_SAY.values())
    ok_all &= good
    print(f"         {len(DO_NOT_SAY)} entries, every one naming what to learn instead  "
          f"[{'pass' if good else 'FAIL'}]")

    print("\n  [test] objective queries get the same context the chunks got")
    groups = _objective_groups()
    if not groups:
        print(f"         [skip] {OBJECTIVES_FILE.name} not found; run tools/extract_objectives.py")
    else:
        known = next(iter(groups))  # any real objective statement, lowercased
        expanded = _expand_objective_query(known)
        unknown = "Microsoft Entra Private Access"
        good = (
            len(groups) == 81
            and expanded != known
            and known in expanded
            # An unknown query passes through untouched, so search_learn is unaffected.
            and _expand_objective_query(unknown) == unknown
            # Expanding twice must not double the prefix.
            and _expand_objective_query(expanded) == expanded
        )
        ok_all &= good
        print(f"         {len(groups)} objectives mapped to group titles  "
              f"[{'pass' if good else 'FAIL'}]")
        print("         unknown query passes through unchanged, expansion is idempotent")

    # REGRESSION GUARD for the score formula. _distance_to_score converts SQUARED L2
    # into cosine. If the collection is ever rebuilt with a different hnsw:space that
    # conversion becomes silently wrong: every score shifts, and every coverage verdict
    # with it. Assert the metric on disk, not the intent in the docstring.
    print("\n  [test] the collection still uses the metric the score formula assumes")
    try:
        cfg = getattr(_collection(), "configuration_json", None) or {}
        space = (cfg.get("hnsw") or {}).get("space")
        good = space == HNSW_SPACE
        ok_all &= good
        print(f"         hnsw.space is {space!r}, formula assumes {HNSW_SPACE!r}  "
              f"[{'pass' if good else 'FAIL'}]")
        if not good:
            print("         -> re-run the calibration; scores and thresholds are now wrong")
    except (RuntimeError, ImportError) as exc:
        print(f"         [skip] {exc}")

    # Live retrieval. Local, offline, free. Skipped, not failed, when the collection has
    # not been built yet, so a fresh clone must still gate.
    print("\n  [test] retrieval returns TEXT and a source_url")
    try:
        rows = _search("Zero Trust", 3)
        passages = [_to_passage(r) for r in rows]
        with_text = sum(1 for p in passages if p.text.strip())
        with_url = sum(1 for p in passages if p.source_url.strip())
        good = bool(passages) and with_text == len(passages) and with_url == len(passages)
        ok_all &= good
        print(f"         {len(passages)} passages, {with_text} with text, "
              f"{with_url} with source_url  [{'pass' if good else 'FAIL'}]")
        if passages:
            print(f"         first hit: {passages[0].unit_title!r}")
            print(f"         cite:      {passages[0].source_url}")
    except RuntimeError as exc:
        print(f"         [skip] {exc}")
    except ImportError as exc:
        print(f"         [skip] chromadb is not installed: {exc}")

    print("\n  [test] the server builds and registers its tools")
    try:
        server = build_server()
        # Still a coroutine in 2.x despite the sync-looking return annotation:
        # checked against the installed SDK rather than inferred from the signature.
        import asyncio

        tools = asyncio.run(server.list_tools())
        names = sorted(t.name for t in tools)
        print(f"         {len(names)} tools: {names}")
        expected = {
            "sc100_search_learn", "sc100_objective_coverage",
            "sc100_coverage_sweep", "sc100_check_currency",
        }
        good = set(names) == expected
        ok_all &= good
        print(f"         tool surface is exactly the four documented tools  [{'pass' if good else 'FAIL'}]")
    except Exception as exc:  # noqa: BLE001
        ok_all = False
        print(f"         FAIL: {exc}")

    print("\n  [test] the installed SDK speaks the targeted spec revision")
    try:
        from mcp.types.version import LATEST_PROTOCOL_VERSION, SUPPORTED_PROTOCOL_VERSIONS

        supported = tuple(SUPPORTED_PROTOCOL_VERSIONS)
        good = TARGET_SPEC_REVISION in supported
        ok_all &= good
        print(f"         targeted        {TARGET_SPEC_REVISION}")
        print(f"         SDK latest      {LATEST_PROTOCOL_VERSION}")
        print(f"         SDK supports    {', '.join(supported)}")
        print(f"         target is supported  [{'pass' if good else 'FAIL'}]")
        if LATEST_PROTOCOL_VERSION != TARGET_SPEC_REVISION:
            print(f"         note: SDK latest ({LATEST_PROTOCOL_VERSION}) differs from the")
            print("         targeted revision. Review before assuming parity.")
    except Exception as exc:  # noqa: BLE001
        ok_all = False
        print(f"         FAIL: could not read SDK protocol versions: {exc}")

    print("\n  [check] configuration")
    cfg = _cfg()
    print(f"         {'backend':<22} {_setting('SC100_BACKEND', DEFAULT_BACKEND + ' (default)')}")
    print(f"         {'local index':<22} {_chroma_path()}")
    print(f"         {'objectives file':<22} {OBJECTIVES_FILE}")
    for key, label in (
        ("AZURE_SEARCH_ENDPOINT", "azure endpoint"),
        ("AZURE_SEARCH_INDEX", "azure index"),
    ):
        print(f"         {label:<22} {cfg.get(key) or 'not configured'}")

    print("\n  self-test:", "ALL PASS" if ok_all else "FAILURES PRESENT")
    return 0 if ok_all else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true", help="Verify configuration and tool surface, then exit.")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    build_server().run(transport="stdio")
    return 0


if __name__ == "__main__":
    sys.exit(main())
