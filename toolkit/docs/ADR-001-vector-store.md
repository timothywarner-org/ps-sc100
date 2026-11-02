# ADR-001: Vector store for the SC-100 study knowledge base

**Status:** Accepted
**Decides:** where the Microsoft Learn corpus is indexed, and what the MCP server exposes

---

## Decision

**Index the corpus in a local Chroma collection by default. Keep Azure AI Search as an
optional upgrade you deploy on purpose and tear down the same day.**

| Path | Store | Cost | Retrieval |
|---|---|---|---|
| **Default** | Local Chroma at `index/learn-chroma`, collection `sc100_learn` | Zero | Dense vectors, plus BM25 through `tools/search_keyword.py` |
| **Optional** | Azure AI Search, Basic SKU (`infra/`) | Bills hourly while it exists | Hybrid BM25 + vectors, fused, then the semantic ranker |

The knowledge base exists to ground your study: you ask a question and get Microsoft's
own words back with a link to the page. A local collection answers that at zero cost,
with no Azure subscription, no `az login`, and no network once the embedding model is
cached. That decides the default.

---

## Why local is the default

**1. You read the results yourself.** A near-miss is visible and cheap when a person is
looking at the passage and its `source_url`. Paying for a semantic ranker to polish an
answer you are about to check anyway is spending on the wrong axis.

**2. Zero infrastructure, zero cost, works offline.** Chroma's default embedding function
runs a small sentence transformer on your machine through ONNX. The same model embeds the
corpus and every query, so the vectors are comparable and reproducible.

**3. The corpus is small.** About 1,100 chunks. No store will be slow, so scale cannot be
the deciding factor. Retrieval quality and cost are.

## What local gives up, and how the toolkit compensates

**This corpus is unusually hostile to pure dense retrieval.** Nearly every discriminating
query is a proper noun with a near neighbour that is wrong: *Microsoft Entra Internet
Access* versus *Microsoft Entra Private Access*, *Defender for Storage* versus *Defender
for Databases*, *MCSB v1* versus *MCSB v2*. Embeddings put those pairs almost on top of
each other. **BM25 does not**, because it keys on the token that differs.

The toolkit gives you BM25 locally anyway. `tools/search_keyword.py` runs Okapi BM25 and
exact phrase matching over the same chunk file the vector store is built from, with
nothing but the standard library. When you need to pin an exact product name, use phrase
mode; it cannot confuse two names that share most of their words.

If retrieval quality ever becomes your real bottleneck, deploy the Azure path rather than
hand-rolling a reranker. That is what it is for.

## When the Azure path is worth it

**1. Hybrid retrieval in one query.** Azure AI Search runs BM25 over the Microsoft English
analyzer and HNSW cosine over 3,072-dimension vectors, fuses them with Reciprocal Rank
Fusion, and re-orders the result with the semantic ranker. Three independent signals.

**2. `objective_ids` as a first-class filter.** Filterable and facetable fields are index
schema in Azure AI Search. In Chroma, the same idea is a `where` clause over a scalar
metadata string.

**3. It is a working example of keyless Azure architecture.** Every service in `infra/`
refuses API keys, and every caller authenticates with Microsoft Entra ID. That is worth
studying for SC-100 in its own right.

The cost is real: Azure AI Search Basic bills by the hour whether you query it or not.
The deploy script prints the live retail rate for your region and asks before it creates
anything. Run the teardown script when you finish.

---

## Citability: the property every design choice protects

Every passage the MCP server returns carries its full text and a `source_url`. Two things
make that true, and both are checked by a self-test rather than trusted:

- **The Chroma query asks for document text.** `include=["documents", "metadatas",
  "distances"]`. Leaving `"documents"` out does not raise an error; retrieval keeps
  returning plausible hits with empty text and nothing to cite. `mcp/server.py` names the
  list once, and `--self-test` asserts it.
- **No chunk enters the index without a `source_url`.** `tools/chunk_learn.py` refuses to
  emit one, and `tools/ingest_local.py` refuses to index one.

---

## Metadata schema

| Field | Notes |
|---|---|
| `source_url` | **Never strip this.** It is the corpus's most valuable property |
| `learning_path` | `LP_01` to `LP_04`, the Learn path the chunk came from |
| `exam_domain` | **Exam** domain 1 to 4, corrected for the numbering trap below |
| `domain_weight` | The published weight band |
| `content_type` | `concept`, `case_study`, `module_intro`, or `module_summary` |
| `unit_id` | Parent unit, for small-to-big rollup (ADR-002) |
| `objective_ids` | Reserved for a classification pass; serialized as `",2.1.3,2.1.4,"` |

### The numbering trap

Microsoft Learn's learning-path order is **not** the study guide's domain order. Learn
path `03` is exam **Domain 4** (applications and data); Learn path `04` is exam **Domain
3** (infrastructure). The chunker maps this with an explicit lookup table and a unit test,
never an inference from a folder name. A silent inversion here corrupts every coverage
number built on top of it, and nothing else would notice.

---

## MCP tool surface

| Tool | Returns |
|---|---|
| `sc100_search_learn` | Passages **with** `source_url`, plus their parent units |
| `sc100_objective_coverage` | Passages for one exam objective and a thin / adequate / strong grade |
| `sc100_coverage_sweep` | The objectives the free Learn training covers thinly |
| `sc100_check_currency` | Retired product names, lifecycle language, and preview language in the corpus |

An earlier design had a separate `find_gaps` tool. It answered the same question as
objective coverage with different defaults, so it became the sweep. Two tools that answer
the same question are the most common cause of wrong tool selection.

---

## Consequences

**Good.** The default costs nothing and runs anywhere Python runs. Citability is enforced
in code and tested. The Azure path is there when hybrid retrieval earns its cost, and it
demonstrates keyless Azure architecture end to end.

**Costs.** Two ingest paths to maintain (`ingest_local.py` and `ingest_azure.py`). Dense
retrieval on the default path can rank a near-identical product name above the one you
asked for, which is why the server's instructions tell the assistant to search by exact
name and read the `source_url` before quoting.

**Revisit if** Chroma ships a hybrid retriever with a comparable reranker, at which point
the Azure path loses most of its reason to exist.
