#!/usr/bin/env python3
"""
ingest_local.py -- embed the Learn chunks into a LOCAL Chroma collection.

WHY LOCAL IS THE DEFAULT
------------------------
This index exists to ground your study: you ask a question, you get Microsoft's own
words back with a link to the page they came from. A local Chroma collection answers
that at zero cost, with no Azure subscription, no `az login`, and no network once the
embedding model has been downloaded. See docs/ADR-001-vector-store.md.

What that gives up, stated honestly: Azure AI Search adds BM25 and a semantic ranker,
the combination that best separates near-identical product names (Microsoft Entra
Internet Access versus Microsoft Entra Private Access). Local Chroma is dense-vector
only. You read these results yourself, so a near-miss is visible and cheap, and
tools/search_keyword.py gives you BM25 locally when you need to pin an exact name.

THE ONE PROPERTY THIS FILE PROTECTS: CITABILITY
-----------------------------------------------
Every passage must come back with its full text AND a `source_url` you can open. That
sounds automatic and is not. Chroma only returns document text when a query asks for it
(`include=[..., "documents"]`), and leaving "documents" out does not raise an error:
retrieval keeps returning plausible-looking hits with empty text and nothing to cite.
So this file verifies citability by running real queries, rather than assuming it.
See verify_collection().

USAGE
-----
    uv run python tools/ingest_local.py
    uv run python tools/ingest_local.py --reset      # drop and rebuild
    uv run python tools/ingest_local.py --verify     # check the existing collection
    uv run python tools/ingest_local.py --limit 25   # smoke test
    uv run python tools/ingest_local.py --self-test  # offline, no deps, no data

The first real run downloads Chroma's default embedding model (about 80 MB). After
that, everything works offline.

EXIT CODES
----------
    0  success
    1  a gate or precondition failed
    2  usage error
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

from _common import (
    CHROMA_DIR,
    CHUNKS_FILE,
    INDEX_DIR,
    TOOLKIT_ROOT,
    fail,
    info,
    load_env,
    ok,
    resolve_path,
    step,
    warn,
)

COLLECTION_NAME = "sc100_learn"
"""The collection name. mcp/server.py opens the same name; change both or neither."""

UPSERT_BATCH = 500
"""Records per Chroma upsert call.

Chroma enforces a max batch size per call (derived from the backing SQLite statement
limits, commonly ~5,461 records), and the practical constraint below that is PAYLOAD:
each record here carries ~1.4 KB of text plus a 384-float vector. 500 keeps a batch in
the low single-digit megabytes, gives the progress line something to say on a run this
size, and leaves an order of magnitude of headroom under the hard cap so a future
chunker change cannot silently cross it."""

METADATA_FIELDS = (
    "exam_domain",
    "domain_weight",
    "domain_title",
    "learning_path",
    "module_title",
    "unit_title",
    "section_title",
    "source_url",
    "content_type",
    "unit_id",
    "chunk_index",
)
"""Filterable fields carried into Chroma metadata.

An explicit allowlist rather than the whole record, so that `text` is stored exactly
once (as the Chroma DOCUMENT) instead of being duplicated into metadata, where it would
double the on-disk size and give retrieval two copies that can disagree after a
re-chunk. `source_url` is on this list and must stay on it.

`objective_ids` is handled separately by serialize_objective_ids(); see there."""

OBJECTIVE_IDS_KEY = "objective_ids"
"""Metadata key holding the serialized objective ID list.

Chroma metadata values must be SCALARS (str, int, float, bool). `objective_ids` is a
LIST in the chunk records, so it cannot go in as-is: Chroma rejects the whole batch.

It is stored as a comma-delimited string with LEADING AND TRAILING commas, for example
`",2.1.3,2.1.4,"`. The sentinel commas are what make substring matching safe: Chroma's
`$contains` on `"2.1.3"` would also match `"12.1.30"`, whereas `",2.1.3,"` cannot.
The chunker emits an empty list today, so this mostly reserves the shape for a future
classification pass. Getting the encoding right now is cheaper than migrating later."""

EMPTY_OBJECTIVE_IDS = ""
"""Encoding for a chunk with no objectives yet, distinct from the `",a,b,"` form.

