//! Benchmark CLI for the hand-written WAT VFT vs. gear-bridges' sails VFT.
//!
//! For each impl we:
//!   1. Deploy the contract via gtest.
//!   2. Run impl-specific setup (gear-bridges needs to allocate hash-map shards
//!      before any insert is possible).
//!   3. Mint 2^60 VFT to the admin actor.
//!   4. Loop `--iters` iterations, each running `--ops` transfers from admin
//!      to a fresh random recipient followed by `--ops` approves from admin
//!      to a fresh random spender. Both phases extend the underlying tables
//!      by ~ops fresh entries per iteration.
//!   5. Record per-iter average gas-burned for each op kind into a CSV.
//!
//! Finally we invoke `scripts/plot_gas_growth.py` to render the curves into
//! `<out_dir>/gas_growth.png`. The Python script reads the CSVs from the
//! same directory and writes the PNG there.
//!
//! All wire encoding is built by hand — we route messages by writing the
//! sails-rs SCALE prefix (compact length + service/method name) directly
//! into the raw payload. This keeps the benchmark independent of any
//! particular sails-rs version.

use std::path::PathBuf;
use std::time::Instant;

use clap::{Parser, ValueEnum};
use gtest::{
    constants::MAX_USER_GAS_LIMIT, calculate_program_id, Program, System,
};

/// Hand-written WAT contract, compiled at build time by `wat::parse_str`.
const WAT_WASM: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/extended_vft.wasm"));

/// gear-bridges VFT, pulled in via cargo with the `wasm-binary` feature.
const BRIDGES_WASM: &[u8] = vft::WASM_BINARY;

const ADMIN_ID: u64 = 10;

// =====================================================================
// CLI
// =====================================================================

#[derive(Parser)]
#[command(version, about = "Gas-growth benchmark for the WAT VFT vs. gear-bridges VFT.")]
struct Cli {
    /// Number of iterations.
    #[arg(long, default_value_t = 100)]
    iters: usize,

    /// Operations per iteration of each kind (so each iter performs
    /// `ops` transfers PLUS `ops` approves).
    #[arg(long, default_value_t = 10_000)]
    ops: usize,

    /// Deterministic RNG seed.
    #[arg(long, default_value_t = 0xDEAD_BEEF_CAFE_BABE_u64)]
    seed: u64,

    /// Which impls to benchmark. Pass multiple flags or comma-separated.
    #[arg(long, value_enum, value_delimiter = ',',
          num_args = 1.., default_values_t = [Impl::Wat, Impl::Bridges])]
    impls: Vec<Impl>,

    /// Directory for CSV + PNG output (created if missing).
    #[arg(long, default_value = "results")]
    out_dir: PathBuf,

    /// Skip running the Python plot script.
    #[arg(long)]
    no_plot: bool,

    /// Path to the Python plot script (defaults to scripts/plot_gas_growth.py
    /// relative to the workspace root).
    #[arg(long, default_value = "scripts/plot_gas_growth.py")]
    plot_script: PathBuf,
}

#[derive(Clone, Copy, ValueEnum, PartialEq, Eq, Debug)]
enum Impl {
    /// Hand-written WAT contract from `wat/extended_vft.wat`.
    Wat,
    /// gear-bridges sails-based VFT at the pinned revision.
    Bridges,
}

impl Impl {
    fn csv_name(self) -> &'static str {
        match self {
            Impl::Wat => "wat",
            Impl::Bridges => "bridges",
        }
    }
}

#[derive(Clone, Copy)]
struct IterStat {
    avg_transfer: u64,
    avg_approve: u64,
}

// =====================================================================
// Payload helpers
// =====================================================================

/// sails-rs places a u64 in an `ActorId` at byte offsets 12..20 (the same
/// layout `gprimitives::ActorId::from(u64)` produces). Mirror that here so
/// the recipient/spender bytes we put on the wire match what `gr_source`
/// reports inside the contract.
fn actor_bytes(id: u64) -> [u8; 32] {
    let mut bytes = [0u8; 32];
    bytes[12..20].copy_from_slice(&id.to_le_bytes());
    bytes
}

fn u256_bytes(value: u64) -> [u8; 32] {
    let mut bytes = [0u8; 32];
    bytes[..8].copy_from_slice(&value.to_le_bytes());
    bytes
}

/// `<compact-len(name)> ++ <name-bytes>` — for routes that fit in one SCALE
/// compact byte (length < 64) the prefix is just `len << 2`.
fn scale_short_str(name: &str) -> Vec<u8> {
    let len = name.len();
    assert!(len < 64, "route too long for single-byte SCALE compact");
    let mut buf = Vec::with_capacity(1 + len);
    buf.push(((len as u8) << 2) | 0);
    buf.extend_from_slice(name.as_bytes());
    buf
}

fn build_init_payload(name: &str, symbol: &str, decimals: u8) -> Vec<u8> {
    let mut buf = scale_short_str("New");
    buf.extend(scale_short_str(name));
    buf.extend(scale_short_str(symbol));
    buf.push(decimals);
    buf
}

