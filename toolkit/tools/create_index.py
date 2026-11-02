#!/usr/bin/env python3
"""
create_index.py -- define the sc100-learn index on Azure AI Search (optional path).

Part of the OPTIONAL Azure path. Run it after infra/deploy.ps1 and before
tools/ingest_azure.py. The default local path never needs it.

WHAT THIS INDEX IS SHAPED FOR
-----------------------------
Not general document search. One specific retrieval problem, described in ADR-002:
a corpus whose discriminating queries are near-identical proper nouns.

    Microsoft Entra Internet Access   vs   Microsoft Entra Private Access
    Microsoft Defender for Storage    vs   Microsoft Defender for Databases
    MCSB v1 (GA)                      vs   MCSB v2 (preview, AI control family)

Every schema decision below follows from that.

WHY HYBRID, AND WHY IT IS THE WHOLE POINT
------------------------------------------
Dense vector search alone fails this corpus. Those product pairs sit almost on top of
each other in embedding space -- they share nearly all their tokens, their context,
and their meaning. Cosine similarity cannot reliably separate "Internet" from
"Private" when 95% of the surrounding text is identical.

BM25 can, because it keys on exactly the token that differs.

So every field that carries meaning is BOTH `searchable` (BM25, on an English
analyzer) AND represented in the vector. The query path runs both and fuses them with
Reciprocal Rank Fusion, then the semantic ranker re-orders the fused set. That is
three independent signals, and it is the single largest quality lever available here
-- larger than the embedding model choice.

THE PARENT-CHILD FIELDS
-----------------------
`unit_id` is filterable and facetable because ADR-002's retrieval pattern is
small-to-big: match on the precise section, then roll hits up to their parent Learn
unit for the answer payload. Making that a first-class filterable field means the
rollup is an index operation rather than post-processing in the MCP server.

`objective_ids` is a filterable, facetable string collection. It is empty today --
mapping chunks to the 81 skills-measured objectives is a classification pass that
belongs in its own stage -- but the field exists now so that the second pass is a
document merge rather than an index rebuild.

WHAT IS DELIBERATELY ABSENT
---------------------------
No indexer. No data source. No skillset. Chunking happens in chunk_learn.py and the
documents are pushed. See ADR-002 for the full argument; the short version is that
this corpus arrives as clean Markdown with structure and provenance already intact,
so paying a layout model to re-derive them would cost money, endanger the `source_url`
line, and make chunk boundaries impossible to git-diff.

There IS a query-time vectorizer, which is the half of integrated vectorization worth
having: the MCP server sends a plain string and Azure embeds it, using the search
service's own managed identity. No embedding client in the query path, no key.

IDEMPOTENCE
-----------
Re-running is safe. `create_or_update_index` reconciles the definition. Adding a new
retrievable field does not require a reload; changing the vector dimensions or the
key field does, and the script says so rather than failing cryptically.

USAGE
-----
    uv sync --group azure                                # once: the Azure SDKs
    uv run python tools/create_index.py
    uv run python tools/create_index.py --recreate       # delete and rebuild (drops all docs)
    uv run python tools/create_index.py --show           # print the definition, change nothing

EXIT CODES
----------
    0  index created or updated
    1  a precondition failed (no .env, auth failure, incompatible existing index)
"""

from __future__ import annotations

import argparse
import sys

