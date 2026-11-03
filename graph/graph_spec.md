# Graph Specification

Use this folder for graph-ready exports.

Primary files:
- `nodes.csv`
- `edges.csv`

The graph must be readable without technical IDs. Use real names in `qualified_name` and `display_name`.

Current Phase 5 graph:
- `nodes.csv` contains workspace, item, and external connection nodes.
- `edges.csv` contains structural `contains` edges plus dependency edges.
- `index/dependencies.csv` remains the technical dependency evidence source.
- `analysis/graph_summary.csv` contains current counts.
- `analysis/graph_validation.csv` contains graph integrity checks.
- `analysis/top_graph_nodes.csv` contains the highest-degree nodes for review.

Recommended graph tools:
- NetworkX for local analysis.
- Neo4j if interactive graph exploration is needed.
- Power BI if business-facing visualization is preferred.

Do not choose the final graph engine until the first inventory size is known.