fn build_mint_payload_vft(to: u64, value: u64) -> Vec<u8> {
    // WAT contract puts Mint inside service "Vft".
    let mut buf = scale_short_str("Vft");
    buf.extend(scale_short_str("Mint"));
    buf.extend_from_slice(&actor_bytes(to));
    buf.extend_from_slice(&u256_bytes(value));
    buf
}

fn build_mint_payload_bridges(to: u64, value: u64) -> Vec<u8> {
    // gear-bridges puts Mint inside service "VftAdmin".
    let mut buf = scale_short_str("VftAdmin");
    buf.extend(scale_short_str("Mint"));
    buf.extend_from_slice(&actor_bytes(to));
    buf.extend_from_slice(&u256_bytes(value));
    buf
}

fn build_transfer_payload(to: u64, value: u64) -> Vec<u8> {
    let mut buf = scale_short_str("Vft");
    buf.extend(scale_short_str("Transfer"));
    buf.extend_from_slice(&actor_bytes(to));
    buf.extend_from_slice(&u256_bytes(value));
    buf
}

fn build_approve_payload(spender: u64, value: u64) -> Vec<u8> {
    let mut buf = scale_short_str("Vft");
    buf.extend(scale_short_str("Approve"));
    buf.extend_from_slice(&actor_bytes(spender));
    buf.extend_from_slice(&u256_bytes(value));
    buf
}

/// gear-bridges' sharded-map storage starts with capacity 0 — we have to
/// allocate the first balance and allowance shards before any mint/approve
/// succeeds. `AllocateNext*Shard` materialises the next zero-capacity shard
/// up to its declared limit (14M slots for balances, 7M for allowances).
fn build_alloc_balances_shard_payload() -> Vec<u8> {
    let mut buf = scale_short_str("VftExtension");
    buf.extend(scale_short_str("AllocateNextBalancesShard"));
    buf
}

fn build_alloc_allowances_shard_payload() -> Vec<u8> {
    let mut buf = scale_short_str("VftExtension");
    buf.extend(scale_short_str("AllocateNextAllowancesShard"));
    buf
}

// =====================================================================
// Benchmark core
// =====================================================================

fn measure_growth(
    label: &str,
    wasm: &[u8],
    seed: u64,
    n_iters: usize,
    ops_per_iter: usize,
    mint_builder: fn(u64, u64) -> Vec<u8>,
    setup_payloads: &[Vec<u8>],
) -> Vec<IterStat> {
    let system = System::new();
    system.mint_to(ADMIN_ID, u128::MAX / 2);

    let code_id = system.submit_code(wasm);
    let program_id = calculate_program_id(code_id, b"salt".as_ref(), None);
    let code = system.submitted_code(code_id).expect("code stored");
    let program = Program::from_binary_with_id(&system, program_id, code);

    // Init.
    let _ = program.send_bytes_with_gas(
        ADMIN_ID,
        build_init_payload("name", "symbol", 10),
        MAX_USER_GAS_LIMIT,
        0,
    );
    let r = system.run_next_block();
    assert!(r.failed.is_empty(), "[{label}] init failed");

    // Impl-specific setup (shard alloc for bridges).
    for (i, payload) in setup_payloads.iter().enumerate() {
        let mid = program.send_bytes_with_gas(
            ADMIN_ID,
            payload.clone(),
            MAX_USER_GAS_LIMIT,
            0,
        );
        let r = system.run_next_block();
        if !r.succeed.contains(&mid) {
            for entry in &r.log {
                if entry.reply_to() == Some(mid) {
                    eprintln!("[{label}] setup #{i} reply: {:?}", entry.reply_code());
                }
            }
            panic!("[{label}] setup payload #{i} did not succeed");
        }
        eprintln!(
            "[{label}] setup #{i} ok (gas = {})",
            r.gas_burned.get(&mid).copied().unwrap_or(0)
        );
    }

    // Pre-mint 2^60 VFT to admin so we never run out of source balance.
    let initial_mint: u64 = 1u64 << 60;
    let mid = program.send_bytes_with_gas(
        ADMIN_ID,
        mint_builder(ADMIN_ID, initial_mint),
        MAX_USER_GAS_LIMIT,
        0,
    );
    let r = system.run_next_block();
    if !r.succeed.contains(&mid) {
        for entry in &r.log {
            if entry.reply_to() == Some(mid) {
                eprintln!("[{label}] admin mint reply: {:?}", entry.reply_code());
            }
        }
        panic!("[{label}] admin mint did not succeed");
    }
    eprintln!(
        "[{label}] admin minted 2^60 (gas = {})",
        r.gas_burned.get(&mid).copied().unwrap_or(0)
    );

    let mut stats = Vec::with_capacity(n_iters);
    let mut state: u64 = seed;
    let mut rand_u64 = || {
        state = state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        state ^ (state >> 32)
    };
    let mut approve_value: u64 = 0;

    let started_at = Instant::now();
    'outer: for iter in 0..n_iters {
        let iter_start = Instant::now();

        // ---- Transfers: admin → fresh random recipient ----
        let mut tsum: u64 = 0;
        for op_idx in 0..ops_per_iter {
            let mut to = rand_u64();
            while to == ADMIN_ID || to == 0 {
                to = rand_u64();
            }
            let mid = program.send_bytes_with_gas(
                ADMIN_ID,
                build_transfer_payload(to, 1),
                MAX_USER_GAS_LIMIT,
                0,
            );
            let r = system.run_next_block();
            if !r.succeed.contains(&mid) {
                eprintln!(
                    "[{label}] TRANSFER FAIL iter={iter} op={op_idx} to={to}"
                );
                for entry in &r.log {
                    if entry.reply_to() == Some(mid) {
                        eprintln!("  reply: {:?}", entry.reply_code());
                    }
                }
                break 'outer;
            }
            tsum += *r.gas_burned.get(&mid).expect("gas info");
        }

        // ---- Approves: admin → fresh random spender ----
        let mut asum: u64 = 0;
        for op_idx in 0..ops_per_iter {
            let mut spender = rand_u64();
            while spender == ADMIN_ID || spender == 0 {
                spender = rand_u64();
            }
            approve_value += 1;
            let mid = program.send_bytes_with_gas(
                ADMIN_ID,
                build_approve_payload(spender, approve_value),
                MAX_USER_GAS_LIMIT,
                0,
            );
            let r = system.run_next_block();
            if !r.succeed.contains(&mid) {
                eprintln!(
                    "[{label}] APPROVE FAIL iter={iter} op={op_idx} \
                     spender={spender} value={approve_value}"
                );
                for entry in &r.log {
                    if entry.reply_to() == Some(mid) {
                        eprintln!("  reply: {:?}", entry.reply_code());
                    }
                }
                break 'outer;
            }
            asum += *r.gas_burned.get(&mid).expect("gas info");
        }

        let avg_t = tsum / ops_per_iter as u64;
        let avg_a = asum / ops_per_iter as u64;
        eprintln!(
            "[{label}] iter {iter:>3}/{n_iters} ({:.1}s/iter, {:.0}s total): \
             transfer={avg_t}, approve={avg_a}",
            iter_start.elapsed().as_secs_f64(),
            started_at.elapsed().as_secs_f64()
        );
        stats.push(IterStat {
            avg_transfer: avg_t,
            avg_approve: avg_a,
        });
    }

    eprintln!(
        "[{label}] collected {}/{} iterations",
        stats.len(),
        n_iters
    );
    stats
}

