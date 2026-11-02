#!/usr/bin/env python3
"""
chunk_learn.py -- structure-aware chunker for the SC-100 Microsoft Learn corpus.

WHY THIS EXISTS
---------------
An early sizing pass put this corpus at "~150-200 chunks, chunk unit = MS Learn unit."
That estimate is wrong, and the failure is silent, so it is worth stating plainly before
the code.

Measured across the real corpus (168 units, 4 learning paths):

    median unit   1,962 est. tokens
    p90 unit      3,286 est. tokens
    max unit      4,738 est. tokens
    82 of 168 units (49%) exceed 2,000 tokens

Nothing here breaks an embedding model. text-embedding-3-large accepts 8,191 tokens,
so every unit *fits*. That is exactly why the problem is easy to miss.

The real failure is retrieval precision. An embedding is a single point in vector
space. Embedding a 3,000-token unit produces the CENTROID of every idea in it --- a
blurry average of a dozen distinct concepts. This particular corpus is unusually
hostile to that blur, because its discriminating queries are near-identical proper
nouns:

    Microsoft Entra Internet Access   vs   Microsoft Entra Private Access
    Microsoft Defender for Storage    vs   Microsoft Defender for Databases
    MCSB v1 (GA)                      vs   MCSB v2 (preview, carries AI controls)
    Secure Score                      vs   Cloud Secure Score

Those pairs already sit close together in embedding space. Averaging each one into a
3,000-token centroid moves them closer still. The chunk boundary is therefore the
retrieval decision with the biggest effect in this pipeline --- bigger than the choice
of embedding model, and bigger than the choice of vector store.

THE STRATEGY: section-level chunk, unit-level envelope
------------------------------------------------------
Microsoft already marked the semantic boundaries for us. Every Learn unit is internally
divided by H2/H3 subheads that its own authors wrote. We split there.

    1. Split each unit on its internal H2/H3 subheads (NOT the "## N. Title" unit header)
    2. A section with an authored heading AND real body text stands alone, always.
       The heading is the author's own boundary; size must never override it.
    3. Absorb forward the two things that carry no author signal: headless preamble
       prose, and SIGNPOST headings (a heading with no body of its own, e.g.
       "## Technology pillars" immediately followed by "### Identity").
    4. Recursively split any chunk over HARD_CEILING tokens on paragraph boundaries
       -- affects <1% of chunks
    5. Drop "Module assessment" / "Knowledge check" stubs -- ~50 tokens of pure
       boilerplate each, near-duplicates of one another, and therefore active
       retrieval poison: they would match everything and inform nothing

Then embed the SECTION but return the UNIT. Each chunk carries `unit_id`, so the MCP
retrieval layer matches on precise sections and rolls up to the coherent unit for the
answer payload. Precision on the way in, coherence on the way out. This is the
small-to-big / parent-child pattern, and in Azure AI Search `unit_id` is a filterable
field, not a JSON blob you have to post-process.

CONTEXTUAL PREFIXING -- the part most pipelines skip
-----------------------------------------------------
A mid-unit section titled "Design guidance" whose body opens "This approach is
preferred when..." is meaningless in isolation. It has lost its subject. Retrieved
cold, it is worse than useless -- it is confidently irrelevant.

So each chunk gets a synthetic header prepended BEFORE embedding:

    Learning path: LP_02 | Exam domain 2 | Module: ... | Unit: ... | Section: ...

That costs ~40 tokens and restores the subject the section lost when we cut it out of
its unit. It is stored in its own field (`context_prefix`), separate from `text`, so
citations quote the real Microsoft prose and never the scaffolding we invented.

THE DOMAIN INVERSION -- read this before touching DOMAIN_MAP
-------------------------------------------------------------
Microsoft Learn's learning-path numbering is NOT the exam study guide's domain
numbering. Learn path 03 is exam Domain 4. Learn path 04 is exam Domain 3.

This is the highest-consequence bug available in this pipeline, because it is silent:
every chunk indexes fine, every query returns results, and every coverage number built
on top is wrong. So the mapping is an explicit lookup table with a unit test attached
(--self-test), never an inference from the folder name at ingest time.

WHY THIS RUNS LOCALLY AND NOT AS AN AZURE SKILLSET
---------------------------------------------------
Azure AI Search offers structure-aware chunking via the Document Layout skill ->
Text Split skill -> index projections. That path is built to RECOVER structure from
binary documents (PDF, DOCX) where structure was lost. Our corpus is already clean
Markdown that carries H2/H3 headings and a `Source:` URL on every single unit.

Paying Document Intelligence to re-derive structure we already possess would be
backwards, and it puts the `Source:` line -- the most valuable property in this whole
corpus -- at risk of being swallowed as body text. It also makes chunking
non-reproducible: you cannot git-diff a skillset's output, so you cannot tell whether
a coverage number changed because the corpus changed or because the chunker did.

Chunk here, deterministically, in code you can read and test. Push the results. Keep
integrated vectorization for QUERY-time embedding only, where it genuinely earns its
keep by letting the MCP server send plain text.

OUTPUT CONTRACT
---------------
    index/learn-chunks.jsonl        One JSON record per chunk. The ingestion artifact.
    index/learn-chunks.stats.json   Distribution + provenance report. The evidence.

Chunk IDs are content-addressed (source_url + section path), so re-running on an
unchanged corpus produces byte-identical IDs. That makes the index incrementally
updatable and the whole step idempotent.

This script imports nothing outside the standard library, so it runs on a bare Python
3.10+ with no virtual environment.

USAGE
-----
    python tools/chunk_learn.py                  # corpus/ in, index/ out (the defaults)
    python tools/chunk_learn.py --report-only    # measure, write nothing
    python tools/chunk_learn.py --self-test      # domain map + splitter tests
    python tools/chunk_learn.py --input "<folder>/Microsoft Cybersecurity Architect" --output <dir>

EXIT CODES
----------
    0  chunked successfully, all validation gates passed
    1  a validation gate failed (oversize chunk, missing provenance, bad domain map)
    2  usage / input error
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import statistics
import sys
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Tuning constants.
#
# These are not arbitrary. Each was chosen against the measured distribution of
# THIS corpus and is re-validated by the stats report on every run. If you change
# one, re-read the report before believing the result.
# ---------------------------------------------------------------------------

MERGE_FLOOR = 350
"""Applies to HEADLESS preamble text only. See merge_small() for why that matters.

