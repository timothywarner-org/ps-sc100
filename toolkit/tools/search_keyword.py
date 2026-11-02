#!/usr/bin/env python3
"""
search_keyword.py -- keyword search over the Learn chunk file, standard library only.

WHY THIS EXISTS
---------------
This is the five-minute path into the toolkit. It needs nothing but Python 3.10 or
later: no virtual environment, no vector store, no embedding model download, no MCP
host. It reads `index/learn-chunks.jsonl`, the same file the vector store is built
from, so every hit carries the same `source_url` the MCP server would cite.

It imports nothing outside the standard library on purpose. A fallback that needs
`pip install` fails exactly where you need it: on a locked-down machine, in a
container with no network, or before you have run `uv sync`.

WHEN TO USE WHICH MODE
----------------------
    phrase   Exact, case-insensitive phrase match. The right instrument for VERIFYING
             that a product name or a claim appears in Microsoft Learn. Dense vectors put
             "Entra Internet Access" and "Entra Private Access" nearly on top of each
             other; a phrase match cannot confuse them.
    bm25     Ranked keyword search (Okapi BM25). For open-ended discovery when you do not
             know the exact wording. Keys on the token that differs, which is why it
             separates near-identical product names better than embeddings do.
    stats    Corpus sanity check: chunk count, domains, how many carry a source_url.

WHAT IT CANNOT REPLACE
----------------------
The MCP server's objective-coverage and coverage-sweep tools have no substitute here.
Those grade depth across the whole skills-measured outline and need the calibrated
vector scores. Use this script to verify a claim and to discover where Learn teaches a
topic.

RUN
---
    python tools/search_keyword.py phrase "Microsoft Entra Private Access"
    python tools/search_keyword.py bm25 "ransomware recovery immutable backup" --top 5
    python tools/search_keyword.py bm25 "key vault" --domain 3 --json
    python tools/search_keyword.py stats
    python tools/search_keyword.py --self-test

EXIT CODES
----------
    0  success (including a search with zero hits, which is a valid answer)
    1  bad input: missing file, unreadable or damaged chunk file
    2  self-test failure
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import pathlib
import re
import sys
import tempfile
import unicodedata
from collections import Counter
from dataclasses import dataclass, field

# Resolved from this file, so the default works from any working directory. Not
# imported from _common.py: this script must run with nothing installed at all.
TOOLKIT_ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_CHUNKS = TOOLKIT_ROOT / "index" / "learn-chunks.jsonl"

# Okapi BM25 defaults. k1 controls term-frequency saturation, b controls length
# normalisation. These are the textbook values and suit ~200-token chunks well; tuning
# them buys little on a 1,000-chunk corpus and would make results harder to explain.
BM25_K1 = 1.5
BM25_B = 0.75

# Titles are short and authored, so a term in a unit or section title is stronger
# evidence than the same term in body prose. Counting title tokens twice is the
# simplest honest way to say that without a second scoring model.
TITLE_WEIGHT = 2

# Deliberately small. Aggressive stopword lists delete words that matter in this domain
# ("access", "data", "control"). These are function words only.
STOPWORDS = frozenset(
    "a an and are as at be by can for from how in into is it its of on or that the this "
    "to use used using what when which with you your".split()
)

SNIPPET_CHARS = 260


# --------------------------------------------------------------------------------------
# Data model
# --------------------------------------------------------------------------------------
@dataclass
class Chunk:
    """One Learn chunk, reduced to the fields a citation needs."""

    chunk_id: str
    exam_domain: str
    module_title: str
    unit_title: str
    section_title: str
    source_url: str
    text: str
    tokens: list[str] = field(default_factory=list)

    @property
    def location(self) -> str:
        parts = [p for p in (self.module_title, self.unit_title, self.section_title) if p]
        return " > ".join(parts)


@dataclass
class Hit:
    rank: int
    score: float
    chunk: Chunk
    snippet: str

    def as_dict(self) -> dict:
        return {
            "rank": self.rank,
            "score": round(self.score, 3),
            "exam_domain": self.chunk.exam_domain,
            "module_title": self.chunk.module_title,
            "unit_title": self.chunk.unit_title,
            "section_title": self.chunk.section_title,
            "source_url": self.chunk.source_url,
            "chunk_id": self.chunk.chunk_id,
            "snippet": self.snippet,
        }


class CorpusError(Exception):
    """Raised for any input problem the caller should see as a plain message."""


# --------------------------------------------------------------------------------------
# Text handling
# --------------------------------------------------------------------------------------
def normalise(text: str) -> str:
    """NFKC + casefold + collapsed whitespace.

    NFKC folds the typographic variants Learn pages carry (non-breaking spaces, curly
    quotes, ligatures) into their plain forms, so a phrase typed on a keyboard matches a
    phrase rendered by a web page.
    """
    text = unicodedata.normalize("NFKC", text).casefold()
    return re.sub(r"\s+", " ", text).strip()


def tokenize(text: str) -> list[str]:
    """Alphanumeric tokens, stopwords removed.

    Hyphenated names split into parts ("zero-trust" -> "zero", "trust"), which is what
    lets "Zero Trust" and "Zero-Trust" match each other. Precise hyphenated identifiers
    such as control IDs are what phrase mode is for.
    """
    return [t for t in re.findall(r"[a-z0-9]+", normalise(text)) if t not in STOPWORDS]


def make_snippet(text: str, needles: list[str]) -> str:
    """Return a window of the chunk around the first needle that appears in it."""
    flat = re.sub(r"\s+", " ", text).strip()
    low = normalise(flat)
    positions = [low.find(n) for n in needles if n and low.find(n) >= 0]
    if not positions:
        return flat[:SNIPPET_CHARS] + ("..." if len(flat) > SNIPPET_CHARS else "")
    start = max(0, min(positions) - SNIPPET_CHARS // 3)
    end = min(len(flat), start + SNIPPET_CHARS)
    return ("..." if start else "") + flat[start:end] + ("..." if end < len(flat) else "")


# --------------------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------------------
def load_chunks(path: pathlib.Path) -> tuple[list[Chunk], int]:
    """Load Learn chunks. Returns (chunks, malformed_line_count).

    Raises CorpusError for a missing file or a file with no usable records. Malformed
    lines are counted and skipped rather than fatal, but more than 1% of them means the
    file is damaged and the run stops.
    """
    if not path.is_file():
        raise CorpusError(
            f"Chunk file not found: {path}\n"
            "Build it from the corpus with tools/chunk_learn.py, or pass --chunks."
        )

    chunks: list[Chunk] = []
    malformed = 0
    total = 0
    with path.open(encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            total += 1
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                malformed += 1
                continue
            chunk = Chunk(
                chunk_id=str(rec.get("chunk_id", f"line-{line_no}")),
                exam_domain=str(rec.get("exam_domain", "")),
                module_title=str(rec.get("module_title", "")),
                unit_title=str(rec.get("unit_title", "")),
                section_title=str(rec.get("section_title", "")),
                source_url=str(rec.get("source_url", "")),
                text=str(rec.get("text", "")),
            )
            title_tokens = tokenize(f"{chunk.unit_title} {chunk.section_title}")
            chunk.tokens = tokenize(chunk.text) + title_tokens * TITLE_WEIGHT
            chunks.append(chunk)

    if total and malformed / total > 0.01:
        raise CorpusError(f"{malformed} of {total} lines in {path} are not valid JSON. The file is damaged.")
    if not chunks:
        raise CorpusError(f"No usable records in {path}.")
    return chunks, malformed


# --------------------------------------------------------------------------------------
# Search
# --------------------------------------------------------------------------------------
class Bm25Index:
    """A minimal in-memory Okapi BM25 index. Built per run; ~1,000 chunks index in well
    under a second, so there is nothing to cache and nothing to go stale."""

    def __init__(self, chunks: list[Chunk]) -> None:
        self.chunks = chunks
        self.n = len(chunks)
        self.avg_len = sum(len(c.tokens) for c in chunks) / max(self.n, 1)
        self.tf = [Counter(c.tokens) for c in chunks]
        df: Counter[str] = Counter()
        for counts in self.tf:
            df.update(counts.keys())
        # The "+1 inside the log" variant keeps IDF positive even for a term that
        # appears in most chunks, so a common term can never subtract from a score.
        self.idf = {t: math.log(1 + (self.n - d + 0.5) / (d + 0.5)) for t, d in df.items()}

    def score(self, query_tokens: list[str], i: int) -> float:
        counts = self.tf[i]
        length = len(self.chunks[i].tokens)
        total = 0.0
        for t in query_tokens:
            f = counts.get(t, 0)
            if not f:
                continue
            denom = f + BM25_K1 * (1 - BM25_B + BM25_B * length / self.avg_len)
            total += self.idf.get(t, 0.0) * f * (BM25_K1 + 1) / denom
        return total


def search_bm25(chunks: list[Chunk], query: str, top: int, domain: str | None) -> list[Hit]:
    q = tokenize(query)
    if not q:
        raise CorpusError("The query has no searchable words after stopword removal.")
    index = Bm25Index(chunks)
    scored = []
    for i, chunk in enumerate(chunks):
        if domain and chunk.exam_domain != domain:
            continue
        s = index.score(q, i)
        if s > 0:
            scored.append((s, chunk))
    scored.sort(key=lambda pair: (-pair[0], pair[1].chunk_id))
    return [Hit(rank, s, c, make_snippet(c.text, q)) for rank, (s, c) in enumerate(scored[:top], start=1)]


def search_phrase(chunks: list[Chunk], phrase: str, top: int, domain: str | None) -> list[Hit]:
    needle = normalise(phrase)
    if not needle:
        raise CorpusError("The phrase is empty.")
    found = []
    for chunk in chunks:
        if domain and chunk.exam_domain != domain:
            continue
        haystack = normalise(f"{chunk.unit_title} {chunk.section_title} {chunk.text}")
        count = haystack.count(needle)
        if count:
            found.append((float(count), chunk))
    found.sort(key=lambda pair: (-pair[0], pair[1].chunk_id))
    return [Hit(rank, s, c, make_snippet(c.text, [needle])) for rank, (s, c) in enumerate(found[:top], start=1)]


def corpus_stats(chunks: list[Chunk], malformed: int) -> dict:
    by_domain = Counter(c.exam_domain or "(none)" for c in chunks)
    return {
        "chunks": len(chunks),
        "with_source_url": sum(1 for c in chunks if c.source_url),
        "distinct_units": len({(c.module_title, c.unit_title) for c in chunks}),
        "by_exam_domain": dict(sorted(by_domain.items())),
        "malformed_lines_skipped": malformed,
    }


# --------------------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------------------
def print_hits(mode: str, query: str, hits: list[Hit], total_chunks: int) -> None:
    label = "occurrences" if mode == "phrase" else "score"
    print(f"{mode}: {query!r}  ->  {len(hits)} hit(s) shown, searched {total_chunks} chunks")
    if not hits:
        print("NO MATCH in the Learn corpus. That is not proof the claim is wrong: this corpus")
        print("is the SC-100 training modules only, so check the product documentation on")
        print("learn.microsoft.com before you treat a claim as unsupported.")
        return
    for h in hits:
        print()
        print(f"[{h.rank}] {label} {h.score:.2f}   domain {h.chunk.exam_domain or '?'}")
        print(f"    {h.chunk.location}")
        print(f"    {h.chunk.source_url or '(no source_url)'}")
        print(f"    {h.snippet}")


# --------------------------------------------------------------------------------------
# Self-test
# --------------------------------------------------------------------------------------
def _write_jsonl(records: list[dict]) -> pathlib.Path:
    fd, name = tempfile.mkstemp(prefix="kw-selftest-", suffix=".jsonl")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")
    return pathlib.Path(name)


def self_test() -> int:
    """Offline tests against a synthetic corpus built around this domain's real traps."""
    base = {"module_title": "M", "section_title": "S"}
    records = [
        {**base, "chunk_id": "c1", "exam_domain": "2", "unit_title": "Internet Access",
         "source_url": "https://learn.example/internet",
         "text": "Microsoft Entra Internet Access secures access to internet and SaaS apps."},
        {**base, "chunk_id": "c2", "exam_domain": "2", "unit_title": "Private Access",
         "source_url": "https://learn.example/private",
         "text": "Microsoft Entra Private Access replaces legacy VPN for private apps."},
        {**base, "chunk_id": "c3", "exam_domain": "3", "unit_title": "Backups",
         "source_url": "https://learn.example/backup",
         "text": "Immutable vaults protect backups from ransomware. Ransomware recovery needs tested restores."},
    ]
    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        print(f"  [{'pass' if ok else 'FAIL'}] {name}" + (f"  ({detail})" if detail else ""))
        failures += 0 if ok else 1

    print("search_keyword self-test")
    good = _write_jsonl(records)
    try:
        chunks, malformed = load_chunks(good)
        check("loads chunk records", len(chunks) == 3 and malformed == 0)

        hits = search_bm25(chunks, "Entra Private Access", 3, None)
        check("bm25 separates Private Access from Internet Access",
              bool(hits) and hits[0].chunk.chunk_id == "c2", hits[0].chunk.chunk_id if hits else "no hits")

        hits = search_phrase(chunks, "entra  internet   ACCESS", 5, None)
        check("phrase match is case- and whitespace-insensitive, and exact",
              [h.chunk.chunk_id for h in hits] == ["c1"])

        hits = search_phrase(chunks, "ransomware", 5, None)
        check("phrase ranks by occurrence count", bool(hits) and hits[0].score == 2.0, f"score {hits[0].score if hits else 0}")

        hits = search_bm25(chunks, "access", 5, "3")
        check("domain filter excludes other domains", hits == [])

        check("every hit carries its source_url",
              all(h.chunk.source_url for h in search_bm25(chunks, "access backups", 5, None)))

        check("zero-hit search returns an empty list, not an error",
              search_phrase(chunks, "Permissions Management", 5, None) == [])

        try:
            search_bm25(chunks, "the and of", 5, None)
            check("stopword-only query is rejected", False)
        except CorpusError:
            check("stopword-only query is rejected", True)
    finally:
        good.unlink(missing_ok=True)

    damaged = _write_jsonl(records[:1])
    try:
        with damaged.open("a", encoding="utf-8") as f:
            f.write("{not json\n")
        load_chunks(damaged)
        check("a file that is mostly malformed is refused as damaged", False)
    except CorpusError as exc:
        check("a file that is mostly malformed is refused as damaged", "damaged" in str(exc))
    finally:
        damaged.unlink(missing_ok=True)

    try:
        load_chunks(pathlib.Path("does-not-exist.jsonl"))
        check("missing file gives a plain message", False)
    except CorpusError as exc:
        check("missing file gives a plain message", "not found" in str(exc))

    print(f"\n  self-test: {'ALL PASS' if not failures else f'{failures} FAILURE(S)'}")
    return 0 if not failures else 2


