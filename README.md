# vara-ft-wat

A hand-written **Vara fungible-token (VFT)** contract implemented directly in
WebAssembly Text format (WAT), plus a benchmark CLI that compares its
per-operation gas cost against the sails-based VFT from
[`gear-tech/gear-bridges`](https://github.com/gear-tech/gear-bridges/tree/1f5f61a/gear-programs/vft).

The WAT contract is byte-compatible with the standard sails-rs `Vft` service
wire protocol (`SCALE("Vft") ++ SCALE("<Method>") ++ <params>`) — existing
clients/IDLs that talk to the
[`extended-vft`](https://github.com/gear-foundation/standards/tree/master/extended-vft)
or to gear-bridges' `Vft` service work against it unchanged.

## Why hand-written WAT

The reference Rust implementations use sails-rs + a `HashMap`/sharded-map for
balances and allowances. They are easy to read but pay for that with a 60+ KB
WASM binary, ~1.6–2.1 B gas per transfer, and (for the vanilla HashMap variant)
a hard-stop wall when the map crosses a `resize` threshold and the rehash
exceeds the per-message gas budget.

The WAT version commits to one specific layout — two open-addressing hash
tables with linear probing, pre-allocated lazily in a `(memory 32768)` linear
region — and skips the entire sails-rs machinery. The result is a **~4 KB**
WASM binary (16× smaller than the optimised sails build) and roughly **3× less
gas per Transfer / Approve** while the load factor stays moderate. Lazy pages
mean reserving the full 2 GB linear-memory address space is free; only pages
the contract actually reads or writes are charged.

Other design points:

- Stack region is one page (64 KB). Per-call scratch (`IN_BUF`, `OUT_BUF`,
  `SOURCE_BUF`, U256 temporaries) lives below `__gear_stack_end` so it is not
  lazy-tracked by gear.
- `gr_size > 1024 → panic` on entry: real VFT payloads are <120 bytes, so
  anything larger is malformed and rejected before `gr_read` can overflow
  the 1 KB input buffer.
- U256 implemented as four `i64` little-endian limbs with manual carry/borrow.
- Slot "empty" = key region is all-zero; deleted entries are kept as
  tombstones (`value = 0`) so probe chains stay intact.
- Balances live at `0x030000` (2^20 slots × 64 B = 64 MB); allowances live at
  `0x4030000` (2^23 slots × 96 B = 768 MB). Both tables use Fibonacci-mixed
  hashing (`× 0x9E3779B9` followed by a right-shift to keep the top 20 / 23
  bits). With 1M entries of each, balances sit at ~95 % load and allowances
  at ~12 % load — see the *Caveat* at the end of this file.
- Routes (`"Vft"`, `"Transfer"`, `"Approve"`, …) are stored as preformatted
  SCALE-compact blobs at fixed offsets; dispatch is a hand-unrolled
  `memeq` chain ordered roughly by call frequency.

## Repository layout

```
.
├── wat/extended_vft.wat        # the contract source (~1 KLOC of WAT)
├── benchmark/                  # Rust crate with the CLI binary `bench`
│   ├── Cargo.toml              # depends on `gtest` + `vft` (gear-bridges, pinned)
│   ├── build.rs                # compiles the .wat → .wasm at build time
│   └── src/main.rs             # benchmark + payload helpers
├── scripts/plot_gas_growth.py  # turns CSVs into the comparison PNG
└── results/                    # CSVs + PNG produced by the CLI
    ├── gas_growth_wat.csv
    ├── gas_growth_bridges.csv
    └── gas_growth.png
```

## Building and running

Requirements: a recent Rust toolchain (matching gear-core 1.10), Python 3
with `matplotlib`, and network access for the first build (gear-bridges is
pulled in via cargo at a pinned commit).

```bash
# Builds the workspace and (transitively) compiles wat/extended_vft.wat to
# WASM using the `wat` crate, and pulls gear-bridges' vft for its WASM_BINARY.
cargo build --release

# Run the benchmark. Defaults: --iters 100 --ops 10000 --impls wat,bridges.
./target/release/bench

# Smoke-size run: 5 iters × 200 ops each, only the WAT impl.
./target/release/bench --iters 5 --ops 200 --impls wat

# Drop the plot step (CSV only):
./target/release/bench --no-plot
```

The CLI writes one `gas_growth_<impl>.csv` per impl into `results/` and then
invokes `scripts/plot_gas_growth.py` to render `results/gas_growth.png`.

## Sample results

Full default run on this box (~24 minutes wall clock, 100 iters × 10 000
transfers + 10 000 approves, every recipient/spender a fresh random `u64`):

| Op       | WAT first → last (Δ)         | Bridges first → last (Δ)   | Bridges / WAT |
|----------|------------------------------|----------------------------|---------------|
| Transfer | 689 M → **827 M (+20.0 %)**  | 2.111 B → 2.120 B (+0.5 %) | 2.57–3.08 ×   |
| Approve  | 528 M → 537 M (+1.9 %)       | 1.908 B → 1.917 B (+0.5 %) | 3.57–3.62 ×   |

The full plot is at [results/gas_growth.png](results/gas_growth.png).

The **Transfer / WAT** curve is the only one that grows visibly — it is the
"hockey stick" of an open-addressing table whose load factor crosses ~85 %
and whose probe chains start spanning multiple 64 KB lazy pages. With the
2^20 balance-slot sizing, ~1 M entries fill the table to 95 % load. See the
caveat below; bumping the balance table to 2^21 (or matching the 2^23 used
for allowances) flattens that curve.

`Bridges` setup cost (one-time, before the benchmark loop):

- `VftExtension::AllocateNextBalancesShard` — **329 B gas**
- `VftExtension::AllocateNextAllowancesShard` — **165 B gas**
- `VftAdmin::Mint(admin, 2^60)` — 1.89 B gas

After those two shard allocations the bridges curve is essentially flat —
the sharded `HashMap`s never need to rehash, so growth doesn't blow the gas
budget like the vanilla `HashMap`-based extended-vft does at ~220 k entries.

## Caveat: WAT balance-table sizing

The current build sizes the balances table at 2^20 slots (64 MB) and the
allowances table at 2^23 slots (768 MB). With ~1 M unique balance entries the
balances table sits at ~95 % load; the closing iterations of the default
benchmark see per-transfer gas climb from 693 M to 827 M as probe chains
cross page boundaries.

For workloads with more than ~500 k unique holders the table should be
bumped to 2^21 (or 2^22) by changing two constants in
`wat/extended_vft.wat`:

- `$hash_actor`: change the final `(i32.shr_u … (i32.const 12))` to
  `(i32.const 11)` (for 2^21) or `(i32.const 10)` (for 2^22).
- `$bal_find`: bump the wrap mask `0xFFFFF` and the probe-cap `1048576`
  accordingly, and shift `ALLOW_BASE` higher to make room for the larger
  balance region.

Lazy pages make the extra address-space reservation free; gas only flows on
pages the contract actually writes to.

## Authorship

This project was produced end-to-end by [Claude Code](https://claude.com/claude-code)
(model: Claude Opus 4.7, 1M-context). Approximate token usage to take the
project from "implement extended-vft as a hand-written WAT contract" to its
current state (including all of the debugging, gas-ablation experiments,
gear-bridges integration, plot iterations, and this README): **on the order
of 2–3 million tokens**.

## License

MIT (see `LICENSE` if present, or the `license` field in `Cargo.toml`).
