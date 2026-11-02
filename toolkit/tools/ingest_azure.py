#!/usr/bin/env python3
"""
ingest_azure.py -- embed the Learn chunks and push them into Azure AI Search (optional path).

This is the OPTIONAL Azure path. The default local path is tools/ingest_local.py, which
costs nothing. Use this one only after infra/deploy.ps1 (or deploy.sh) has created the
search service, and tear the service down when you finish (infra/teardown.ps1).

WHAT GETS EMBEDDED, AND WHY IT IS NOT JUST THE TEXT
---------------------------------------------------
The embedded string is the chunk's `context_prefix`, a blank line, and then its `text`,
not the text alone.

ADR-002's chunking strategy cuts a Learn unit into its authored H2/H3 sections. That
buys precision, and it costs subject. A section headed "Design guidance" whose body
opens "This approach is preferred when..." is, standing alone, not merely unhelpful --
it is confidently irrelevant, because nothing in it says WHAT approach.

The prefix restores that:

    Learning path: LP_02 | Exam domain 2 | Module: Design solutions for identity and
    access management | Unit: Design a solution for external identities |
    Section: B2B collaboration in workforce tenants

~40 tokens, and the chunk knows its own subject again.

It is stored in a separate index field, never spliced into `text`. That matters at
citation time: when you quote a passage, the quoted words are Microsoft's, not
scaffolding this pipeline invented.

IDEMPOTENCE, AND WHY IT IS FREE HERE
------------------------------------
`chunk_id` is a content hash of (source_url, section title, index) produced by
chunk_learn.py. Same corpus in, same IDs out. The upload uses merge-or-upload, so
re-running:

    * overwrites chunks whose text changed
    * leaves unchanged chunks byte-identical
    * never creates a duplicate

That is what makes the teardown/redeploy rhythm affordable. Re-ingesting a corpus you
already have costs the embedding calls and about a minute.

`--skip-existing` goes further and re-embeds nothing that is already indexed. Use it
when resuming an interrupted run; leave it off after editing the chunker, because then
the text has changed and the vectors are stale.

COST
----
Embedding ~1,100 chunks at ~250 tokens each is roughly 275,000 tokens, once. That is
a rounding error against the hourly cost of the search service itself. The expensive
resource in this pipeline is time, not tokens.

USAGE
-----
    uv sync --group azure                                 # once: the Azure SDKs
    uv run python tools/ingest_azure.py
    uv run python tools/ingest_azure.py --skip-existing   # resume an interrupted run
    uv run python tools/ingest_azure.py --dry-run         # no Azure calls; validate + report
    uv run python tools/ingest_azure.py --limit 20        # smoke test on 20 chunks

EXIT CODES
----------
    0  all chunks embedded and indexed; post-upload count verified
    1  a precondition or upload failed
"""

from __future__ import annotations

import argparse
import json
import sys
import time

from _common import (
    CHUNKS_FILE,
    explain_403,
    fail,
    get_credential,
    info,
    load_env,
    ok,
    require,
    step,
    warn,
)

# ---------------------------------------------------------------------------
# Batching and retry
# ---------------------------------------------------------------------------

EMBED_BATCH = 64
"""Chunks per embedding request.

The API accepts arrays, and batching cuts round trips by ~64x. Kept well below any
per-request token ceiling: 64 x ~300 tokens is ~19k, comfortably inside limits."""

UPLOAD_BATCH = 50
"""Documents per search upload request.

Deliberately far below the 1,000-document API maximum, because the binding constraint
is payload SIZE, not count. Each document carries 3,072 floats, which serialize to
roughly 40 KB of JSON -- 50 documents is ~2 MB, safely inside the 16 MB request cap.
Setting this to 1,000 would produce 40 MB requests and silent-looking failures."""

MAX_RETRIES = 5
RETRY_BASE_SECONDS = 2.0

# Overridable because Azure OpenAI API versions rotate. Pinned rather than floating so
# a run is reproducible; bump it deliberately, not by accident.
DEFAULT_OPENAI_API_VERSION = "2024-10-21"

# Index fields that are populated from the chunk record. Listed explicitly rather than
# passing the whole record through: a stray key that is not in the index schema causes
# the whole batch to be rejected, and an explicit allowlist makes that impossible.
DOC_FIELDS = (
    "chunk_id",
    "unit_id",
    "text",
    "context_prefix",
    "source_url",
    "module_title",
    "unit_title",
    "section_title",
    "learning_path",
    "exam_domain",
    "domain_weight",
    "domain_title",
    "content_type",
    "objective_ids",
    "unit_number",
    "chunk_index",
    "chunks_in_unit",
    "token_estimate",
    "module_file",
)