from _common import (
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
# Schema constants
# ---------------------------------------------------------------------------

VECTOR_DIMENSIONS = 3072
"""Output width of text-embedding-3-large.

This MUST match the deployed model. If you change embeddingModelName in
infra/main.bicepparam, change this too and re-embed the entire corpus -- vectors from
two different models are not comparable, and mixing them degrades retrieval silently
rather than raising an error."""

VECTOR_PROFILE = "sc100-vector-profile"
HNSW_CONFIG = "sc100-hnsw"
VECTORIZER = "sc100-query-vectorizer"
SEMANTIC_CONFIG = "sc100-semantic"

TEXT_ANALYZER = "en.microsoft"
"""Microsoft's English analyzer, not the Lucene default.

It does better lemmatisation and, more importantly here, better word-breaking on the
hyphenated and compound product names this corpus is full of ("multicloud",
"Defender for Cloud", "Zero Trust"). BM25 quality is the reason hybrid works, so the
analyzer choice is not cosmetic."""


def build_index(index_name: str, foundry_endpoint: str, embedding_deployment: str):
    """Construct the SearchIndex definition.

    Split out from main() so the schema can be unit-tested and printed without
    touching Azure -- see --show.
    """
    from azure.search.documents.indexes.models import (
        AzureOpenAIVectorizer,
        AzureOpenAIVectorizerParameters,
        HnswAlgorithmConfiguration,
        HnswParameters,
        SearchField,
        SearchFieldDataType,
        SearchIndex,
        SemanticConfiguration,
        SemanticField,
        SemanticPrioritizedFields,
        SemanticSearch,
        VectorSearch,
        VectorSearchProfile,
    )

    fields = [
        # -- Identity ------------------------------------------------------
        SearchField(
            name="chunk_id",
            type=SearchFieldDataType.String,
            key=True,
            # The keyword analyzer treats the whole value as one token. Without it the
            # key would be word-broken and lookups by exact ID would miss.
            analyzer_name="keyword",
            filterable=True,
            sortable=True,
        ),
        # The parent pointer. Filterable is the important flag: it is what makes
        # small-to-big rollup an index operation instead of client-side work.
        SearchField(
            name="unit_id",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        # -- Retrievable content ------------------------------------------
        # Searchable AND vectorized. This is the hybrid pair.
        SearchField(
            name="text",
            type=SearchFieldDataType.String,
            searchable=True,
            analyzer_name=TEXT_ANALYZER,
        ),
        # The synthetic breadcrumb from chunk_learn.py. Searchable because it carries
        # the product names and domain labels a keyword query will aim at; stored
        # separately from `text` so a citation quotes Microsoft's prose, never ours.
        SearchField(
            name="context_prefix",
            type=SearchFieldDataType.String,
            searchable=True,
            analyzer_name=TEXT_ANALYZER,
        ),
        # -- The vector ----------------------------------------------------
        SearchField(
            name="text_vector",
            type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
            searchable=True,
            vector_search_dimensions=VECTOR_DIMENSIONS,
            vector_search_profile_name=VECTOR_PROFILE,
            # Never return 3072 floats to a caller. It is pure payload bloat and would
            # dominate every MCP tool response.
            hidden=True,
        ),
        # -- Provenance ----------------------------------------------------
        # The corpus's most valuable property: a passage that cannot be cited cannot
        # ground a claim.
        SearchField(
            name="source_url",
            type=SearchFieldDataType.String,
            filterable=True,
        ),
        # -- Titles: searchable, and the semantic ranker's title signal ----
        SearchField(
            name="module_title",
            type=SearchFieldDataType.String,
            searchable=True,
            filterable=True,
            analyzer_name=TEXT_ANALYZER,
        ),
        SearchField(
            name="unit_title",
            type=SearchFieldDataType.String,
            searchable=True,
            filterable=True,
            analyzer_name=TEXT_ANALYZER,
        ),
        SearchField(
            name="section_title",
            type=SearchFieldDataType.String,
            searchable=True,
            analyzer_name=TEXT_ANALYZER,
        ),
        # -- Facets that make coverage a measurement, not a judgment -------
        SearchField(
            name="learning_path",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        # NOTE: this is the EXAM domain, already corrected for the Learn-path
        # inversion by chunk_learn.py's lookup table. Learn path 03 is exam Domain 4.
        SearchField(
            name="exam_domain",
            type=SearchFieldDataType.Int32,
            filterable=True,
            facetable=True,
            sortable=True,
        ),
        SearchField(
            name="domain_weight",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        SearchField(
            name="domain_title",
            type=SearchFieldDataType.String,
            filterable=True,
        ),
        SearchField(
            name="content_type",
            type=SearchFieldDataType.String,
            filterable=True,
            facetable=True,
        ),
        # Empty today, populated by the objective-mapping second pass. Present now so
        # that pass is a merge, not a rebuild.
        SearchField(
            name="objective_ids",
            type=SearchFieldDataType.Collection(SearchFieldDataType.String),
            filterable=True,
            facetable=True,
        ),
        # -- Diagnostics ---------------------------------------------------
        SearchField(name="unit_number", type=SearchFieldDataType.Int32, filterable=True, sortable=True),
        SearchField(name="chunk_index", type=SearchFieldDataType.Int32, filterable=True, sortable=True),
        SearchField(name="chunks_in_unit", type=SearchFieldDataType.Int32, filterable=True),
        SearchField(name="token_estimate", type=SearchFieldDataType.Int32, filterable=True, sortable=True),
        SearchField(name="module_file", type=SearchFieldDataType.String, filterable=True),
    ]

    vector_search = VectorSearch(
        algorithms=[
            HnswAlgorithmConfiguration(
                name=HNSW_CONFIG,
                parameters=HnswParameters(
                    # Defaults, stated explicitly so they are reviewable rather than
                    # implicit. At ~1,100 documents HNSW tuning is irrelevant to
                    # quality -- the graph is smaller than the parameters assume --
                    # so these are left alone deliberately rather than fiddled with.
                    m=4,
                    ef_construction=400,
                    ef_search=500,
                    metric="cosine",
                ),
            )
        ],
        profiles=[
            VectorSearchProfile(
                name=VECTOR_PROFILE,
                algorithm_configuration_name=HNSW_CONFIG,
                vectorizer_name=VECTORIZER,
            )
        ],
        vectorizers=[
            # The query-time half of integrated vectorization, and the only half worth
            # having here. The MCP server sends a plain string; the search service
            # embeds it using its OWN managed identity. No embedding client in the
            # query path, no key in the index definition.
            AzureOpenAIVectorizer(
                vectorizer_name=VECTORIZER,
                parameters=AzureOpenAIVectorizerParameters(
                    resource_url=foundry_endpoint,
                    deployment_name=embedding_deployment,
                    model_name="text-embedding-3-large",
                    # No api_key. Authentication is the search service's system-assigned
                    # identity, granted Cognitive Services OpenAI User in main.bicep.
                ),
            )
        ],
    )

    semantic_search = SemanticSearch(
        default_configuration_name=SEMANTIC_CONFIG,
        configurations=[
            SemanticConfiguration(
                name=SEMANTIC_CONFIG,
                prioritized_fields=SemanticPrioritizedFields(
                    # The unit title is the most reliable single descriptor of what a
                    # chunk is about -- section titles are sometimes generic
                    # ("Design guidance"), unit titles almost never are.
                    title_field=SemanticField(field_name="unit_title"),
                    content_fields=[
                        SemanticField(field_name="text"),
                    ],
                    # Keyword fields feed the ranker the short, high-signal strings.
                    # context_prefix is here precisely because it concentrates the
                    # product and domain names into one line.
                    keywords_fields=[
                        SemanticField(field_name="context_prefix"),
                        SemanticField(field_name="section_title"),
                        SemanticField(field_name="module_title"),
                    ],
                ),
            )
        ],
    )

    return SearchIndex(
        name=index_name,
        fields=fields,
        vector_search=vector_search,
        semantic_search=semantic_search,
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "--recreate",
        action="store_true",
        help="Delete the index first. DESTROYS all indexed documents; you must re-run ingest_azure.py.",
    )
    ap.add_argument(
        "--show",
        action="store_true",
        help="Print the index definition as JSON and exit. Touches nothing, needs no credentials.",
    )
    args = ap.parse_args()

    # --show works offline so you can review or diff the schema without deploying
    # anything or paying for a search service.
    if args.show:
        cfg = load_env(required=False)
        if not cfg:
            info("No .env present; showing the definition with placeholder endpoints.")
        try:
            index = build_index(
                cfg.get("AZURE_SEARCH_INDEX", "sc100-learn"),
                cfg.get("AZURE_FOUNDRY_ENDPOINT", "https://PLACEHOLDER.cognitiveservices.azure.com/"),
                cfg.get("AZURE_EMBEDDING_DEPLOYMENT", "text-embedding-3-large"),
            )
        except ImportError:
            fail("azure-search-documents is not installed.",
                 "The Azure path is optional. Run: uv sync --group azure")
        import json

        print(json.dumps(index.as_dict(), indent=2))
        return 0

    cfg = load_env()
    endpoint, index_name, foundry, deployment = require(
        cfg,
        "AZURE_SEARCH_ENDPOINT",
        "AZURE_SEARCH_INDEX",
        "AZURE_FOUNDRY_ENDPOINT",
        "AZURE_EMBEDDING_DEPLOYMENT",
    )

    step("Configuration")
    info(f"search    {endpoint}")
    info(f"index     {index_name}")
    info(f"foundry   {foundry}")
    info(f"embedding {deployment}  ({VECTOR_DIMENSIONS} dimensions)")

    try:
        from azure.core.exceptions import ResourceNotFoundError
        from azure.search.documents.indexes import SearchIndexClient
    except ImportError:
        fail("azure-search-documents is not installed.", "The Azure path is optional. Run: uv sync --group azure")

    credential = get_credential()
    client = SearchIndexClient(endpoint=endpoint, credential=credential)

    step("Checking for an existing index")
    existing = None
    try:
        existing = client.get_index(index_name)
        ok(f"'{index_name}' exists with {len(existing.fields)} fields")
    except ResourceNotFoundError:
        ok(f"'{index_name}' does not exist yet")
    except Exception as exc:  # noqa: BLE001
        fail(f"Could not query the search service: {exc}", explain_403(exc))

    # Guard the one change that silently corrupts retrieval: an existing index whose
    # vector width does not match the model we are about to embed with. Mixing vector
    # widths does not raise -- it just returns bad results forever.
    if existing and not args.recreate:
        for f in existing.fields:
            dims = getattr(f, "vector_search_dimensions", None)
            if dims and dims != VECTOR_DIMENSIONS:
                fail(
                    f"Existing index '{index_name}' has {dims}-dimension vectors, "
                    f"but this script builds {VECTOR_DIMENSIONS}-dimension vectors.",
                    "Vectors from different models are not comparable and mixing them "
                    "degrades retrieval without any error. Re-run with --recreate and "
                    "then re-run ingest_azure.py.",
                )

    if args.recreate and existing:
        step("Deleting the existing index")
        warn("This destroys every indexed document. You must re-run ingest_azure.py.")
        client.delete_index(index_name)
        ok("Deleted")

    step("Applying the index definition")
    index = build_index(index_name, foundry, deployment)
    try:
        result = client.create_or_update_index(index)
    except Exception as exc:  # noqa: BLE001
        fail(f"Failed to create or update the index: {exc}", explain_403(exc))

    ok(f"Index '{result.name}' is ready")
    info(f"fields              {len(result.fields)}")
    info(f"vector profile      {VECTOR_PROFILE} (HNSW, cosine, {VECTOR_DIMENSIONS}d)")
    info(f"query vectorizer    {VECTORIZER} -> {deployment} (managed identity, no key)")
    info(f"semantic config     {SEMANTIC_CONFIG}")

    print(
        "\n"
        "Retrieval is now three signals fused: BM25 over the English analyzer,\n"
        "HNSW cosine over 3072-dimension vectors, and the semantic reranker on top.\n"
        "That combination is what separates 'Entra Internet Access' from\n"
        "'Entra Private Access' -- see docs/ADR-002 for why it has to.\n"
        "\n"
        "Next: uv run python tools/ingest_azure.py\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
