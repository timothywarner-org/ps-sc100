# How the pipeline works

The pipeline turns Microsoft Learn's free SC-100 training into a searchable, citable
knowledge base in four stages: download, chunk, index, serve. Every stage runs on your
machine, and every passage that comes out the far end carries the URL of the Learn page it
came from. This page explains what each stage does and why it is built the way it is. For
setup commands, see the [README](../README.md).

```
  Microsoft Learn ──▶ corpus/ ──▶ index/learn-chunks.jsonl ──▶ index/learn-chroma ──▶ MCP server ──▶ your assistant
   (SC-100T00)      download        chunk_learn.py              ingest_local.py      mcp/server.py
                                          │
                                          └──▶ search_keyword.py   (no install, BM25 + exact phrase)
```

---

## Stage 1: download

`scripts/Get-SC100Corpus.ps1` clones the
[microsoft-courses-downloader](https://github.com/timothywarner-org/microsoft-courses-downloader)
into `.cache/`, gives it its own virtual environment, and asks it for course SC-100T00.
The downloader calls the Microsoft Learn Catalog API, resolves the course to its four
learning paths, and writes one Markdown file per module. Each unit starts with a
`## N. Title` heading and a `Source:` line holding its Learn URL. That `Source:` line is
the most valuable line in the corpus, because it is what makes every later passage
citable.

The script then checks the shape of what landed (four learning paths) rather than trusting
the downloader's exit code. A partial download looks complete and silently under-reports
coverage.

## Stage 2: chunk

`tools/chunk_learn.py` cuts each unit at its authored H2/H3 sections, absorbs signpost
headings and headless preamble into the section that follows, splits the rare oversize
section on paragraph boundaries, and drops the near-identical "Knowledge check" stubs. The
result is 1,071 chunks with a median of 219 estimated tokens, every one carrying its
`source_url`. [ADR-002](ADR-002-chunking-strategy.md) has the measurements behind every
threshold, including the bug that fused *Microsoft Entra Internet Access* and *Microsoft
Entra Private Access* into one chunk and the sweep that set the signpost ceiling.

Two properties matter most:

- **The domain inversion is applied here, by lookup table.** Learn path `03` is exam
  Domain 4 and Learn path `04` is exam Domain 3. Every chunk records the **exam** domain,
  and a validation gate fails the run if any chunk carries the wrong mapping.
- **Output is deterministic.** Chunk IDs are content hashes, and the file is written with
  fixed line endings, so the same corpus produces a byte-identical file on Windows,
  macOS, and Linux. A changed coverage number therefore means a changed corpus, never a
  changed run.

The chunker uses only the standard library, so it runs before you install anything.

## Stage 3: index

`tools/ingest_local.py` embeds every chunk into a local Chroma collection named
`sc100_learn`, using Chroma's default sentence transformer through ONNX on your machine.
The embedded string is the chunk's `context_prefix` (learning path, domain, module, unit,
section) followed by its text, so a section that opens "This approach is preferred
when..." still knows what it is about. The prefix is separable at citation time, so a
quote is always Microsoft's prose and never the scaffolding.

After upserting, the script proves citability rather than asserting it: the count matches
the input, every record has a `source_url`, and a live query returns document text.

`tools/extract_objectives.py` runs alongside this stage. It parses the 81 skills-measured
objectives from `../docs/SC-100-Skills-Measured.md` into `index/objectives.json`, gated on
Microsoft's published counts (4 domains, 14 groups, 81 statements). The MCP server reads
that file to give objective-shaped queries the same context the chunks got.

## Stage 4: serve

`mcp/server.py` exposes four tools over the MCP stdio transport:

| Tool | What you use it for |
|---|---|
| `sc100_search_learn` | Ground any answer in Microsoft's own words, with a `source_url` on every passage |
| `sc100_objective_coverage` | See how deeply Learn covers one objective, graded thin, adequate, or strong |
| `sc100_coverage_sweep` | Find the objectives the free training covers thinly, so you study those from the product docs |
| `sc100_check_currency` | Catch retired product names and preview features before they cost you an exam item |