An earlier version of this script applied this floor to every section, merging any
consecutive run that stayed under it. That was wrong, and the corpus caught it:

    At 350 with no heading check, the chunker fused three consecutive sections of the
    identity-access unit -- "Microsoft Entra Internet Access", "Microsoft Entra
    Private Access", and "Additional network controls" -- into one 364-token chunk.

That is exactly the near-neighbour pair this entire chunking strategy exists to keep
separable. A query for "Private Access" would return a chunk discussing both products,
handing the disambiguation back to the model -- the failure we set out to design away.

The lesson generalises past this one bug: a size-driven merge rule silently overrides
the author's own semantic judgment. Microsoft gave those two products separate headings
BECAUSE they are contrasted. Trading that signal for a tidier size histogram is a bad
trade. So the floor now governs only unheaded prose, which has no author signal to
override.

The residual worry -- "won't that leave some very small chunks?" -- is real and is
fine. BM25 scores a short, proper-noun-dense chunk extremely well, and this toolkit
offers BM25 twice: tools/search_keyword.py locally, and the optional Azure AI Search
path with its semantic reranker. Dense-only retrieval is the mode that punishes short
chunks, and the MCP server softens that by rolling section hits up to their parent
unit. A small precise chunk costs almost nothing; a large blurry one costs recall on
every neighbouring query."""

SIGNPOST_CEILING = 60
"""A heading whose own body is under this many tokens is a SIGNPOST, not a section.

The heading-is-a-boundary rule above needs exactly one exception, and this is it.
Microsoft's authors use two structurally different kinds of heading:

    A section   "### Microsoft Entra Private Access" + 120 tokens describing it.
                Real content. An authored boundary. Must stand alone.

    A signpost  "## Technology pillars" + nothing, immediately followed by
                "### Identity", "### Endpoints", "### Data". Pure navigation.

Treating a signpost as a section produces a chunk that is a bare heading -- measured
at as low as 3 estimated tokens. That is not "small but precise", it is noise with an
embedding, and it will surface on title-similarity while carrying no information.

So a signpost is absorbed forward into the first real section beneath it, where it
also does useful work: it becomes the parent heading in that chunk's context.

CALIBRATED, NOT GUESSED. The sweep, and the test that decided it:

The failure mode of too HIGH a ceiling is that real sections get absorbed forward and
contrasted products end up in one chunk again. That is invisible in a size histogram,
so it was measured directly -- by counting chunks whose text mentions BOTH halves of a
known near-neighbour pair. A rising count means fusion.

    ceiling   chunks   median   Entra Int./Priv. co-occur   Defender Sto./DB co-occur
        40      1128      209             3 (baseline)              4 (baseline)
        60      1071      219             3                         4
        90       954      259             3                         5   <- fusion starts
       110       875      286             3                         5
       130       798      308             4   <- fusion               5

