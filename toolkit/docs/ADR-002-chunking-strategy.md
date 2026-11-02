# ADR-002: Chunking strategy for the SC-100 corpus

**Status:** Accepted
**Decides:** the chunk boundary for the Microsoft Learn corpus, and who performs the chunking
**Implemented by:** `tools/chunk_learn.py` (deterministic, self-tested, five validation gates)

---

## Decision

**Chunk on the authored H2/H3 section. Retrieve on the section, return the unit.**

**Chunk locally in Python and push the result. Do not let an Azure skillset decide the
boundary.**

| | Microsoft Learn corpus |
|---|---|
| Chunk unit | **H2/H3 section within a Learn unit** |
| Chunks | **1,071** |
| Median size | **219 est. tokens** |
| Citable address | `source_url` (100% coverage) |
| Chunker | `chunk_learn.py`, local, deterministic |

Small enough that no store will be slow or expensive, so the boundary was chosen purely
on retrieval quality.

---

## Why the unit is not a usable chunk

The obvious first estimate was "about 150 to 200 chunks, one per Learn unit." That number
came from counting units, and the unit is too big. Measured across the real corpus:

| Unit-as-chunk | Measured |
|---|---|
| Units | 168 |
| Median unit | 1,962 est. tokens |
| p90 | 3,286 |
| Max | 4,738 |
| **Units over 2,000 tokens** | **82 of 168 (49%)** |

Nothing here breaks an embedding model: `text-embedding-3-large` takes 8,191 tokens, so
every unit fits comfortably. **That is exactly why this is easy to miss.** The pipeline
would build cleanly, index cleanly, and return plausible results.

The failure is retrieval precision. An embedding is one point in vector space, so
embedding a 3,000-token unit stores the *centroid* of every idea in it. This corpus is
unusually hostile to that blur because its discriminating queries are near-identical
proper nouns:

- Microsoft Entra Internet Access **vs** Microsoft Entra Private Access
- Microsoft Defender for Storage **vs** Microsoft Defender for Databases
- MCSB v1 (GA) **vs** MCSB v2 (preview, carries the AI control family)
- Secure Score **vs** Cloud Secure Score

Those pairs already sit close together. Averaging each into a 3,000-token centroid moves
them closer. BM25 keys on the token that differs, but only if that token is a meaningful
share of the chunk it indexes; a chunk that dilutes it into one part in fifteen undercuts
keyword search too.

---

## The rule, and the two bugs that shaped it

The rule is not "split on headings." It is more specific than that, because two naive
versions were built first and the corpus rejected both.

### Rule 1: an authored heading is an absolute boundary

A section with its own heading **and real body text stands alone. Always.** Size never
overrides it.

The first implementation merged any consecutive run of sections under a 350-token floor.
It produced this:

> one 364-token chunk titled *"Microsoft Entra Internet Access + Microsoft Entra Private
> Access + Additional network controls"*

That is the exact near-neighbour pair the strategy exists to separate, fused by the
strategy's own tidying rule. A query for "Private Access" would return a chunk discussing
both products and hand the disambiguation back to the model.

**The lesson that generalizes:** a size-driven merge rule silently overrides the author's
semantic judgment. Microsoft gave those two products separate headings *because they are
contrasted*. Trading that signal for a tidier size histogram is a bad trade.

### Rule 2: a signpost is not a section

Removing the merge entirely swung too far: 1,213 chunks, median 192, and a **minimum of 3
estimated tokens**, which means bare headings with no body.

Microsoft uses headings in two structurally different ways:

| | Shape | Treatment |
|---|---|---|
| **Section** | `### Microsoft Entra Private Access` + 120 tokens describing it | Stands alone |
| **Signpost** | `## Technology pillars` + nothing, then `### Identity`, `### Endpoints` | Absorbed forward |

A signpost has no body, so it has no author signal to respect. It merges into the first
real section beneath it, where it does useful work as that chunk's parent heading.
Headless preamble prose is handled the same way, for the same reason.

### Calibrating the signpost threshold

The failure mode of too high a threshold is invisible in a size histogram: real sections
get absorbed and contrasted products fuse again. So it was measured directly, by counting
chunks whose text mentions **both** halves of a known near-neighbour pair. A rising count
means fusion.

| Signpost ceiling | Chunks | Median | Entra Internet/Private | Defender Storage/DB |
|---|---|---|---|---|
| 40 | 1,128 | 209 | 3 (baseline) | 4 (baseline) |
| **60** | **1,071** | **219** | **3** | **4** |
| 90 | 954 | 259 | 3 | 5 (fusion begins) |
| 110 | 875 | 286 | 3 | 5 |
| 130 | 798 | 308 | 4 (fusion) | 5 |

