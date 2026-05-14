#!/usr/bin/env python3
"""Render gas-per-op vs hash-table size from the benchmark CLI's CSV output.

Usage:
    python3 scripts/plot_gas_growth.py [RESULTS_DIR] [OPS_PER_ITER]

Defaults: RESULTS_DIR=results, OPS_PER_ITER=10000.

The script reads any `gas_growth_<impl>.csv` files inside `RESULTS_DIR` and
writes `gas_growth.png` to the same directory. Each CSV must have columns
`iter, avg_transfer, avg_approve` (one row per iteration).

X-axis is the approximate number of entries in the relevant table at the
midpoint of the iteration — `i * OPS_PER_ITER + OPS_PER_ITER/2`. For the
top-row panels that's the balances-table size; for the bottom-row panels
it's the allowances-table size. Each iter inserts ~OPS_PER_ITER fresh
entries into each table.
"""

import csv
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as mtick


# Order + colour assignment for known impl names.
KNOWN_IMPLS = [
    ("WAT",     "wat",     "#1f77b4"),
    ("Bridges", "bridges", "#2ca02c"),
    ("Rust",    "rust",    "#d62728"),
]


def load(path):
    iters, transfers, approves = [], [], []
    if not Path(path).exists():
        return None
    with open(path, newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            iters.append(int(row["iter"]))
            transfers.append(int(row["avg_transfer"]))
            approves.append(int(row["avg_approve"]))
    if not iters:
        return None
    return iters, transfers, approves


def fmt_gas(v, _pos=None):
    # Three decimals in B-range so sub-percent variation is visible.
    if v >= 1e9:
        return f"{v / 1e9:.3f}B"
    if v >= 1e6:
        return f"{v / 1e6:.1f}M"
    return f"{v:.0f}"


def fmt_entries(v, _pos=None):
    if v >= 1e6:
        return f"{v / 1e6:.1f}M"
    if v >= 1e3:
        return f"{v / 1e3:.0f}k"
    return f"{v:.0f}"


def stats_line(label, xs):
    if not xs:
        return f"{label}: no data"
    return (
        f"{label}: n={len(xs):3d}  first={fmt_gas(xs[0])}  last={fmt_gas(xs[-1])}  "
        f"mean={fmt_gas(sum(xs)/len(xs))}  Δ={(xs[-1]-xs[0])/xs[0]*100:+.2f}%"
    )


def main():
    results_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("results")
    ops_per_iter = int(sys.argv[2]) if len(sys.argv) > 2 else 10_000

    impls = []
    for name, slug, color in KNOWN_IMPLS:
        data = load(results_dir / f"gas_growth_{slug}.csv")
        if data is not None:
            impls.append((name, data, color))

    if not impls:
        print(f"no CSV data found in {results_dir}; expected gas_growth_*.csv")
        sys.exit(1)

    n = len(impls)
    fig, axs = plt.subplots(2, n, figsize=(5 * n + 1, 8), sharex=False, squeeze=False)

    for col, (name, (it, tr, ap), color) in enumerate(impls):
        bal_x  = [i * ops_per_iter + ops_per_iter // 2 + 1 for i in it]
        allw_x = [i * ops_per_iter + ops_per_iter // 2     for i in it]

        ax_t = axs[0, col]
        ax_t.plot(bal_x, tr, color=color, linewidth=1.4)
        ax_t.set_title(f"Transfer — {name}")
        ax_t.set_xlabel("# balances in table")
        ax_t.grid(True, alpha=0.3)
        ax_t.yaxis.set_major_formatter(mtick.FuncFormatter(fmt_gas))
        ax_t.xaxis.set_major_formatter(mtick.FuncFormatter(fmt_entries))
        if col == 0:
            ax_t.set_ylabel("avg gas / op")

        ax_a = axs[1, col]
        ax_a.plot(allw_x, ap, color=color, linewidth=1.4)
        ax_a.set_title(f"Approve — {name}")
        ax_a.set_xlabel("# allowances in table")
        ax_a.grid(True, alpha=0.3)
        ax_a.yaxis.set_major_formatter(mtick.FuncFormatter(fmt_gas))
        ax_a.xaxis.set_major_formatter(mtick.FuncFormatter(fmt_entries))
        if col == 0:
            ax_a.set_ylabel("avg gas / op")

    n_iters = len(impls[0][1][0])
    fig.suptitle(
        f"vara-ft-wat gas growth — {n_iters} iters × "
        f"({ops_per_iter // 1000}k transfer + {ops_per_iter // 1000}k approve)\n"
        "admin pre-minted with 2^60 VFT, every recipient/spender a fresh random u64",
        fontsize=11,
    )
    fig.tight_layout(rect=[0, 0, 1, 0.96])

    out_png = results_dir / "gas_growth.png"
    fig.savefig(out_png, dpi=140, bbox_inches="tight")
    print(f"saved {out_png}")

    for name, (_, tr, ap), _ in impls:
        print(stats_line(f"  transfer {name:>10}", tr))
        print(stats_line(f"  approve  {name:>10}", ap))


if __name__ == "__main__":
    main()