A non-zero baseline is expected: some sections legitimately discuss both products. The
signal is the INCREASE. 60 is the largest ceiling at which neither pair rises, so 60 is
the value. Re-run the sweep with --signpost-ceiling if the corpus is ever re-scraped."""

HARD_CEILING = 1200
"""Any chunk above this gets recursively split on paragraph boundaries.

Chosen because the measured p99 is ~1,100 tokens: the ceiling sits just above the
99th percentile, so it catches genuine outliers without fragmenting normal sections.
Measured effect on this corpus: 4 chunks, 0.7%."""

STUB_THRESHOLD = 200
"""Units below this many tokens are dropped as navigational boilerplate.

The 19 units this removes are all "Module assessment" or "Knowledge check" landing
pages whose body is a stock sentence telling the learner to answer questions on the
Learn site. They are near-identical to each other, so they would form a tight cluster
that matches broadly and teaches nothing."""

CHARS_PER_TOKEN = 4
"""Token estimate divisor.

Deliberately an ESTIMATE, not a tiktoken call. This script must run with zero
third-party dependencies so it can execute on any machine without a virtualenv.
The 4-chars-per-token heuristic runs ~10% high on technical English with many proper
nouns, which is the safe direction to err: it over-estimates chunk size, so the
ceiling gate triggers early rather than late. Swap in tiktoken if you ever need exact
billing numbers; you do not need them to pick a boundary."""


# ---------------------------------------------------------------------------
# The domain inversion table.
#
# EXPLICIT LOOKUP, NEVER AN INFERENCE. See the module docstring. Covered by --self-test.
# ---------------------------------------------------------------------------

DOMAIN_MAP: dict[str, dict] = {
    "01": {"learning_path": "LP_01", "exam_domain": 1, "domain_weight": "20-25%",
           "domain_title": "Design solutions that align with security best practices and priorities"},
    "02": {"learning_path": "LP_02", "exam_domain": 2, "domain_weight": "25-30%",
           "domain_title": "Design security operations, identity, and compliance capabilities"},
    # The inversion lives on the next two lines. Learn path 03 is exam Domain 4.
    "03": {"learning_path": "LP_03", "exam_domain": 4, "domain_weight": "20-25%",
           "domain_title": "Design security solutions for applications and data"},
    # Learn path 04 is exam Domain 3.
    "04": {"learning_path": "LP_04", "exam_domain": 3, "domain_weight": "25-30%",
           "domain_title": "Design security solutions for infrastructure"},
}


# ---------------------------------------------------------------------------
# Parsing patterns
# ---------------------------------------------------------------------------

# A unit header: "## 4. Design a solution for external identities"
UNIT_RE = re.compile(r"^##\s+(\d+)\.\s+(.*?)\s*$")

# A section subhead: any H2/H3 that is NOT a unit header.
# The negative lookahead is what keeps unit headers out of the section list.
SECTION_RE = re.compile(r"^(#{2,3})\s+(?!\d+\.\s)(.*?)\s*$")

# The provenance line. This is the most valuable single line in the corpus.
SOURCE_RE = re.compile(r"^Source:\s+(\S+)\s*$")

# Per-unit boilerplate emitted by the scraper. Stripped from body, never from metadata.
BOILERPLATE_RE = re.compile(r"^(Completed|-\s*\d+\s*minutes?|Source:\s+\S+)\s*$", re.IGNORECASE)


def est_tokens(text: str) -> int:
    """Estimate token count. See CHARS_PER_TOKEN for why this is an estimate."""
    return len(text) // CHARS_PER_TOKEN


def stable_id(*parts: str) -> str:
    """Content-addressed ID.

    Derived from the source URL plus the section path, so the same input always
    produces the same ID. That is what makes re-ingestion idempotent: unchanged
    chunks overwrite themselves in the index instead of duplicating.
    """
    joined = "".join(parts)
    return hashlib.sha1(joined.encode("utf-8")).hexdigest()[:16]


def classify_content(module_filename: str, unit_title: str) -> str:
    """Assign the ADR-001 `content_type` facet.

    Kept deliberately dumb and rule-based. A misclassification here is recoverable
    by re-running; an LLM call here would make the pipeline non-deterministic for
    no gain, since these categories are decidable from the title alone.
    """
    lowered = unit_title.lower()
    if "case study" in module_filename.lower() or "case study" in lowered:
        return "case_study"
    if "knowledge check" in lowered or "module assessment" in lowered:
        return "knowledge_check"
    if lowered == "introduction":
        return "module_intro"
    if lowered == "summary":
        return "module_summary"
    return "concept"


@dataclass
class Section:
    """One H2/H3 section inside a Learn unit, before merging."""
    title: str | None
    lines: list[str] = field(default_factory=list)

    @property
    def text(self) -> str:
        return "\n".join(self.lines).strip()

    @property
    def tokens(self) -> int:
        return est_tokens(self.text)

    @property
    def body_tokens(self) -> int:
        """Tokens excluding the section's own heading line.

        This is what separates a signpost from a section: both may be short, but a
        signpost is short *because it has no body*, while a small section is short
        because its topic is small. Only the first should be absorbed forward.
        """
        body = [ln for ln in self.lines if not SECTION_RE.match(ln)]
        return est_tokens("\n".join(body).strip())


def split_into_sections(body_lines: list[str]) -> list[Section]:
    """Cut one unit's body into sections on its internal H2/H3 subheads.

    Text appearing before the first subhead becomes a leading section with
    title=None -- that is the unit's own introductory prose, and it is usually the
    single most quotable paragraph in the unit, so it must not be discarded.
    """
    head_idx = [i for i, ln in enumerate(body_lines) if SECTION_RE.match(ln)]

    if not head_idx:
        return [Section(title=None, lines=list(body_lines))]

    sections: list[Section] = []
    if head_idx[0] > 0:
        sections.append(Section(title=None, lines=body_lines[: head_idx[0]]))

    for n, start in enumerate(head_idx):
        end = head_idx[n + 1] if n + 1 < len(head_idx) else len(body_lines)
        title = SECTION_RE.match(body_lines[start]).group(2)
        # Keep the heading line in the body: it is real content and it helps BM25,
        # which is doing the heavy lifting on proper-noun queries in hybrid search.
        sections.append(Section(title=title, lines=body_lines[start:end]))

    return sections


def merge_small(sections: list[Section], signpost_ceiling: int = SIGNPOST_CEILING) -> list[Section]:
    """Merge consecutive sections while under MERGE_FLOOR.

    Forward-merge only, and only within the same unit -- a chunk must never span
    two units, because then it has two source URLs and can only cite one of them.
    """
    out: list[Section] = []
    pending: list[Section] = []   # headless prose / signposts waiting for a home

    for sec in sections:
        # A section that carries an authored heading AND real body text ALWAYS stands
        # alone. The heading is the boundary signal; overriding it on total-size grounds
        # is what caused the Entra Internet/Private Access fusion documented above.
        #
        # The two exceptions both lack an author signal to respect:
        #   - headless preamble prose (no heading at all)
        #   - a signpost heading (a heading with no body of its own)
        is_preamble = sec.title is None and sec.tokens < MERGE_FLOOR
        is_signpost = sec.title is not None and sec.body_tokens < signpost_ceiling
        if is_preamble or is_signpost:
            pending.append(sec)
            continue

        if pending:
            lines: list[str] = []
            for p in pending:
                lines.extend([*p.lines, ""])
            sec = Section(title=sec.title, lines=lines + sec.lines)
            pending = []

        out.append(Section(title=sec.title, lines=list(sec.lines)))

    # Trailing headless prose with no following section: attach backward rather than
    # drop it. Losing text silently is the one outcome worse than an odd-shaped chunk.
    if pending:
        if out:
            for p in pending:
                out[-1].lines.extend(["", *p.lines])
        else:
            out.extend(pending)

    return out


def split_oversize(sec: Section) -> list[Section]:
    """Recursively halve an oversize section on paragraph boundaries.

    Splits on blank lines so a chunk edge never lands mid-sentence or mid-table.
    Falls back to returning the section unsplit if it has no internal paragraph
    breaks at all -- better an oversize chunk than one cut through a code block.
    """
    if sec.tokens <= HARD_CEILING:
        return [sec]

    paras: list[list[str]] = [[]]
    for ln in sec.lines:
        if ln.strip() == "":
            if paras[-1]:
                paras.append([])
        else:
            paras[-1].append(ln)
    paras = [p for p in paras if p]

    if len(paras) < 2:
        return [sec]  # Nothing safe to cut on. Let the gate report it.

    half = sec.tokens // 2
    left: list[list[str]] = []
    running = 0
    for i, p in enumerate(paras):
        if running >= half and left:
            right = paras[i:]
            break
        left.append(p)
        running += est_tokens("\n".join(p))
    else:
        return [sec]

    def rebuild(groups, suffix):
        lines: list[str] = []
        for g in groups:
            lines.extend(g)
            lines.append("")
        return Section(title=(f"{sec.title} ({suffix})" if sec.title else suffix), lines=lines)

    return split_oversize(rebuild(left, "part 1")) + split_oversize(rebuild(right, "part 2"))


def build_context_prefix(meta: dict) -> str:
    """The synthetic header prepended before embedding. See module docstring."""
    bits = [
        f"Learning path: {meta['learning_path']}",
        f"Exam domain {meta['exam_domain']}",
        f"Module: {meta['module_title']}",
        f"Unit: {meta['unit_title']}",
    ]
    if meta.get("section_title"):
        bits.append(f"Section: {meta['section_title']}")
    return " | ".join(bits)


def chunk_corpus(root: pathlib.Path, signpost_ceiling: int = SIGNPOST_CEILING) -> tuple[list[dict], dict]:
    """Walk the corpus and produce chunk records plus a diagnostics dict."""
    chunks: list[dict] = []
    diag = {"units_seen": 0, "units_dropped_as_stub": 0, "modules": 0,
            "folders": [], "dropped_units": [], "oversize_survivors": []}

    folders = sorted(p for p in root.iterdir() if p.is_dir() and p.name[:2] in DOMAIN_MAP)
    if not folders:
        raise SystemExit(f"[error] no learning-path folders (01-04) found under {root}")

    for folder in folders:
        dm = DOMAIN_MAP[folder.name[:2]]
        diag["folders"].append(folder.name)

        for md in sorted(folder.glob("*.md")):
            # _full.md is a concatenation of the per-module files. Indexing it would
            # duplicate every chunk in the corpus and silently double every coverage
            # count. Skip it explicitly rather than relying on glob luck.
            if md.name == "_full.md":
                continue
            diag["modules"] += 1

            raw = md.read_text(encoding="utf-8", errors="replace").splitlines()
            module_title = raw[0].lstrip("# ").strip() if raw else md.stem

            unit_starts = [i for i, ln in enumerate(raw) if UNIT_RE.match(ln)]
            for n, start in enumerate(unit_starts):
                end = unit_starts[n + 1] if n + 1 < len(unit_starts) else len(raw)
                block = raw[start:end]
                m = UNIT_RE.match(raw[start])
                unit_number, unit_title = int(m.group(1)), m.group(2)
                diag["units_seen"] += 1

                # Capture provenance BEFORE stripping boilerplate. This URL is the
                # reason the corpus is worth anything; losing it is unrecoverable.
                source_url = next(
                    (SOURCE_RE.match(ln).group(1) for ln in block[:6] if SOURCE_RE.match(ln)),
                    None,
                )
                if not source_url:
                    raise SystemExit(
                        f"[error] no Source: URL for unit {unit_number} in {md.name}. "
                        "Refusing to emit a chunk that cannot be cited."
                    )

                body = [ln for ln in block[1:]
                        if not BOILERPLATE_RE.match(ln.strip())
                        and not (ln.startswith("# ") and ln.lstrip("# ").strip() == unit_title)]

                if est_tokens("\n".join(body)) < STUB_THRESHOLD:
                    diag["units_dropped_as_stub"] += 1
                    diag["dropped_units"].append(f"{md.name} :: u{unit_number} {unit_title}")
                    continue

                sections = merge_small(split_into_sections(body), signpost_ceiling)
                final: list[Section] = []
                for s in sections:
                    final.extend(split_oversize(s))

                unit_id = stable_id(source_url)
                for idx, sec in enumerate(final):
                    if not sec.text:
                        continue
                    meta = {
                        "learning_path": dm["learning_path"],
                        "exam_domain": dm["exam_domain"],
                        "domain_weight": dm["domain_weight"],
                        "domain_title": dm["domain_title"],
                        "module_file": md.name,
                        "module_title": module_title,
                        "unit_number": unit_number,
                        "unit_title": unit_title,
                        "unit_id": unit_id,
                        "section_title": sec.title,
                        "source_url": source_url,
                        "content_type": classify_content(md.name, unit_title),
                    }
                    rec = {
                        "chunk_id": stable_id(source_url, sec.title or "", str(idx)),
                        **meta,
                        "chunk_index": idx,
                        "chunks_in_unit": len(final),
                        "context_prefix": build_context_prefix(meta),
                        # Populated by a second pass (an LLM classification step against
                        # the 81 blueprint objectives). Deliberately empty here so the
                        # deterministic stage stays deterministic.
                        "objective_ids": [],
                        "text": sec.text,
                        "char_count": len(sec.text),
                        "token_estimate": sec.tokens,
                    }
                    if sec.tokens > HARD_CEILING:
                        diag["oversize_survivors"].append(
                            {"chunk_id": rec["chunk_id"], "tokens": sec.tokens,
                             "section": sec.title, "unit": unit_title})
                    chunks.append(rec)

    return chunks, diag


def build_stats(chunks: list[dict], diag: dict) -> dict:
    """The evidence report. An assertion that chunking worked proves nothing."""
    toks = sorted(c["token_estimate"] for c in chunks)
    if not toks:
        raise SystemExit("[error] produced zero chunks")

    def pct(p):
        return toks[min(int(p * len(toks)), len(toks) - 1)]

    by_domain: dict[str, dict] = {}
    for c in chunks:
        k = f"domain_{c['exam_domain']}"
        d = by_domain.setdefault(k, {"chunks": 0, "tokens": 0, "learning_path": c["learning_path"],
                                     "weight": c["domain_weight"]})
        d["chunks"] += 1
        d["tokens"] += c["token_estimate"]

    by_type: dict[str, int] = {}
    for c in chunks:
        by_type[c["content_type"]] = by_type.get(c["content_type"], 0) + 1

    return {
        "chunks_total": len(chunks),
        "units_seen": diag["units_seen"],
        "units_dropped_as_stub": diag["units_dropped_as_stub"],
        "modules_processed": diag["modules"],
        "tokens_total_estimate": sum(toks),
        "token_distribution": {
            "min": toks[0], "p10": pct(.10), "median": int(statistics.median(toks)),
            "p75": pct(.75), "p90": pct(.90), "p99": pct(.99), "max": toks[-1],
            "mean": round(statistics.mean(toks), 1),
        },
        "size_bands": {
            "under_150": sum(1 for t in toks if t < 150),
            "150_to_350": sum(1 for t in toks if 150 <= t < 350),
            "350_to_700": sum(1 for t in toks if 350 <= t < 700),
            "700_to_1200": sum(1 for t in toks if 700 <= t < 1200),
            "over_1200": sum(1 for t in toks if t >= 1200),
        },
        "by_exam_domain": by_domain,
        "by_content_type": by_type,
        "provenance": {
            "chunks_with_source_url": sum(1 for c in chunks if c.get("source_url")),
            "coverage_percent": round(
                100 * sum(1 for c in chunks if c.get("source_url")) / len(chunks), 2),
            "distinct_units": len({c["unit_id"] for c in chunks}),
            "distinct_source_urls": len({c["source_url"] for c in chunks}),
        },
        "gates": {},  # filled by validate()
        "dropped_units": diag["dropped_units"],
        "oversize_survivors": diag["oversize_survivors"],
        "config": {"MERGE_FLOOR": MERGE_FLOOR, "SIGNPOST_CEILING": SIGNPOST_CEILING, "HARD_CEILING": HARD_CEILING,
                   "STUB_THRESHOLD": STUB_THRESHOLD, "CHARS_PER_TOKEN": CHARS_PER_TOKEN},
    }


def validate(chunks: list[dict], stats: dict) -> list[str]:
    """Validation gates.

    Each gate is a claim the downstream index depends on. A gate failure is an
    exit code, not a warning, because a warning in a batch pipeline is a thing
    nobody reads.
    """
    failures: list[str] = []
    gates: dict[str, str] = {}

    # Gate 1 -- provenance. A chunk that cannot be cited cannot ground a claim.
    missing = [c["chunk_id"] for c in chunks if not c.get("source_url")]
    gates["every_chunk_citable"] = "PASS" if not missing else f"FAIL ({len(missing)})"
    if missing:
        failures.append(f"{len(missing)} chunks lack a source_url")

    # Gate 2 -- ID uniqueness. Collisions silently overwrite documents in the index.
    ids = [c["chunk_id"] for c in chunks]
    dupes = len(ids) - len(set(ids))
    gates["chunk_ids_unique"] = "PASS" if not dupes else f"FAIL ({dupes} collisions)"
    if dupes:
        failures.append(f"{dupes} duplicate chunk_id values")

    # Gate 3 -- no chunk exceeds twice the ceiling. A survivor here means a section
    # with no internal paragraph breaks, which is worth looking at by hand.
    huge = [c for c in chunks if c["token_estimate"] > HARD_CEILING * 2]
    gates["no_runaway_chunks"] = "PASS" if not huge else f"FAIL ({len(huge)})"
    if huge:
        failures.append(f"{len(huge)} chunks exceed {HARD_CEILING * 2} tokens")

    # Gate 4 -- the domain inversion actually happened. If LP_03 ever reports exam
    # domain 3, the lookup table was bypassed and every coverage number is wrong.
    bad = [c["chunk_id"] for c in chunks
           if (c["learning_path"], c["exam_domain"]) not in
           {("LP_01", 1), ("LP_02", 2), ("LP_03", 4), ("LP_04", 3)}]
    gates["domain_inversion_applied"] = "PASS" if not bad else f"FAIL ({len(bad)})"
    if bad:
        failures.append(f"{len(bad)} chunks have an incorrect learning_path -> exam_domain mapping")

    # Gate 5 -- all four domains present. A missing domain means a folder was skipped.
    present = {c["exam_domain"] for c in chunks}
    gates["all_four_domains_present"] = "PASS" if present == {1, 2, 3, 4} else f"FAIL (got {sorted(present)})"
    if present != {1, 2, 3, 4}:
        failures.append(f"expected exam domains 1-4, found {sorted(present)}")

    stats["gates"] = gates
    return failures


def self_test() -> int:
    """Unit tests for the two things most likely to break silently."""
    ok = True

    print("  [test] domain inversion table")
    for folder, expected in (("01", 1), ("02", 2), ("03", 4), ("04", 3)):
        got = DOMAIN_MAP[folder]["exam_domain"]
        mark = "pass" if got == expected else "FAIL"
        if got != expected:
            ok = False
        print(f"         Learn path {folder} -> exam domain {got} (expected {expected}) [{mark}]")

    print("  [test] section splitter keeps unit headers out of the section list")
    body = ["## 4. A unit header that must not become a section",
            "intro prose", "", "## A real section", "body", "### A subsection", "more"]
    secs = split_into_sections(body[1:])
    titles = [s.title for s in secs]
    expect = [None, "A real section", "A subsection"]
    mark = "pass" if titles == expect else "FAIL"
    if titles != expect:
        ok = False
    print(f"         got {titles} (expected {expect}) [{mark}]")

    print("  [test] headless preamble is absorbed forward, not dropped")
    pre = [Section(None, ["orphan preamble prose"]),
           Section("Real section", ["## Real section", "body text " * 40])]
    merged = merge_small(pre)
    absorbed = len(merged) == 1 and "orphan preamble" in merged[0].text and "body text" in merged[0].text
    mark = "pass" if absorbed else "FAIL"
    if not absorbed:
        ok = False
    print(f"         preamble + 1 section -> {len(merged)} chunk, text preserved={absorbed} [{mark}]")

    # Regression test for a MEASURED failure. At MERGE_FLOOR=350 with no cap, these
    # three real section headings from the identity-access unit collapsed into a single
    # chunk, destroying the Internet Access / Private Access distinction. If this test
    # ever fails again, the merge rule has been loosened past the point of usefulness.
    print("  [test] near-neighbour products are NOT merged into one chunk")
    para = "w " * 60  # ~120 est. tokens each: individually small, collectively a digest
    near = [Section("Microsoft Entra Internet Access", [para]),
            Section("Microsoft Entra Private Access", [para]),
            Section("Additional network controls", [para])]
    out = merge_small(near)
    intact = len(out) == 3 and all(
        sum(1 for probe in ("Internet Access", "Private Access", "Additional network")
            if probe in (s.title or "")) == 1 for s in out)
    mark = "pass" if intact else "FAIL"
    if not intact:
        ok = False
    print(f"         3 product sections -> {len(out)} chunks, each heading intact={intact} [{mark}]")

    print("\n  self-test:", "ALL PASS" if ok else "FAILURES PRESENT")
    return 0 if ok else 1


TOOLKIT_ROOT = pathlib.Path(__file__).resolve().parent.parent
"""Resolved from this file so the defaults work from any working directory.