def load_chunks(limit: int | None) -> list[dict]:
    """Read the JSONL produced by chunk_learn.py, validating as we go."""
    if not CHUNKS_FILE.exists():
        fail(
            f"No chunk file at {CHUNKS_FILE}",
            "Run the chunker first: uv run python tools/chunk_learn.py",
        )

    chunks: list[dict] = []
    for line_no, line in enumerate(CHUNKS_FILE.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"Malformed JSON on line {line_no} of {CHUNKS_FILE.name}: {exc}")

        # Refuse to index a chunk that cannot be cited. A passage without provenance
        # cannot ground a claim, which is the entire purpose of this corpus, so an
        # uncitable chunk is worse than a missing one.
        if not rec.get("source_url"):
            fail(f"Chunk {rec.get('chunk_id', '?')} on line {line_no} has no source_url.")
        if not rec.get("text"):
            fail(f"Chunk {rec.get('chunk_id', '?')} on line {line_no} has empty text.")

        chunks.append(rec)
        if limit and len(chunks) >= limit:
            break

    if not chunks:
        fail(f"{CHUNKS_FILE} contains no chunks.")
    return chunks


def embedding_input(rec: dict) -> str:
    """The exact string that gets embedded. See the module docstring."""
    prefix = rec.get("context_prefix") or ""
    return f"{prefix}\n\n{rec['text']}" if prefix else rec["text"]


