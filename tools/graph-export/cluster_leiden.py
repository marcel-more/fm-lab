#!/usr/bin/env python3
"""Leiden community detection (P5 optional enhancement).

Same I/O contract as cluster_louvain.mjs — a drop-in the dispatcher (cluster.sh)
selects only when Python + igraph are present. Determinism via fixed seed +
resolution so cluster colors stay stable between runs.

The stderr line carries `modularity=<Q>` (igraph `part.modularity`), matching the
louvain engine's format so the fm-graph-cluster resolution-sweep parses Q
engine-agnostically.

Usage:  python3 cluster_leiden.py <edges.csv> <communities.csv> [resolution] [seed]
  edges.csv         header: source,target
  communities.csv   header: object_uuid,community

Node IDs are opaque strings: since export 3.0.0 they are composite `uuid::file`
(clone-dedup; NULL-file synthetics stay bare `uuid`). csv.reader handles them
verbatim (quote-safe); cluster_load.sql splits them back to (Object_UUID, File_Name).

Only dependency: python-igraph. No DuckDB in Python — I/O stays CSV.
"""
import csv
import random
import sys
import time


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write(
            "usage: cluster_leiden.py <edges.csv> <communities.csv> [resolution] [seed]\n")
        return 2
    edges_path, out_path = sys.argv[1], sys.argv[2]
    resolution = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else 42

    import igraph as ig  # imported late: dispatcher guarantees availability

    t0 = time.time()
    ids: dict[str, int] = {}
    edges: list[tuple[int, int]] = []

    def node_id(name: str) -> int:
        idx = ids.get(name)
        if idx is None:
            idx = len(ids)
            ids[name] = idx
        return idx

    with open(edges_path, newline="") as fh:
        reader = csv.reader(fh)
        next(reader, None)  # header
        for row in reader:
            if len(row) < 2 or not row[0] or not row[1] or row[0] == row[1]:
                continue
            edges.append((node_id(row[0]), node_id(row[1])))

    g = ig.Graph(n=len(ids), edges=edges, directed=False)
    g.simplify(multiple=True, loops=True)
    t_parsed = time.time()

    # An edgeless graph is a legitimate input: a micro-solution whose only operational
    # links are builtins or local variables is filtered down to zero edges by the
    # logical export. igraph 0.11 does NOT terminate on it — community_leiden() with
    # n_iterations=-1 (run to convergence) spins forever once ecount()==0, reproduced
    # for vcount 0, 1 and 2 and independent of the RNG pinning below. Short-circuit to
    # the trivial partition (every node its own community, modularity undefined),
    # matching what cluster_louvain.mjs reports for the same input.
    if g.ecount() == 0:
        membership = list(range(g.vcount()))
        modularity = float("nan")
        t_clustered = time.time()
    else:
        # Determinism: python-igraph's community_leiden() takes NO seed= kwarg — the
        # algorithm draws from igraph's global RNG. We seed Python's random module and
        # pin it as igraph's generator, so the partition is reproducible (same seed +
        # resolution → identical membership), which the stable-colors guarantee relies on.
        # Passing seed= to community_leiden raises TypeError on igraph 0.11.
        random.seed(seed)
        ig.set_random_number_generator(random)

        part = g.community_leiden(
            objective_function="modularity",
            resolution=resolution,
            n_iterations=-1,
        )
        membership = part.membership
        modularity = part.modularity
        t_clustered = time.time()

    rev = [None] * len(ids)
    for name, idx in ids.items():
        rev[idx] = name
    with open(out_path, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["object_uuid", "community"])
        for idx, name in enumerate(rev):
            writer.writerow([name, membership[idx]])

    sys.stderr.write(
        f"[leiden] nodes={len(ids)} edges={len(edges)} "
        f"communities={len(set(membership))} modularity={modularity:.6f} "
        f"resolution={resolution} seed={seed} | "
        f"parse={(t_parsed - t0) * 1000:.0f}ms cluster={(t_clustered - t_parsed) * 1000:.0f}ms\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