Deliberately not imported from _common.py: this chunker stays standard-library-only and
self-contained, so it runs on a bare interpreter before anything is installed."""

DEFAULT_INPUT = TOOLKIT_ROOT / "corpus" / "Microsoft Cybersecurity Architect"
DEFAULT_OUTPUT = TOOLKIT_ROOT / "index"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", default=None,
                    help="The 'Microsoft Cybersecurity Architect' folder (default: corpus/ in this toolkit)")
    ap.add_argument("--output", default=None,
                    help="Directory for learn-chunks.jsonl and the stats report (default: index/)")
    ap.add_argument("--report-only", action="store_true", help="Measure and print; write nothing")
    ap.add_argument("--signpost-ceiling", type=int, default=SIGNPOST_CEILING,
                    help=f"Heading with body under this many tokens is absorbed forward (default {SIGNPOST_CEILING})")
    ap.add_argument("--self-test", action="store_true", help="Run internal tests and exit")
    args = ap.parse_args()

    if args.self_test:
        print("chunk_learn.py self-test\n")
        return self_test()

    root = pathlib.Path(args.input).expanduser() if args.input else DEFAULT_INPUT
    if not root.is_dir():
        print(f"[error] not a directory: {root}", file=sys.stderr)
        print("        Download the corpus first: scripts/Get-SC100Corpus.ps1", file=sys.stderr)
        return 2

    chunks, diag = chunk_corpus(root, args.signpost_ceiling)
    stats = build_stats(chunks, diag)
    failures = validate(chunks, stats)

    d = stats["token_distribution"]
    b = stats["size_bands"]
    print("=" * 68)
    print("SC-100 LEARN CORPUS CHUNKING REPORT")
    print("=" * 68)
    print(f"  modules processed      {stats['modules_processed']}")
    print(f"  units seen             {stats['units_seen']}")
    print(f"  units dropped (stub)   {stats['units_dropped_as_stub']}")
    print(f"  CHUNKS PRODUCED        {stats['chunks_total']}")
    print(f"  est. tokens total      {stats['tokens_total_estimate']:,}")
    print()
    print(f"  tokens/chunk   min {d['min']}  p10 {d['p10']}  median {d['median']}  "
          f"p75 {d['p75']}  p90 {d['p90']}  p99 {d['p99']}  max {d['max']}")
    print()
    print("  size bands")
    for label, count in b.items():
        bar = "#" * min(count // 5, 60)
        print(f"    {label:<14} {count:>4}  {bar}")
    print()
    print("  by exam domain (note the Learn-path inversion on domains 3 and 4)")
    for k in sorted(stats["by_exam_domain"]):
        v = stats["by_exam_domain"][k]
        print(f"    {k}  {v['learning_path']}  weight {v['weight']:<8} "
              f"{v['chunks']:>4} chunks  {v['tokens']:>7,} tok")
    print()
    print("  by content type")
    for k, v in sorted(stats["by_content_type"].items(), key=lambda x: -x[1]):
        print(f"    {k:<18} {v:>4}")
    print()
    p = stats["provenance"]
    print(f"  provenance   {p['chunks_with_source_url']}/{stats['chunks_total']} chunks citable "
          f"({p['coverage_percent']}%)   {p['distinct_units']} distinct units")
    print()
    print("  VALIDATION GATES")
    for gate, result in stats["gates"].items():
        print(f"    {result:<22} {gate}")
    print("=" * 68)

    if args.report_only:
        print("\n[report-only] nothing written.")
        return 1 if failures else 0

    outdir = pathlib.Path(args.output).expanduser() if args.output else DEFAULT_OUTPUT
    outdir.mkdir(parents=True, exist_ok=True)

    # newline="" disables Python's platform newline translation. Without it a
    # Windows run emits CRLF and a Linux run emits LF, so the same corpus produces
    # two files differing by exactly one byte per chunk -- which breaks the
    # "deterministic, byte-identical output" property this chunker is documented
    # to have, and makes cross-machine diffs unreadable. Content was always
    # identical; only the line terminator drifted.
    jsonl = outdir / "learn-chunks.jsonl"
    with jsonl.open("w", encoding="utf-8", newline="") as fh:
        for c in chunks:
            fh.write(json.dumps(c, ensure_ascii=False) + "\n")

    statsfile = outdir / "learn-chunks.stats.json"
    with statsfile.open("w", encoding="utf-8", newline="") as fh:
        fh.write(json.dumps(stats, indent=2, ensure_ascii=False))

    print(f"\n  wrote {jsonl}  ({jsonl.stat().st_size:,} bytes)")
    print(f"  wrote {statsfile}")

    if failures:
        print("\n[FAILED] validation gates did not pass:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print("\n[OK] all validation gates passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