An empty string rather than `","` so `objective_ids == ""` is an exact-match filter for
"unclassified", which is the query a classification pass would use to find its work."""


# ---------------------------------------------------------------------------
# Pure helpers. Kept free of chromadb and filesystem access so --self-test can
# exercise them with no dependencies installed and no data on disk.
# ---------------------------------------------------------------------------

def serialize_objective_ids(value) -> str:
    """Flatten the objective_ids LIST into a Chroma-legal scalar.

    See OBJECTIVE_IDS_KEY for why the sentinel commas matter. Sorted so the encoding is
    stable: a re-run whose classifier emitted the same IDs in a different order must not
    look like a changed record.
    """
    if not value:
        return EMPTY_OBJECTIVE_IDS
    items = [value] if isinstance(value, str) else [str(v) for v in value]
    items = sorted({s.strip() for s in items if s and s.strip()})
    if not items:
        return EMPTY_OBJECTIVE_IDS
    return "," + ",".join(items) + ","


def build_metadata(rec: dict) -> dict:
    """Project a chunk record onto Chroma-legal scalar metadata.

    Nothing is withheld here: `text` is simply stored as the document instead, so it
    is not duplicated into metadata.
    """
    meta: dict = {}
    for key in METADATA_FIELDS:
        val = rec.get(key)
        if val is None:
            continue
        meta[key] = val if isinstance(val, (str, int, float, bool)) else str(val)
    meta[OBJECTIVE_IDS_KEY] = serialize_objective_ids(rec.get("objective_ids"))
    return meta


def document_text(rec: dict) -> str:
    """Build the string that is BOTH embedded and stored, verbatim-recoverable.

    `context_prefix` leads because chunk_learn.py cuts units at their authored H2/H3
    sections (ADR-002), and a section headed "Design guidance" opening "This approach
    is preferred when..." is, standing alone, confidently irrelevant: nothing in it says
    WHAT approach. The ~40-token prefix restores the subject for the embedding.

    The prefix is joined with a blank line so the Microsoft prose is trivially separable
    at citation time: split once on the first blank line and keep the second half. When
    you quote a passage, the quoted words must be Microsoft's, not scaffolding this
    pipeline invented.
    """
    text = (rec.get("text") or "").strip()
    prefix = (rec.get("context_prefix") or "").strip()
    if prefix and text:
        return f"{prefix}\n\n{text}"
    return text or prefix


def load_chunks(path: pathlib.Path, limit: int | None = None) -> list[dict]:
    """Read the JSONL chunk file, failing on the line number of any bad record.

    Reporting the line number matters because the chunker writes this file: a parse
    error here is a chunker bug, and "line 604" is the difference between a two-minute
    fix and a bisect through a thousand records.
    """
    if not path.is_file():
        fail(
            f"Chunk file not found: {path}",
            "Run: uv run python tools/chunk_learn.py",
        )

    records: list[dict] = []
    with path.open(encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as exc:
                fail(f"{path.name} line {lineno} is not valid JSON: {exc}",
                     "Re-run tools/chunk_learn.py to regenerate the chunk file.")
            if limit is not None and len(records) >= limit:
                break

    if not records:
        fail(f"{path} contains no records.")
    return records


def prepare(records: list[dict]) -> tuple[list[str], list[str], list[dict], list[str]]:
    """Turn chunk records into (ids, documents, metadatas, problems).

    `problems` is returned rather than raised so the caller can report EVERY bad record
    at once. Failing on the first missing source_url turns one fix into N round trips
    through a full re-chunk.
    """
    ids: list[str] = []
    documents: list[str] = []
    metadatas: list[dict] = []
    problems: list[str] = []
    seen: set[str] = set()

    for i, rec in enumerate(records):
        chunk_id = str(rec.get("chunk_id") or "").strip()
        if not chunk_id:
            problems.append(f"record {i} has no chunk_id")
            continue
        # Reuse the chunker's content-hash chunk_id as the Chroma id. That is what makes
        # re-running idempotent: same corpus in, same ids out, so upsert overwrites in
        # place instead of appending a second copy of the collection.
        if chunk_id in seen:
            problems.append(f"duplicate chunk_id {chunk_id!r}")
            continue

        # Non-negotiable. A chunk with no source_url is unciteable, and an unciteable
        # passage is exactly what this knowledge base exists to avoid, so it is a hard
        # gate, not a warning.
        if not str(rec.get("source_url") or "").strip():
            problems.append(f"chunk {chunk_id} has no source_url")
            continue

        text = document_text(rec)
        if not text.strip():
            problems.append(f"chunk {chunk_id} has no text")
            continue

        seen.add(chunk_id)
        ids.append(chunk_id)
        documents.append(text)
        metadatas.append(build_metadata(rec))

    return ids, documents, metadatas, problems


def batches(total: int, size: int):
    """Yield (start, end) slice bounds. Extracted so --self-test can prove the last
    partial batch is not dropped, the classic off-by-one that silently loses records."""
    for start in range(0, total, size):
        yield start, min(start + size, total)


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

def verify_collection(collection, expected_count: int | None) -> bool:
    """Prove the collection's citability instead of asserting it.

    Three gates:

      1. COUNT matches the input, so nothing was silently dropped mid-batch.
      2. Every record carries a non-empty source_url, so every hit is citable.
      3. A live query RETURNS DOCUMENT TEXT. A collection that answers queries but
         returns no text cannot ground anything, and nothing else would notice.
    """
    step("Verifying citability")
    passed = True

    count = collection.count()
    if expected_count is None:
        info(f"'{COLLECTION_NAME}' holds {count} chunks (no input count to compare)")
    elif count == expected_count:
        ok(f"count matches input: {count} chunks")
    else:
        warn(f"count is {count} but the input holds {expected_count} chunks")
        passed = False

    if count == 0:
        warn("collection is empty, so there is nothing to verify")
        return False

    # Page through everything rather than sampling. A thousand records is small, and a
    # source_url gate that only inspects the first page passes while the tail is broken.
    missing_url: list[str] = []
    empty_docs: list[str] = []
    scanned = 0
    for start, end in batches(count, UPSERT_BATCH):
        page = collection.get(
            limit=end - start,
            offset=start,
            include=["metadatas", "documents"],  # documents INCLUDED: text is the point.
        )
        page_ids = page.get("ids") or []
        page_metas = page.get("metadatas") or []
        page_docs = page.get("documents") or []
        for i, rec_id in enumerate(page_ids):
            scanned += 1
            meta = page_metas[i] if i < len(page_metas) else {}
            doc = page_docs[i] if i < len(page_docs) else ""
            if not str((meta or {}).get("source_url") or "").strip():
                missing_url.append(str(rec_id))
            if not str(doc or "").strip():
                empty_docs.append(str(rec_id))

    if missing_url:
        warn(f"{len(missing_url)} of {scanned} chunks have no source_url "
             f"(first: {missing_url[:3]})")
        passed = False
    else:
        ok(f"all {scanned} chunks carry a non-empty source_url")

    if empty_docs:
        warn(f"{len(empty_docs)} of {scanned} chunks have no stored text "
             f"(first: {empty_docs[:3]})")
        passed = False
    else:
        ok(f"all {scanned} chunks retain their full text as Chroma documents")

    # The retrieval-shaped proof. Every answer you get goes through a query, not a
    # get(), so the query path is what has to be tested.
    hits = collection.query(
        query_texts=["Zero Trust architecture guiding principles"],
        n_results=3,
        include=["documents", "metadatas", "distances"],
    )
    docs = (hits.get("documents") or [[]])[0]
    metas = (hits.get("metadatas") or [[]])[0]

    if not docs or not any(str(d or "").strip() for d in docs):
        warn("a retrieval query returned NO document text, so nothing here is citable")
        passed = False
    else:
        ok("retrieval query returned document text")
        if not all(str((m or {}).get("source_url") or "").strip() for m in metas):
            warn("a retrieved hit carried no source_url")
            passed = False
        else:
            ok("every retrieved hit carried a source_url")
            info("an answer looks like this: quotable, and cited")
            for d, m in zip(docs, metas, strict=False):
                # Strip the context prefix before displaying: what a citation quotes is
                # Microsoft's prose, not the scaffolding this pipeline prepended for the
                # embedding. Showing the prefix would make every sample look alike.
                prose = str(d).split("\n\n", 1)[-1]
                snippet = " ".join(prose.split())[:88]
                info(f"  {m.get('source_url')}")
                info(f"    \"{snippet}...\"")

    return passed


# ---------------------------------------------------------------------------
# Self-test. Must run with no chromadb installed and no data present, because
# tests/run_all.py is a gate you run on a fresh clone. A gate with preconditions is a
# gate that stops being run.
# ---------------------------------------------------------------------------

def self_test() -> int:
    step("Local ingest self-test")

    checks: list[tuple[bool, str]] = []

    checks.append((COLLECTION_NAME == "sc100_learn",
                   f"collection is 'sc100_learn', the name mcp/server.py opens (got {COLLECTION_NAME!r})"))

    # Regression guard for the silent failure described in the module docstring: read
    # this file's own source and assert that every Chroma include= requests documents.
    try:
        source = pathlib.Path(__file__).read_text(encoding="utf-8")
    except OSError:
        source = ""
    checks.append(('include=["metadatas", "documents"]' in source
                   and 'include=["documents", "metadatas", "distances"]' in source,
                   "every Chroma include= requests 'documents' (passages must return text)"))
    checks.append(("source_url" in METADATA_FIELDS,
                   "the metadata allowlist still carries source_url"))

    # --- objective_ids serialization: a LIST into a Chroma-legal scalar. ---
    checks.append((serialize_objective_ids([]) == EMPTY_OBJECTIVE_IDS,
                   "empty objective_ids serializes to the unclassified sentinel"))
    checks.append((serialize_objective_ids(["2.1.4", "2.1.3"]) == ",2.1.3,2.1.4,",
                   f"objective_ids sort and get sentinel commas "
                   f"(got {serialize_objective_ids(['2.1.4', '2.1.3'])!r})"))
    checks.append((isinstance(serialize_objective_ids(["1.1.1"]), str),
                   "objective_ids becomes a scalar string, which is all Chroma accepts"))
    checks.append((",2.1.3," in serialize_objective_ids(["2.1.3"])
                   and ",2.1.3," not in serialize_objective_ids(["12.1.30"]),
                   "sentinel commas stop '2.1.3' matching '12.1.30'"))

    # --- Metadata projection keeps text OUT of metadata but IN the document. ---
    sample = {
        "chunk_id": "abc123",
        "exam_domain": 2,
        "domain_weight": "25-30%",
        "learning_path": "LP_02",
        "module_title": "Design solutions for identity",
        "unit_title": "External identities",
        "section_title": "B2B collaboration",
        "source_url": "https://learn.microsoft.com/en-us/training/modules/x/1-y",
        "content_type": "concept",
        "unit_id": "unit-1",
        "chunk_index": 0,
        "objective_ids": ["2.1.3"],
        "context_prefix": "Learning path: LP_02 | Exam domain 2",
        "text": "Microsoft Entra External ID supports B2B collaboration.",
    }
    meta = build_metadata(sample)
    checks.append((meta["source_url"] == sample["source_url"],
                   "source_url is carried into metadata"))
    checks.append((all(isinstance(v, (str, int, float, bool)) for v in meta.values()),
                   "every metadata value is a Chroma-legal scalar"))
    checks.append(("text" not in meta,
                   "text is not duplicated into metadata (it is the document)"))
    checks.append((meta[OBJECTIVE_IDS_KEY] == ",2.1.3,",
                   "objective_ids reaches metadata serialized"))

    doc = document_text(sample)
    checks.append((sample["text"] in doc, "the document retains the full chunk text"))
    checks.append((doc.startswith(sample["context_prefix"]),
                   "context_prefix leads the embedded string"))
    checks.append((doc.split("\n\n", 1)[-1] == sample["text"],
                   "Microsoft's prose is separable from the prefix for citation"))

    # --- prepare(): idempotence key and the source_url gate. ---
    ids, _docs, _metas, problems = prepare([sample, dict(sample)])
    checks.append((ids == ["abc123"] and len(problems) == 1,
                   f"the same chunk_id twice yields one id (got {ids}, {len(problems)} problems)"))
    checks.append((ids[0] == sample["chunk_id"],
                   "the Chroma id IS the chunker's chunk_id, so re-runs upsert in place"))

    no_url = dict(sample, chunk_id="nourl", source_url="")
    ids2, _, _, problems2 = prepare([no_url])
    checks.append((ids2 == [] and any("source_url" in p for p in problems2),
                   "a chunk with no source_url is REJECTED, never silently indexed"))

    no_text = dict(sample, chunk_id="notext", text="", context_prefix="")
    ids3, _, _, _problems3 = prepare([no_text])
    checks.append((ids3 == [], "a chunk with no text is rejected"))

    _good_ids, good_docs, good_metas, good_problems = prepare([sample])
    checks.append((good_problems == [] and len(good_docs) == 1 and len(good_metas) == 1,
                   "a well-formed chunk passes with no problems"))

    # --- Batching: the last partial batch must not be dropped. ---
    bounds = list(batches(1071, UPSERT_BATCH))
    covered = sum(e - s for s, e in bounds)
    checks.append((covered == 1071 and bounds[-1] == (1000, 1071),
                   f"batching covers every record including the remainder (got {bounds[-1]})"))
    checks.append((list(batches(0, UPSERT_BATCH)) == [],
                   "an empty input yields no batches"))
    checks.append((0 < UPSERT_BATCH <= 5000,
                   f"batch size {UPSERT_BATCH} stays under Chroma's per-call cap"))

    # --- Path resolution: CLI is cwd-relative, .env is toolkit-root-relative. ---
    env_resolved = resolve_path(None, "./index/learn-chroma", CHROMA_DIR)
    checks.append((env_resolved == (TOOLKIT_ROOT / "index" / "learn-chroma").resolve(),
                   "a .env path resolves against the toolkit root"))
    default_resolved = resolve_path(None, None, CHROMA_DIR)
    checks.append((default_resolved == (INDEX_DIR / "learn-chroma").resolve(),
                   "the built-in default is index/learn-chroma"))
    checks.append((resolve_path("somewhere.jsonl", "./ignored", CHUNKS_FILE)
                   == pathlib.Path("somewhere.jsonl").expanduser().resolve(),
                   "a CLI path wins and resolves against the cwd"))

    passed = True
    for good, label in checks:
        print(f"           {label} [{'pass' if good else 'FAIL'}]")
        passed = passed and good

    if not passed:
        failures = sum(1 for good, _ in checks if not good)
        print(f"    self-test: FAILED ({failures} of {len(checks)} checks)")
        return 1
    print(f"    self-test: ALL PASS ({len(checks)} checks)")
    ok("passages stay citable")
    return 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--input", default=None,
                    help="Chunk file (default: SC100_CHUNKS from .env, else index/learn-chunks.jsonl)")
    ap.add_argument("--path", default=None,
                    help="Chroma directory (default: SC100_CHROMA_PATH from .env, else index/learn-chroma)")
    ap.add_argument("--reset", action="store_true",
                    help="Drop the existing collection and rebuild from scratch.")
    ap.add_argument("--verify", action="store_true",
                    help="Only verify the existing collection, then exit.")
    ap.add_argument("--limit", type=int, default=None,
                    help="Ingest only the first N chunks (smoke test).")
    ap.add_argument("--self-test", action="store_true",
                    help="Run offline internal tests and exit. Needs no data and no chromadb.")
    args = ap.parse_args()

    # Before anything that touches the filesystem or imports chromadb, so a fresh clone
    # can run the gate.
    if args.self_test:
        return self_test()

    if args.limit is not None and args.limit < 1:
        ap.error("--limit must be 1 or greater")  # argparse exits 2, which is the usage code

    cfg = load_env(required=False)  # the local path needs no .env
    chunks_path = resolve_path(args.input, cfg.get("SC100_CHUNKS"), CHUNKS_FILE)
    chroma_path = resolve_path(args.path, cfg.get("SC100_CHROMA_PATH"), CHROMA_DIR)

    try:
        import chromadb
    except ImportError:
        fail("chromadb is not installed.", "Run: uv sync")

    step("Opening the local collection")
    info(f"path {chroma_path}")
    info(f"collection '{COLLECTION_NAME}'")
    chroma_path.parent.mkdir(parents=True, exist_ok=True)
    client = chromadb.PersistentClient(path=str(chroma_path))

    if args.verify:
        try:
            collection = client.get_collection(COLLECTION_NAME)
        except Exception:  # noqa: BLE001 - chromadb raises different types across versions
            fail(f"Collection '{COLLECTION_NAME}' does not exist yet.",
                 "Run: uv run python tools/ingest_local.py")
        # Compare against the input file when it is present, so --verify catches a
        # partial ingest rather than merely confirming whatever is there is well formed.
        expected = None
        if chunks_path.is_file():
            expected = sum(1 for line in chunks_path.open(encoding="utf-8") if line.strip())
            info(f"input {chunks_path.name} holds {expected} chunks")
        return 0 if verify_collection(collection, expected) else 1

    if args.reset:
        try:
            client.delete_collection(COLLECTION_NAME)
            ok("dropped the existing collection")
        except Exception:  # noqa: BLE001
            info("no existing collection to drop")

    # No embedding_function argument: Chroma's default runs a small sentence transformer
    # LOCALLY via ONNX. The reason is cost and reproducibility: zero dollars, no
    # `az login`, no network after the first model download, and the same vectors on a
    # plane as in CI. mcp/server.py embeds queries with the same default, which is what
    # makes query and document vectors comparable.
    collection = client.get_or_create_collection(
        name=COLLECTION_NAME,
        metadata={
            "source": "Microsoft Learn SC-100 training, downloaded for personal study",
            "egress_rule": "full text may ground answers; always cite source_url",
        },
    )

    step("Loading chunks")
    info(f"input {chunks_path}")
    records = load_chunks(chunks_path, limit=args.limit)
    ok(f"{len(records)} chunk records")
    if args.limit is not None:
        warn(f"--limit {args.limit} is a smoke test; the collection will be incomplete")

    domains: dict = {}
    for r in records:
        key = r.get("exam_domain", "?")
        domains[key] = domains.get(key, 0) + 1
    for domain, n in sorted(domains.items(), key=lambda kv: str(kv[0])):
        info(f"  {n:>4} chunks  exam domain {domain}")

    step("Preparing records")
    ids, documents, metadatas, problems = prepare(records)
    if problems:
        for p in problems[:10]:
            warn(p)
        if len(problems) > 10:
            warn(f"...and {len(problems) - 10} more")
        # source_url is the property this knowledge base exists for, so a missing one is
        # a gate, not a skip. Indexing an unciteable chunk is worse than indexing nothing.
        if any("source_url" in p for p in problems):
            fail("Some chunks have no source_url, so they cannot be cited.",
                 "Re-run tools/chunk_learn.py. Every chunk must carry a source URL.")
    ok(f"{len(ids)} records ready, every one carrying a source_url")

    step("Embedding locally")
    info("model: Chroma default sentence transformer, ONNX, on this machine")
    info("zero cost, no Azure resource")

    for start, end in batches(len(ids), UPSERT_BATCH):
        # upsert, not add: the chunker's content-hash chunk_id is the Chroma id, so a
        # re-run overwrites in place. Re-ingesting the same corpus cannot duplicate.
        collection.upsert(
            ids=ids[start:end],
            documents=documents[start:end],
            metadatas=metadatas[start:end],
        )
        info(f"embedded {end}/{len(ids)}")

    ok(f"{collection.count()} chunks in '{COLLECTION_NAME}'")

    if not verify_collection(collection, len(ids) if args.limit is None else None):
        fail("The citability check FAILED. Fix it before you rely on answers from this "
             "collection.")

    print(
        "\nThe Learn corpus is indexed locally and every passage is citable.\n"
        "\nNext: uv run python mcp/server.py --self-test\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