fn write_csv(path: &std::path::Path, stats: &[IterStat]) {
    use std::io::Write;
    let mut f = std::fs::File::create(path).expect("create csv");
    writeln!(f, "iter,avg_transfer,avg_approve").unwrap();
    for (i, s) in stats.iter().enumerate() {
        writeln!(f, "{},{},{}", i, s.avg_transfer, s.avg_approve).unwrap();
    }
    eprintln!("wrote {}", path.display());
}

fn run_plot(script: &std::path::Path, out_dir: &std::path::Path, ops_per_iter: usize) {
    let png_path = out_dir.join("gas_growth.png");
    let status = std::process::Command::new("python3")
        .arg(script)
        .arg(out_dir)
        .arg(ops_per_iter.to_string())
        .status();
    match status {
        Ok(s) if s.success() => eprintln!("wrote {}", png_path.display()),
        Ok(s) => eprintln!("plot script exited with {s:?}"),
        Err(e) => eprintln!("could not run python3 {}: {e}", script.display()),
    }
}

// =====================================================================
// Entry point
// =====================================================================

fn main() {
    let cli = Cli::parse();
    std::fs::create_dir_all(&cli.out_dir).expect("create out_dir");

    eprintln!(
        "vara-ft-wat bench: iters={} ops={} seed={:#x} impls={:?} out_dir={}",
        cli.iters, cli.ops, cli.seed, cli.impls, cli.out_dir.display()
    );

    let setup_bridges = vec![
        build_alloc_balances_shard_payload(),
        build_alloc_allowances_shard_payload(),
    ];

    for impl_kind in &cli.impls {
        let (label, wasm, mint_builder, setup): (
            &str,
            &[u8],
            fn(u64, u64) -> Vec<u8>,
            &[Vec<u8>],
        ) = match impl_kind {
            Impl::Wat => ("WAT", WAT_WASM, build_mint_payload_vft, &[]),
            Impl::Bridges => (
                "Bridges",
                BRIDGES_WASM,
                build_mint_payload_bridges,
                &setup_bridges,
            ),
        };
        let stats = measure_growth(
            label, wasm, cli.seed, cli.iters, cli.ops, mint_builder, setup,
        );
        let csv_path = cli
            .out_dir
            .join(format!("gas_growth_{}.csv", impl_kind.csv_name()));
        write_csv(&csv_path, &stats);
    }

    if !cli.no_plot {
        run_plot(&cli.plot_script, &cli.out_dir, cli.ops);
    }
}