A few design choices are worth knowing about:

- **Coverage grades on relevance, not result count.** A vector search always returns
  `depth` results, because something is always nearest. The first version graded on how
  many came back and could never report "thin". The current grade counts only passages
  above a calibrated score floor; the calibration table is in the source.
- **Scores are recovered cosine similarity.** The collection uses Chroma's default
  squared-L2 distance over unit vectors, which is exactly twice the cosine distance. The
  server converts it back and scales it to 0 to 4, and its self-test fails if the stored
  metric ever changes underneath the formula.
- **Objective queries are expanded; your searches are not.** An objective written in
  product-neutral language ("Specify security requirements for web workloads") gets its
  functional-group title prepended, which lifted the weakest matches substantially. A
  search for a named product passes through untouched.
- **Section hits roll up to their parent unit.** You match on precise sections and read
  whole units.

## The optional Azure path

Everything above is free. The Azure path swaps the local store for Azure AI Search, which
runs BM25 and vector search together and re-orders the result with a semantic ranker. It
lives in `infra/` (Bicep plus deploy and teardown scripts) and three tools:
`tools/create_index.py`, `tools/ingest_azure.py`, and the optional snapshot archive
`tools/sync_corpus.py` ([ADR-003](ADR-003-source-archive.md)). Every service it deploys
refuses API keys; every caller authenticates with Microsoft Entra ID through
`DefaultAzureCredential`. [ADR-001](ADR-001-vector-store.md) explains when that upgrade is
worth its hourly cost.

---

## File map

```
toolkit/
  README.md                     Start here
  pyproject.toml, uv.lock       Dependencies with documented floors; exact pins
  .env.example                  Every setting, with its default (the local path needs none)
  .python-version               The interpreter the lock was verified against

  scripts/
    Get-SC100Corpus.ps1         Download the Learn training into corpus/

  tools/
    chunk_learn.py              Structure-aware chunker. Standard library only
    search_keyword.py           BM25 + exact-phrase search. Standard library only
    extract_objectives.py       Skills-measured outline -> index/objectives.json
    ingest_local.py             Local Chroma embedding, with citability verification
    create_index.py             Azure path: index schema (hybrid + semantic + vectorizer)
    ingest_azure.py             Azure path: batched embedding, merge-or-upload, read-back
    sync_corpus.py              Azure path: private, versioned corpus snapshots
    _common.py                  Shared paths, console output, config, Entra auth

  mcp/
    server.py                   The four-tool MCP server
    claude_desktop_config.example.json

  tests/
    run_all.py                  Every self-test, one verdict, fully offline

  infra/
    main.bicep, main.bicepparam Foundry + embedding deployment, AI Search, storage, RBAC
    deploy.ps1 / deploy.sh      Cost gate, deploy, write .env from the outputs
    teardown.ps1 / teardown.sh  Stop the billing. Leaves every local file intact

  docs/
    ADR-001-vector-store.md     Why local Chroma is the default
    ADR-002-chunking-strategy.md  Why section-level chunks, with the measurements
    ADR-003-source-archive.md   Why the snapshot archive is never an ingestion source
    PIPELINE.md                 This page

  corpus/   (gitignored)        Your downloaded copy of the training
  index/    (gitignored)        Chunks, objectives, and the vector store, all regenerable
  .cache/   (gitignored)        The downloader clone
```

---

## Known limits

- **The corpus is a dated snapshot of training modules, not live product documentation.**
  The currency scan can only be as current as your last download, and a claim missing
  from the corpus may still be true in the product docs.
- **Dense retrieval blurs near-identical product names.** Search by exact name, read the
  `source_url` before quoting, and use `search_keyword.py phrase` to pin a name.
- **`objective_ids` is empty.** Mapping chunks to objectives is a classification pass
  deliberately kept out of the deterministic stages. The fields exist so that pass is a
  merge, not a rebuild.
- **Chroma downloads its embedding model on first use** (about 80 MB). After that, the
  local path is fully offline.
- **Objective IDs are positional.** They are stable against one version of the
  skills-measured outline. When Microsoft revises it, regenerate `objectives.json`.