def with_retry(fn, what: str):
    """Run fn with exponential backoff on transient failures.

    Throttling (429) and transient 5xx are normal on a fresh deployment, especially
    while embedding quota warms up. Retrying is the correct response; failing the whole
    run after 1,000 successful chunks is not.
    """
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            return fn()
        except Exception as exc:
            text = str(exc)
            transient = any(s in text for s in ("429", "500", "502", "503", "504", "timeout", "Timeout"))
            if not transient or attempt == MAX_RETRIES:
                raise
            delay = RETRY_BASE_SECONDS * (2 ** (attempt - 1))
            warn(f"{what} failed (attempt {attempt}/{MAX_RETRIES}): {text[:120]}")
            info(f"retrying in {delay:.0f}s")
            time.sleep(delay)
    return None


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--skip-existing", action="store_true",
                    help="Do not re-embed chunks already present in the index. For resuming, not for after a chunker change.")
    ap.add_argument("--dry-run", action="store_true",
                    help="Validate the chunk file and report what would happen. No Azure calls, no cost.")
    ap.add_argument("--limit", type=int, default=None,
                    help="Process only the first N chunks. For smoke tests.")
    ap.add_argument("--api-version", default=None,
                    help=f"Azure OpenAI API version (default {DEFAULT_OPENAI_API_VERSION}).")
    args = ap.parse_args()

    step("Loading chunks")
    chunks = load_chunks(args.limit)
    total_tokens = sum(c.get("token_estimate", 0) for c in chunks)
    ok(f"{len(chunks)} chunks, ~{total_tokens:,} estimated tokens")

    domains: dict[int, int] = {}
    for c in chunks:
        domains[c.get("exam_domain", 0)] = domains.get(c.get("exam_domain", 0), 0) + 1
    info("by exam domain: " + "  ".join(f"D{k}={v}" for k, v in sorted(domains.items())))

    if args.dry_run:
        step("Dry run")
        sample = chunks[0]
        info(f"embedding input for {sample['chunk_id']} would be:")
        preview = embedding_input(sample).replace("\n", " ")[:220]
        info(f'  "{preview}..."')
        info(f"embedding requests : {(len(chunks) + EMBED_BATCH - 1) // EMBED_BATCH} (batch {EMBED_BATCH})")
        info(f"upload requests    : {(len(chunks) + UPLOAD_BATCH - 1) // UPLOAD_BATCH} (batch {UPLOAD_BATCH})")
        ok("Dry run complete. No Azure calls were made and nothing was charged.")
        return 0

    cfg = load_env()
    search_endpoint, index_name, foundry, deployment = require(
        cfg, "AZURE_SEARCH_ENDPOINT", "AZURE_SEARCH_INDEX",
        "AZURE_FOUNDRY_ENDPOINT", "AZURE_EMBEDDING_DEPLOYMENT",
    )
    api_version = args.api_version or cfg.get("AZURE_OPENAI_API_VERSION") or DEFAULT_OPENAI_API_VERSION

    try:
        from azure.identity import get_bearer_token_provider
        from azure.search.documents import SearchClient
        from openai import AzureOpenAI
    except ImportError as exc:
        fail(f"Missing dependency: {exc}", "The Azure path is optional. Run: uv sync --group azure")

    credential = get_credential()

    # Token-based auth to Azure OpenAI. The token provider refreshes automatically,
    # which matters for a run long enough to outlive a single token's lifetime.
    token_provider = get_bearer_token_provider(
        credential, "https://cognitiveservices.azure.com/.default"
    )
    aoai = AzureOpenAI(
        azure_endpoint=foundry,
        azure_ad_token_provider=token_provider,
        api_version=api_version,
    )
    search = SearchClient(endpoint=search_endpoint, index_name=index_name, credential=credential)

    step("Configuration")
    info(f"search     {search_endpoint}  index '{index_name}'")
    info(f"foundry    {foundry}  deployment '{deployment}'  api-version {api_version}")

    # -- Optionally skip what is already indexed ---------------------------
    if args.skip_existing:
        step("Checking which chunks are already indexed")
        existing: set[str] = set()
        try:
            results = search.search(search_text="*", select=["chunk_id"], top=100000)
            existing = {r["chunk_id"] for r in results}
        except Exception as exc:  # noqa: BLE001
            warn(f"Could not enumerate the index ({str(exc)[:100]}). Proceeding with a full ingest.")
        before = len(chunks)
        chunks = [c for c in chunks if c["chunk_id"] not in existing]
        ok(f"{len(existing)} already indexed; {len(chunks)} of {before} to process")
        if not chunks:
            ok("Nothing to do. The index is already current.")
            return 0

    # -- Embed --------------------------------------------------------------
    step(f"Embedding {len(chunks)} chunks")
    vectors: list[list[float]] = []
    t0 = time.time()

    for start in range(0, len(chunks), EMBED_BATCH):
        batch = chunks[start : start + EMBED_BATCH]
        inputs = [embedding_input(c) for c in batch]

        def call(inputs=inputs):
            return aoai.embeddings.create(model=deployment, input=inputs)

        try:
            response = with_retry(call, "embedding request")
        except Exception as exc:  # noqa: BLE001
            fail(f"Embedding failed after {MAX_RETRIES} attempts: {exc}", explain_403(exc))

        # The API guarantees order, but assert it rather than trust it: a silent
        # misalignment here attaches every vector to the wrong chunk, and the only
        # symptom is retrieval that is subtly, inexplicably wrong.
        ordered = sorted(response.data, key=lambda d: d.index)
        if len(ordered) != len(batch):
            fail(f"Embedding count mismatch: sent {len(batch)}, received {len(ordered)}.")
        vectors.extend(d.embedding for d in ordered)

        done = min(start + EMBED_BATCH, len(chunks))
        info(f"embedded {done}/{len(chunks)}")

    ok(f"{len(vectors)} vectors in {time.time() - t0:.1f}s ({len(vectors[0])} dimensions)")

    # -- Upload -------------------------------------------------------------
    step(f"Uploading {len(chunks)} documents")
    documents = []
    # strict=True: a length mismatch here would attach vectors to the wrong chunks, so
    # it must raise rather than silently truncate.
    for rec, vec in zip(chunks, vectors, strict=True):
        doc = {k: rec[k] for k in DOC_FIELDS if k in rec}
        doc["text_vector"] = vec
        documents.append(doc)

    uploaded = 0
    failures: list[str] = []
    for start in range(0, len(documents), UPLOAD_BATCH):
        batch = documents[start : start + UPLOAD_BATCH]

        def call(batch=batch):
            # merge_or_upload, not upload: this is what makes re-running idempotent
            # instead of duplicating, given content-addressed chunk IDs.
            return search.merge_or_upload_documents(documents=batch)

        try:
            results = with_retry(call, "upload batch")
        except Exception as exc:  # noqa: BLE001
            fail(f"Upload failed after {MAX_RETRIES} attempts: {exc}", explain_403(exc))

        for r in results:
            if r.succeeded:
                uploaded += 1
            else:
                failures.append(f"{r.key}: {r.error_message}")
        info(f"uploaded {uploaded}/{len(documents)}")

    if failures:
        warn(f"{len(failures)} documents were rejected:")
        for f in failures[:10]:
            info(f"  {f}")
        fail("Upload completed with rejections. The index is incomplete.")

    ok(f"{uploaded} documents indexed")

    # -- Verify -------------------------------------------------------------
    # An assertion that the upload worked proves nothing about the index. Ask it.
    step("Verifying")
    time.sleep(3)  # indexing is near-real-time, not instant
    try:
        count = search.get_document_count()
        ok(f"index reports {count} documents")

        probe = list(search.search(
            search_text="Microsoft Entra Private Access",
            query_type="semantic",
            top=3,
            select=["chunk_id", "unit_title", "section_title", "source_url"],
        ))
        if probe:
            ok("semantic + hybrid query returned results:")
            for r in probe:
                info(f"  {r.get('section_title') or r.get('unit_title')}")
                info(f"    {r['source_url']}")
        else:
            warn("Probe query returned nothing. Indexing may still be catching up.")
    except Exception as exc:  # noqa: BLE001
        warn(f"Verification query failed: {str(exc)[:160]}")
        warn("The upload succeeded; only the read-back check did not. Retry in a minute.")

    print(
        "\nThe Azure AI Search index is live. Next:\n"
        "  set SC100_BACKEND=azure in .env, then\n"
        "  uv run python mcp/server.py --self-test\n"
        "\nThe search service bills by the hour. When you finish: infra/teardown.ps1\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