# --------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    # Windows consoles default to a legacy code page that cannot print every character
    # Learn content carries. Reconfigure rather than crash mid-result.
    for stream in (sys.stdout, sys.stderr):
        with contextlib.suppress(AttributeError, ValueError):
            stream.reconfigure(encoding="utf-8", errors="replace")

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", nargs="?", choices=("phrase", "bm25", "stats"), help="Search mode.")
    ap.add_argument("query", nargs="?", default="", help="Phrase or keywords. Quote multi-word input.")
    ap.add_argument("--chunks", type=pathlib.Path, default=DEFAULT_CHUNKS,
                    help="Chunk file (default: index/learn-chunks.jsonl in this toolkit)")
    ap.add_argument("--top", type=int, default=8, help="Maximum hits to show (default: 8).")
    ap.add_argument("--domain", help="Only search this exam domain, e.g. 2.")
    ap.add_argument("--json", action="store_true", help="Emit JSON instead of text.")
    ap.add_argument("--self-test", action="store_true", help="Run offline tests and exit.")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.mode:
        ap.error("choose a mode: phrase, bm25, or stats (or --self-test)")
    if args.mode != "stats" and not args.query.strip():
        ap.error(f"{args.mode} needs a query")
    if args.top < 1:
        ap.error("--top must be at least 1")
    if args.domain and args.domain not in ("1", "2", "3", "4"):
        ap.error("--domain must be 1, 2, 3, or 4 (the EXAM domain, not the Learn path number)")

    try:
        chunks, malformed = load_chunks(args.chunks)
        if malformed:
            print(f"[ WARN ] skipped {malformed} malformed line(s) in {args.chunks}", file=sys.stderr)
        if args.mode == "stats":
            stats = corpus_stats(chunks, malformed)
            print(json.dumps(stats, indent=2))
            return 0
        search = search_phrase if args.mode == "phrase" else search_bm25
        hits = search(chunks, args.query, args.top, args.domain)
    except CorpusError as exc:
        print(f"[ ERROR ] {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps({"mode": args.mode, "query": args.query, "hits": [h.as_dict() for h in hits]}, indent=2))
    else:
        print_hits(args.mode, args.query, hits, len(chunks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