A non-zero baseline is expected, because some sections legitimately compare both products.
The signal is the *increase*. **60 is the largest ceiling at which neither pair rises.**
Re-run the sweep with `--signpost-ceiling` whenever you download a fresh corpus.

### Rule 3: drop the assessment stubs

20 units are "Module assessment" or "Knowledge check" landing pages: about 50 tokens of
stock text telling the learner to answer questions on the Learn site. They are
near-identical to one another, so they would form a tight cluster that matches broadly and
informs nothing. They are dropped, and listed by name in the stats report so the removal
is auditable.

---

## Retrieve on the section, return the unit

Section-level chunks are precise but individually thin, with a median of 219 tokens. That
is right *for matching* and not enough *for answering*. So the two jobs are separated:

- Every chunk carries `unit_id` (a content hash of the unit's `source_url`).
- The MCP server matches on sections, then rolls hits up to their parent unit for the
  answer payload.

Precision on the way in, coherence on the way out: the small-to-big pattern. On the Azure
path `unit_id` is a filterable field, so the rollup can be an index operation.

### Contextual prefixing

A mid-unit section titled "Design guidance" that opens "This approach is preferred
when..." has lost its subject. Retrieved cold, it is not merely unhelpful; it is
confidently irrelevant. So each chunk carries a synthetic header that is embedded but
stored separately:

```
Learning path: LP_02 | Exam domain 2 | Module: Design solutions for identity and
access management | Unit: Design a solution for external identities | Section: B2B
collaboration in workforce tenants
```

About 40 tokens restore the subject. The header lives in `context_prefix`, not `text`, so
a citation quotes real Microsoft prose and never the scaffolding.

---

## Why the chunking runs locally, not as an Azure skillset

Azure offers structure-aware chunking: **Document Layout skill, then Text Split skill,
then index projections.** That path exists to *recover* structure from binary documents
where it was lost. This corpus is already clean Markdown carrying H2/H3 headings and a
`Source:` URL on every unit.

Three reasons not to use it here:

1. **It pays to re-derive what you already have.** The Document Layout skill bills
   through Document Intelligence pricing to extract structure the downloader already
   preserved.
2. **It endangers `source_url`.** Provenance is the corpus's most valuable property. A
   layout model treats that line as body text. Losing it is unrecoverable and, worse,
   silent.
3. **It makes chunking non-reproducible.** You cannot `git diff` a skillset's output.
   When a coverage number moves, you could not tell whether the corpus changed or the
   chunker did.

**Chunk locally, push the documents.** Deterministic, unit-tested, and diffable: the same
corpus produces a byte-identical chunk file on every machine.

**Keep integrated vectorization for query time only.** On the Azure path, a vectorizer on
the index lets the MCP server send plain text and have Azure embed the query, using the
search service's own managed identity. That is where the feature earns its keep.

---

## Search tier on the Azure path

- **The semantic ranker's free billing plan is available on all pricing tiers.** The
  *standard* plan (pay as you go past the free allowance) requires **Basic or higher**.
- Whether the ranker runs on the **Free tier at all is region-dependent**, and Microsoft's
  own pages disagree with each other on it.
- The Free tier has **no managed identity**, which would force key-based auth on the
  query-time vectorizer and the MCP server.

**Decision: Basic.** Not because of storage (1,071 chunks fit easily in the Free tier's
50 MB) but because keyless auth needs a managed identity, and building on a capability
whose own documentation contradicts itself is a poor foundation. Basic bills hourly, so
run it ephemerally: deploy, ingest, study, tear down. Check the live price for your region
before you deploy; `infra/deploy.ps1` prints it.

---

## Consequences

**Good.** The boundary is chosen by measurement, not intuition, and the measurement is
re-runnable (`--report-only`, `--signpost-ceiling`). Chunking is deterministic and
idempotent: content-addressed IDs mean an unchanged corpus produces a byte-identical
JSONL, so re-ingestion updates in place rather than duplicating. Five validation gates
fail the build rather than warning, including one that proves the Learn-path to
exam-domain inversion was actually applied.

**Costs.** Roughly six times more documents than the unit-as-chunk estimate. Irrelevant
for cost at this scale, but retrieval must request more results and roll them up, rather
than returning the top three raw.

**Accepted risk.** 270 of 1,071 chunks fall under 150 tokens. Acceptable with unit rollup
and BM25 available, and the alternative is demonstrably worse: it fuses contrasted
products. Revisit only if a retrieval evaluation shows short chunks losing.

**Open, deliberately deferred.** `objective_ids` is emitted empty. Mapping chunks to the
81 skills-measured objectives is a classification task, and keeping it out of this stage
is what keeps this stage deterministic.

**Revisit if** you download a fresh corpus (re-run the signpost sweep, because Microsoft's
heading conventions could shift), or a retrieval evaluation on real SC-100 questions
contradicts the near-neighbour co-occurrence proxy used to calibrate here.
