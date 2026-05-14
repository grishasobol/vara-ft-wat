;; ===========================================================================
;; extended-vft contract — hand-written WAT
;;
;; Implements the same wire-level interface as the Rust-based extended-vft
;; (sails-rs). Tests in `extended-vft/tests/test.rs` exercise this contract.
;;
;; sails-rs wire protocol:
;;   handle  msg     = SCALE("Vft") ++ SCALE("<Method>") ++ SCALE(params)
;;   init    msg     = SCALE("New") ++ SCALE(params)
;;   reply (non-unit) = SCALE("Vft") ++ SCALE("<Method>") ++ SCALE(result)
;;   reply (unit)     = empty (gear auto-reply on handle exit)
;;
;; A SCALE-encoded String is: compact-len + UTF-8 bytes.
;; For len < 64 the compact-len is one byte = len << 2.
;;
;; Memory layout (WASM page = 64 KB = 0x10000):
;;   page  0           : auxiliary stack (__gear_stack_end at 0x010000).
;;                       IN_BUF / OUT_BUF / U256 scratch / source live here.
;;                       Stack pages are not lazy-tracked by gear, but we
;;                       only use ~6 KB so the rest is just unused.
;;   page  1           : meta — routes blob, name/symbol, decimals,
;;                       total_supply.
;;   page  2           : roles — admins / minters / burners (≤639 each).
;;   pages 3..1026     : balances  (2^20 * 64 B = 64 MB)
;;   pages 1027..13314 : allowances (2^23 * 96 B = 768 MB)
;;   pages 13315..32767: unused; pre-declared so the executor never has to
;;                       grow memory (gear's instrumentation forbids memory.grow).
;;                       Pages are lazy: cost is paid only on first touch, so
;;                       declaring 2 GB up-front is free for unread pages.
;;
;; Balances/allowances are open-addressing hash tables with linear probing.
;; Slot "empty" = the slot's key region is all zero bytes.
;; When a balance/allowance becomes zero we keep the slot in place with
;; value=0 (a tombstone). This preserves probe chains and is functionally
;; identical for balance_of/allowance queries.
;; ===========================================================================
(module
  ;; ------------------------------------------------------------------------
  ;; Imports
  ;; ------------------------------------------------------------------------
  ;; Pre-declare the full 32768-page (= 2 GB) linear memory up-front. Gear's
  ;; gas-instrumentation banlists memory.grow, so we must reserve everything we
  ;; might ever touch. Pages are lazily mapped by the executor (and by the OS
  ;; on top of that), so unused pages cost neither RAM nor gas — only pages
  ;; that the code actually reads or writes do.
  (import "env" "memory"    (memory 32768))
  (import "env" "gr_size"   (func $gr_size   (param i32)))
  (import "env" "gr_read"   (func $gr_read   (param i32 i32 i32 i32)))
  (import "env" "gr_source" (func $gr_source (param i32)))
  (import "env" "gr_reply"  (func $gr_reply  (param i32 i32 i32 i32)))
  (import "env" "gr_panic"  (func $gr_panic  (param i32 i32)))

  ;; ------------------------------------------------------------------------
  ;; Exports
  ;; ------------------------------------------------------------------------
  (export "init"             (func $init))
  (export "handle"           (func $handle))
  (export "__gear_stack_end" (global $stack_end))

  ;; Aux stack ends at the start of page 1 (0x010000). The page below is
  ;; used for per-call scratch (input/output message buffers, SOURCE_BUF,
  ;; U256 temporaries). Per-call writes overwrite earlier garbage, so no
  ;; persistence requirement → safe to live in the stack region.
  (global $stack_end i32 (i32.const 0x010000))

  ;; ------------------------------------------------------------------------
  ;; Static data segment
  ;;
  ;; All routes packed at 0x010000 (the start of page 64). Each route is
  ;; SCALE-encoded String prefixed by a compact length byte.
  ;;
  ;;   Offset Route           Bytes
  ;;     0     "Vft"             4
  ;;     4     "New"             4
  ;;     8     "Burn"            5
  ;;    13     "Mint"            5
  ;;    18     "Approve"         8
  ;;    26     "Transfer"        9
  ;;    35     "TransferFrom"   13
  ;;    48     "Allowance"      10
  ;;    58     "BalanceOf"      10
  ;;    68     "Decimals"        9
  ;;    77     "Name"            5
  ;;    82     "Symbol"          7
  ;;    89     "TotalSupply"    12
  ;;   101     "GrantAdminRole" 15
  ;;   116     "GrantMinterRole"16
  ;;   132     "GrantBurnerRole"16
  ;;   148     "RevokeAdminRole"16
  ;;   164     "RevokeMinterRole"17
  ;;   181     "RevokeBurnerRole"17
  ;;   198     "Admins"          7
  ;;   205     "Minters"         8
  ;;   213     "Burners"         8
  ;; ------------------------------------------------------------------------
  (data (i32.const 0x010000)
    "\0cVft"
    "\0cNew"
    "\10Burn"
    "\10Mint"
    "\1cApprove"
    "\20Transfer"
    "\30TransferFrom"
    "\24Allowance"
    "\24BalanceOf"
    "\20Decimals"
    "\10Name"
    "\18Symbol"
    "\2cTotalSupply"
    "\38GrantAdminRole"
    "\3cGrantMinterRole"
    "\3cGrantBurnerRole"
    "\3cRevokeAdminRole"
    "\40RevokeMinterRole"
    "\40RevokeBurnerRole"
    "\18Admins"
    "\1cMinters"
    "\1cBurners"
  )

  ;; Short panic message. Tests check only that a call panicked, not the
  ;; text; gas paths are uniform regardless of which failure fired.
  (data (i32.const 0x0100E0) "panic")

  ;; ------------------------------------------------------------------------
  ;; Memory map (all addresses are i32 constants used inline):
  ;;
  ;; --- aux stack (page 0, per-call scratch, not lazy-tracked) ---
  ;;   0x000100 SIZE_BUF    (4 B; used by gr_size and read_compact's len_out)
  ;;   0x000110 ERR_BUF     (36 B; ErrorWithHash for gr_reply / gr_read)
  ;;   0x000140 SOURCE_BUF  (32 B; cached msg::source)
  ;;   0x000180 ZERO_VALUE  (16 B; u128 zero — passed as `value` to gr_reply)
  ;;   0x0001A0 SCR_A       (32 B; U256 scratch)
  ;;   0x0001C0 SCR_B       (32 B)
  ;;   0x0001E0 SCR_C       (32 B)
  ;;   0x000400 IN_BUF      (1024 B; incoming message; we panic on size > 1024)
  ;;   0x000800 OUT_BUF     (2048 B; reply construction; result slot at +0x100,
  ;;                        Vec<ActorId> staging at +0x200)
  ;;
  ;; --- meta (page 1) ---
  ;;   0x010000 ROUTES blob (221 B)
  ;;   0x0100E0 panic string (5 B)
  ;;   0x010200 NAME_BUF    (128 B; SCALE-encoded blob, ready for reply)
  ;;   0x010280 SYMBOL_BUF  (128 B; SCALE-encoded blob)
  ;;   0x010300 DECIMALS    (1 B; padded)
  ;;   0x010320 TOTAL_SUPPLY(32 B; U256 LE)
  ;;
  ;; --- roles (page 2; 3 × 0x5000 sections, ≤639 entries each) ---
  ;;   0x020000 ADMINS      (u32 len at +0; 32-B entries from +16)
  ;;   0x025000 MINTERS
  ;;   0x02A000 BURNERS
  ;;
  ;; --- bulk hash tables (lazy pages, only touched slots cost gas) ---
  ;;   0x030000   BAL_BASE   (2^20 slots * 64 B  = 64 MB,  pages 3..1026)
  ;;   0x4030000  ALLOW_BASE (2^23 slots * 96 B  = 768 MB, pages 1027..13314)
  ;; ------------------------------------------------------------------------

  ;; ========================================================================
  ;; 32-byte primitive helpers (ActorId / U256)
  ;; ========================================================================
  (func $memcpy32 (param $dst i32) (param $src i32)
    (i64.store offset=0  (local.get $dst) (i64.load offset=0  (local.get $src)))
    (i64.store offset=8  (local.get $dst) (i64.load offset=8  (local.get $src)))
    (i64.store offset=16 (local.get $dst) (i64.load offset=16 (local.get $src)))
    (i64.store offset=24 (local.get $dst) (i64.load offset=24 (local.get $src)))
  )

  (func $zero32 (param $p i32)
    (i64.store offset=0  (local.get $p) (i64.const 0))
    (i64.store offset=8  (local.get $p) (i64.const 0))
    (i64.store offset=16 (local.get $p) (i64.const 0))
    (i64.store offset=24 (local.get $p) (i64.const 0))
  )

  (func $eq32 (param $a i32) (param $b i32) (result i32)
    (i32.and
      (i32.and
        (i64.eq (i64.load offset=0 (local.get $a))
                (i64.load offset=0 (local.get $b)))
        (i64.eq (i64.load offset=8 (local.get $a))
                (i64.load offset=8 (local.get $b))))
      (i32.and
        (i64.eq (i64.load offset=16 (local.get $a))
                (i64.load offset=16 (local.get $b)))
        (i64.eq (i64.load offset=24 (local.get $a))
                (i64.load offset=24 (local.get $b)))))
  )

  (func $is_zero32 (param $p i32) (result i32)
    (i32.and
      (i32.and
        (i64.eqz (i64.load offset=0  (local.get $p)))
        (i64.eqz (i64.load offset=8  (local.get $p))))
      (i32.and
        (i64.eqz (i64.load offset=16 (local.get $p)))
        (i64.eqz (i64.load offset=24 (local.get $p)))))
  )

  ;; ========================================================================
  ;; U256 arithmetic (4 x i64 LE limbs)
  ;; ========================================================================

  ;; out = a + b. Returns 1 on overflow.
  (func $u256_add
        (param $a i32) (param $b i32) (param $out i32) (result i32)
    (local $i i32)
    (local $carry i64)
    (local $av i64) (local $bv i64) (local $sum i64) (local $c1 i64)
    (block $end
      (loop $loop
        (local.set $av (i64.load (i32.add (local.get $a) (local.get $i))))
        (local.set $bv (i64.load (i32.add (local.get $b) (local.get $i))))
        (local.set $sum (i64.add (local.get $av) (local.get $bv)))
        (local.set $c1
          (i64.extend_i32_u
            (i64.lt_u (local.get $sum) (local.get $av))))
        (local.set $sum (i64.add (local.get $sum) (local.get $carry)))
        (local.set $carry
          (i64.or (local.get $c1)
                  (i64.extend_i32_u
                    (i64.lt_u (local.get $sum) (local.get $carry)))))
        (i64.store (i32.add (local.get $out) (local.get $i)) (local.get $sum))
        (local.set $i (i32.add (local.get $i) (i32.const 8)))
        (br_if $loop (i32.lt_u (local.get $i) (i32.const 32)))
      )
    )
    (i32.wrap_i64 (local.get $carry))
  )

  ;; out = a - b. Returns 1 on underflow.
  (func $u256_sub
        (param $a i32) (param $b i32) (param $out i32) (result i32)
    (local $i i32)
    (local $borrow i64)
    (local $av i64) (local $bv i64) (local $diff i64)
    (local $b1 i64) (local $b2 i64)
    (block $end
      (loop $loop
        (local.set $av (i64.load (i32.add (local.get $a) (local.get $i))))
        (local.set $bv (i64.load (i32.add (local.get $b) (local.get $i))))
        ;; b1 = (av < bv) ? 1 : 0  (first sub underflows)
        (local.set $b1
          (i64.extend_i32_u
            (i64.lt_u (local.get $av) (local.get $bv))))
        (local.set $diff (i64.sub (local.get $av) (local.get $bv)))
        ;; b2 = (diff < borrow) ? 1 : 0 (second sub underflows; uses OLD borrow)
        (local.set $b2
          (i64.extend_i32_u
            (i64.lt_u (local.get $diff) (local.get $borrow))))
        (local.set $diff (i64.sub (local.get $diff) (local.get $borrow)))
        (local.set $borrow (i64.or (local.get $b1) (local.get $b2)))
        (i64.store (i32.add (local.get $out) (local.get $i)) (local.get $diff))
        (local.set $i (i32.add (local.get $i) (i32.const 8)))
        (br_if $loop (i32.lt_u (local.get $i) (i32.const 32)))
      )
    )
    (i32.wrap_i64 (local.get $borrow))
  )

  ;; ========================================================================
  ;; Hashing
  ;; ========================================================================

  ;; 32-bit XOR-fold of the eight i32 lanes, then Fibonacci-multiplicative
  ;; mixing — using top 20 bits to spread sequential u64-derived ActorIds
  ;; evenly across the 2^20-slot balances table.
  (func $hash_actor (param $p i32) (result i32)
    (local $h i32)
    (local.set $h (i32.load offset=0  (local.get $p)))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=4  (local.get $p))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=8  (local.get $p))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=12 (local.get $p))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=16 (local.get $p))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=20 (local.get $p))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=24 (local.get $p))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=28 (local.get $p))))
    (i32.shr_u
      (i32.mul (local.get $h) (i32.const 0x9E3779B9))
      (i32.const 12))
  )

  ;; Hash of (owner, spender) for the allowances table. XOR-fold all 16 i32
  ;; lanes, then Fibonacci-multiplicative mixing and take the top 23 bits.
  ;; Matches $hash_actor's diffusion quality so clustered owner/spender pairs
  ;; (one owner approving many sequential spenders) still distribute evenly.
  (func $hash_pair (param $a i32) (param $b i32) (result i32)
    (local $h i32)
    (local.set $h (i32.load offset=0  (local.get $a)))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=4  (local.get $a))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=8  (local.get $a))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=12 (local.get $a))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=16 (local.get $a))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=20 (local.get $a))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=24 (local.get $a))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=28 (local.get $a))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=0  (local.get $b))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=4  (local.get $b))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=8  (local.get $b))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=12 (local.get $b))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=16 (local.get $b))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=20 (local.get $b))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=24 (local.get $b))))
    (local.set $h (i32.xor (local.get $h) (i32.load offset=28 (local.get $b))))
    (i32.shr_u
      (i32.mul (local.get $h) (i32.const 0x9E3779B9))
      (i32.const 9))
  )

  ;; ========================================================================
  ;; Balances table — 2^20 slots * 64 B (32 actor + 32 value), at 0x030000.
  ;; ========================================================================

  ;; Locate slot for $actor: returns either the matching slot or the first
  ;; empty (all-zero actor field) slot in the probe chain.
  (func $bal_find (param $actor i32) (result i32)
    (local $hash i32) (local $tries i32) (local $slot i32)
    (local.set $hash (call $hash_actor (local.get $actor)))
    (block $found (result i32)
      (loop $probe (result i32)
        (local.set $slot
          (i32.add (i32.const 0x030000)
                   (i32.shl (local.get $hash) (i32.const 6))))   ;; * 64
        (if (call $eq32 (local.get $slot) (local.get $actor))
            (then (br $found (local.get $slot))))
        (if (call $is_zero32 (local.get $slot))
            (then (br $found (local.get $slot))))
        (local.set $hash
          (i32.and (i32.add (local.get $hash) (i32.const 1))
                   (i32.const 0xFFFFF)))
        (local.set $tries (i32.add (local.get $tries) (i32.const 1)))
        ;; Safety: never loop more than table size; if we do, return slot.
        (br_if $probe (i32.lt_u (local.get $tries) (i32.const 1048576)))
        (local.get $slot)
      )
    )
  )

  (func $bal_load (param $actor i32) (param $out i32)
    (local $slot i32)
    (local.set $slot (call $bal_find (local.get $actor)))
    (if (call $eq32 (local.get $slot) (local.get $actor))
        (then
          (call $memcpy32 (local.get $out)
                          (i32.add (local.get $slot) (i32.const 32))))
        (else
          (call $zero32 (local.get $out))))
  )

  (func $bal_store (param $actor i32) (param $value i32)
    (local $slot i32)
    (local.set $slot (call $bal_find (local.get $actor)))
    (call $memcpy32 (local.get $slot) (local.get $actor))
    (call $memcpy32 (i32.add (local.get $slot) (i32.const 32))
                    (local.get $value))
  )

  ;; ========================================================================
  ;; Allowances table — 2^23 slots * 96 B (32 owner + 32 spender + 32 value),
  ;; at 0x4030000.
  ;; ========================================================================

  (func $allow_find (param $owner i32) (param $spender i32) (result i32)
    (local $hash i32) (local $tries i32) (local $slot i32)
    (local.set $hash (call $hash_pair (local.get $owner) (local.get $spender)))
    (block $found (result i32)
      (loop $probe (result i32)
        ;; slot = ALLOW_BASE + hash * 96
        (local.set $slot
          (i32.add (i32.const 0x4030000)
                   (i32.mul (local.get $hash) (i32.const 96))))
        ;; Match?
        (if (i32.and
              (call $eq32 (local.get $slot) (local.get $owner))
              (call $eq32 (i32.add (local.get $slot) (i32.const 32))
                          (local.get $spender)))
            (then (br $found (local.get $slot))))
        ;; Empty? (owner field all zero AND spender field all zero)
        (if (i32.and
              (call $is_zero32 (local.get $slot))
              (call $is_zero32 (i32.add (local.get $slot) (i32.const 32))))
            (then (br $found (local.get $slot))))
        (local.set $hash
          (i32.and (i32.add (local.get $hash) (i32.const 1))
                   (i32.const 0x7FFFFF)))
        (local.set $tries (i32.add (local.get $tries) (i32.const 1)))
        (br_if $probe (i32.lt_u (local.get $tries) (i32.const 8388608)))
        (local.get $slot)
      )
    )
  )

  (func $allow_load (param $owner i32) (param $spender i32) (param $out i32)
    (local $slot i32)
    (local.set $slot (call $allow_find (local.get $owner) (local.get $spender)))
    (if (i32.and
          (call $eq32 (local.get $slot) (local.get $owner))
          (call $eq32 (i32.add (local.get $slot) (i32.const 32))
                      (local.get $spender)))
        (then
          (call $memcpy32 (local.get $out)
                          (i32.add (local.get $slot) (i32.const 64))))
        (else
          (call $zero32 (local.get $out))))
  )

  (func $allow_store
        (param $owner i32) (param $spender i32) (param $value i32)
    (local $slot i32)
    (local.set $slot (call $allow_find (local.get $owner) (local.get $spender)))
    (call $memcpy32 (local.get $slot) (local.get $owner))
    (call $memcpy32 (i32.add (local.get $slot) (i32.const 32))
                    (local.get $spender))
    (call $memcpy32 (i32.add (local.get $slot) (i32.const 64))
                    (local.get $value))
  )

  ;; ========================================================================
  ;; Role sets — linear arrays in static memory.
  ;;   base[+0..+4)  : u32 length
  ;;   base[+16..)   : N * 32 B entries (offset 16 for alignment, room for len)
  ;; ========================================================================

  (func $set_contains (param $base i32) (param $actor i32) (result i32)
    (local $len i32) (local $i i32) (local $entry i32)
    (local.set $len (i32.load (local.get $base)))
    (block $end
      (loop $loop
        (br_if $end (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $entry
          (i32.add (i32.add (local.get $base) (i32.const 16))
                   (i32.shl (local.get $i) (i32.const 5))))    ;; * 32
        (if (call $eq32 (local.get $entry) (local.get $actor))
            (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
    (i32.const 0)
  )

  (func $set_insert (param $base i32) (param $actor i32)
    (local $len i32) (local $i i32) (local $entry i32)
    (local.set $len (i32.load (local.get $base)))
    (block $end
      (loop $loop
        (br_if $end (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $entry
          (i32.add (i32.add (local.get $base) (i32.const 16))
                   (i32.shl (local.get $i) (i32.const 5))))
        (if (call $eq32 (local.get $entry) (local.get $actor))
            (then (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
    (local.set $entry
      (i32.add (i32.add (local.get $base) (i32.const 16))
               (i32.shl (local.get $len) (i32.const 5))))
    (call $memcpy32 (local.get $entry) (local.get $actor))
    (i32.store (local.get $base) (i32.add (local.get $len) (i32.const 1)))
  )

  (func $set_remove (param $base i32) (param $actor i32)
    (local $len i32) (local $i i32) (local $entry i32) (local $last i32)
    (local.set $len (i32.load (local.get $base)))
    (block $end
      (loop $loop
        (br_if $end (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $entry
          (i32.add (i32.add (local.get $base) (i32.const 16))
                   (i32.shl (local.get $i) (i32.const 5))))
        (if (call $eq32 (local.get $entry) (local.get $actor))
            (then
              (local.set $len (i32.sub (local.get $len) (i32.const 1)))
              (if (i32.lt_u (local.get $i) (local.get $len))
                  (then
                    (local.set $last
                      (i32.add (i32.add (local.get $base) (i32.const 16))
                               (i32.shl (local.get $len) (i32.const 5))))
                    (call $memcpy32 (local.get $entry) (local.get $last))))
              (i32.store (local.get $base) (local.get $len))
              (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; ========================================================================
  ;; Byte helpers
  ;; ========================================================================
  (func $memcpy (param $dst i32) (param $src i32) (param $len i32)
    (local $i i32)
    (block $end
      (loop $loop
        (br_if $end (i32.ge_u (local.get $i) (local.get $len)))
        (i32.store8
          (i32.add (local.get $dst) (local.get $i))
          (i32.load8_u (i32.add (local.get $src) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  (func $memeq (param $a i32) (param $b i32) (param $len i32) (result i32)
    (local $i i32)
    (block $end
      (loop $loop
        (br_if $end (i32.ge_u (local.get $i) (local.get $len)))
        (if (i32.ne (i32.load8_u (i32.add (local.get $a) (local.get $i)))
                    (i32.load8_u (i32.add (local.get $b) (local.get $i))))
            (then (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
    (i32.const 1)
  )

  ;; ========================================================================
  ;; SCALE compact length codec
  ;; ========================================================================

  ;; Decode SCALE compact at $ptr. Writes bytes consumed to *$len_out.
  ;; Returns the value as u32. Only modes 0..2 are supported; bigger sizes are
  ;; not used by our parameter set.
  (func $read_compact (param $ptr i32) (param $len_out i32) (result i32)
    (local $b0 i32)
    (local.set $b0 (i32.load8_u (local.get $ptr)))
    (block $two
      (block $one
        (br_if $one (i32.eq (i32.and (local.get $b0) (i32.const 3))
                            (i32.const 0)))
        (br_if $two (i32.eq (i32.and (local.get $b0) (i32.const 3))
                            (i32.const 1)))
        ;; mode 2: 4-byte
        (i32.store (local.get $len_out) (i32.const 4))
        (return (i32.shr_u (i32.load (local.get $ptr)) (i32.const 2)))
      )
      ;; mode 0: 1-byte
      (i32.store (local.get $len_out) (i32.const 1))
      (return (i32.shr_u (local.get $b0) (i32.const 2)))
    )
    ;; mode 1: 2-byte
    (i32.store (local.get $len_out) (i32.const 2))
    (i32.shr_u (i32.load16_u (local.get $ptr)) (i32.const 2))
  )

  ;; Write SCALE compact length at $out. Returns bytes written.
  (func $write_compact (param $out i32) (param $val i32) (result i32)
    (if (i32.lt_u (local.get $val) (i32.const 64))
        (then
          (i32.store8 (local.get $out)
            (i32.shl (local.get $val) (i32.const 2)))
          (return (i32.const 1))))
    (if (i32.lt_u (local.get $val) (i32.const 16384))
        (then
          (i32.store16 (local.get $out)
            (i32.or (i32.shl (local.get $val) (i32.const 2))
                    (i32.const 1)))
          (return (i32.const 2))))
    (i32.store (local.get $out)
      (i32.or (i32.shl (local.get $val) (i32.const 2))
              (i32.const 2)))
    (i32.const 4)
  )

  ;; ========================================================================
  ;; Reply construction
  ;; ========================================================================

  ;; Compose reply [SCALE("Vft") ++ method_route ++ result_bytes] into OUT_BUF
  ;; and send via gr_reply.
  ;;
  ;;   $route_off : offset of method route inside ROUTES blob (rel. 0x010000)
  ;;   $route_len : length of method route in bytes
  ;;   $result    : pointer to result bytes
  ;;   $result_len: result length
  (func $emit_reply
        (param $route_off i32) (param $route_len i32)
        (param $result i32)    (param $result_len i32)
    (local $total i32)
    ;; OUT_BUF[0..4] = "\0cVft"
    (i32.store (i32.const 0x000800) (i32.load (i32.const 0x010000)))
    ;; OUT_BUF[4..4+route_len] = method route bytes
    (call $memcpy (i32.const 0x000804)
                  (i32.add (i32.const 0x010000) (local.get $route_off))
                  (local.get $route_len))
    (local.set $total (i32.add (i32.const 4) (local.get $route_len)))
    ;; OUT_BUF[total..] = result bytes
    (call $memcpy (i32.add (i32.const 0x000800) (local.get $total))
                  (local.get $result)
                  (local.get $result_len))
    (local.set $total (i32.add (local.get $total) (local.get $result_len)))
    (call $gr_reply (i32.const 0x000800)
                    (local.get $total)
                    (i32.const 0x000180)
                    (i32.const 0x000110))
  )

  ;; Tiny helper: trap with a generic panic.
  (func $panic
    (call $gr_panic (i32.const 0x0100E0) (i32.const 5))
    (unreachable)
  )

  ;; ========================================================================
  ;; INIT — New(name: String, symbol: String, decimals: u8)
  ;; ========================================================================
  (func $init
    (local $size i32) (local $ptr i32) (local $consumed i32)
    (local $nlen i32) (local $slen i32)

    ;; Read incoming message. IN_BUF is exactly 1024 bytes — any larger
    ;; payload is malformed (legitimate inputs top out around 100 B), so
    ;; reject it with a panic before gr_read can overflow.
    (call $gr_size (i32.const 0x000100))
    (local.set $size (i32.load (i32.const 0x000100)))
    (if (i32.gt_u (local.get $size) (i32.const 1024))
        (then (call $panic)))
    (call $gr_read (i32.const 0) (local.get $size)
                   (i32.const 0x000400) (i32.const 0x000110))

    ;; Expect "New" prefix at ROUTES+4 (4 bytes).
    (if (i32.eqz
          (call $memeq (i32.const 0x000400)
                       (i32.const 0x010004)
                       (i32.const 4)))
        (then (call $panic)))

    (local.set $ptr (i32.const 0x000404))

    ;; Decode name (String) — keep the SCALE-encoded blob in NAME_BUF so that
    ;; the `Name` query reply can be emitted by direct memcpy.
    (local.set $nlen
      (call $read_compact (local.get $ptr) (i32.const 0x000100)))
    (local.set $consumed (i32.load (i32.const 0x000100)))
    (call $memcpy (i32.const 0x010200)
                  (local.get $ptr)
                  (i32.add (local.get $consumed) (local.get $nlen)))
    (local.set $ptr
      (i32.add (local.get $ptr)
               (i32.add (local.get $consumed) (local.get $nlen))))

    ;; Decode symbol.
    (local.set $slen
      (call $read_compact (local.get $ptr) (i32.const 0x000100)))
    (local.set $consumed (i32.load (i32.const 0x000100)))
    (call $memcpy (i32.const 0x010280)
                  (local.get $ptr)
                  (i32.add (local.get $consumed) (local.get $slen)))
    (local.set $ptr
      (i32.add (local.get $ptr)
               (i32.add (local.get $consumed) (local.get $slen))))

    ;; decimals: u8.
    (i32.store8 (i32.const 0x010300) (i32.load8_u (local.get $ptr)))

    ;; msg::source → SOURCE_BUF. Add to all three role sets.
    (call $gr_source (i32.const 0x000140))
    (call $set_insert (i32.const 0x020000) (i32.const 0x000140))
    (call $set_insert (i32.const 0x025000) (i32.const 0x000140))
    (call $set_insert (i32.const 0x02A000) (i32.const 0x000140))
    ;; Gear auto-reply will signal init success.
  )

  ;; ========================================================================
  ;; Method handlers
  ;;
  ;; Each handler receives $params: a pointer just past the method-route bytes
  ;; in the incoming message. It runs the business logic, builds the reply
  ;; (if non-unit) and returns. Panics are signalled via $panic.
  ;; ========================================================================

  ;; transfer(to: ActorId, value: U256) -> bool
  (func $h_transfer (param $params i32)
    (local $to i32) (local $val i32)
    (local.set $to  (local.get $params))
    (local.set $val (i32.add (local.get $params) (i32.const 32)))

    ;; if from == to || value == 0 → reply false
    (if (i32.or
          (call $eq32 (local.get $to) (i32.const 0x000140))
          (call $is_zero32 (local.get $val)))
        (then
          (i32.store8 (i32.const 0x000900) (i32.const 0))
          (call $emit_reply (i32.const 26) (i32.const 9)
                            (i32.const 0x000900) (i32.const 1))
          (return)))

    ;; new_from = balance(source) - value
    (call $bal_load (i32.const 0x000140) (i32.const 0x0001A0))
    (if (call $u256_sub
              (i32.const 0x0001A0) (local.get $val) (i32.const 0x0001A0))
        (then (call $panic)))

    ;; new_to = balance(to) + value
    (call $bal_load (local.get $to) (i32.const 0x0001C0))
    (if (call $u256_add
              (i32.const 0x0001C0) (local.get $val) (i32.const 0x0001C0))
        (then (call $panic)))

    (call $bal_store (i32.const 0x000140) (i32.const 0x0001A0))
    (call $bal_store (local.get $to)      (i32.const 0x0001C0))

    (i32.store8 (i32.const 0x000900) (i32.const 1))
    (call $emit_reply (i32.const 26) (i32.const 9)
                      (i32.const 0x000900) (i32.const 1))
  )

  ;; mint(to: ActorId, value: U256) -> bool  (requires source to be minter)
  (func $h_mint (param $params i32)
    (local $to i32) (local $val i32)
    (if (i32.eqz
          (call $set_contains (i32.const 0x025000) (i32.const 0x000140)))
        (then (call $panic)))
    (local.set $to  (local.get $params))
    (local.set $val (i32.add (local.get $params) (i32.const 32)))

    (if (call $is_zero32 (local.get $val))
        (then
          (i32.store8 (i32.const 0x000900) (i32.const 0))
          (call $emit_reply (i32.const 13) (i32.const 5)
                            (i32.const 0x000900) (i32.const 1))
          (return)))

    ;; new_total = total + value
    (if (call $u256_add (i32.const 0x010320) (local.get $val)
                        (i32.const 0x0001A0))
        (then (call $panic)))
    ;; new_to = balance(to) + value
    (call $bal_load (local.get $to) (i32.const 0x0001C0))
    (if (call $u256_add (i32.const 0x0001C0) (local.get $val)
                        (i32.const 0x0001C0))
        (then (call $panic)))

    (call $bal_store (local.get $to) (i32.const 0x0001C0))
    (call $memcpy32 (i32.const 0x010320) (i32.const 0x0001A0))

    (i32.store8 (i32.const 0x000900) (i32.const 1))
    (call $emit_reply (i32.const 13) (i32.const 5)
                      (i32.const 0x000900) (i32.const 1))
  )

  ;; burn(from: ActorId, value: U256) -> bool  (requires source to be burner)
  (func $h_burn (param $params i32)
    (local $from i32) (local $val i32)
    (if (i32.eqz
          (call $set_contains (i32.const 0x02A000) (i32.const 0x000140)))
        (then (call $panic)))
    (local.set $from (local.get $params))
    (local.set $val  (i32.add (local.get $params) (i32.const 32)))

    (if (call $is_zero32 (local.get $val))
        (then
          (i32.store8 (i32.const 0x000900) (i32.const 0))
          (call $emit_reply (i32.const 8) (i32.const 5)
                            (i32.const 0x000900) (i32.const 1))
          (return)))

    ;; new_total = total - value
    (if (call $u256_sub (i32.const 0x010320) (local.get $val)
                        (i32.const 0x0001A0))
        (then (call $panic)))
    ;; new_from = balance(from) - value
    (call $bal_load (local.get $from) (i32.const 0x0001C0))
    (if (call $u256_sub (i32.const 0x0001C0) (local.get $val)
                        (i32.const 0x0001C0))
        (then (call $panic)))

    (call $bal_store (local.get $from) (i32.const 0x0001C0))
    (call $memcpy32 (i32.const 0x010320) (i32.const 0x0001A0))

    (i32.store8 (i32.const 0x000900) (i32.const 1))
    (call $emit_reply (i32.const 8) (i32.const 5)
                      (i32.const 0x000900) (i32.const 1))
  )

  ;; approve(spender: ActorId, value: U256) -> bool
  ;; owner == msg::source
  (func $h_approve (param $params i32)
    (local $spender i32) (local $val i32) (local $slot i32)
    (local $had_value i32) (local $changed i32)
    (local.set $spender (local.get $params))
    (local.set $val     (i32.add (local.get $params) (i32.const 32)))

    ;; owner == spender → return false
    (if (call $eq32 (i32.const 0x000140) (local.get $spender))
        (then
          (i32.store8 (i32.const 0x000900) (i32.const 0))
          (call $emit_reply (i32.const 18) (i32.const 8)
                            (i32.const 0x000900) (i32.const 1))
          (return)))

    (local.set $slot (call $allow_find (i32.const 0x000140) (local.get $spender)))
    ;; had_value = slot.owner == source && slot.spender == spender (i.e., not empty)
    (local.set $had_value
      (i32.and
        (call $eq32 (local.get $slot) (i32.const 0x000140))
        (call $eq32 (i32.add (local.get $slot) (i32.const 32))
                    (local.get $spender))))

    (if (call $is_zero32 (local.get $val))
        (then
          ;; remove allowance
          (if (i32.eqz (local.get $had_value))
              (then
                (i32.store8 (i32.const 0x000900) (i32.const 0))
                (call $emit_reply (i32.const 18) (i32.const 8)
                                  (i32.const 0x000900) (i32.const 1))
                (return)))
          ;; Real allowance — check if old value was non-zero. If old was
          ;; already zero (tombstone), no mutation.
          (if (call $is_zero32 (i32.add (local.get $slot) (i32.const 64)))
              (then
                (i32.store8 (i32.const 0x000900) (i32.const 0))
                (call $emit_reply (i32.const 18) (i32.const 8)
                                  (i32.const 0x000900) (i32.const 1))
                (return)))
          (call $zero32 (i32.add (local.get $slot) (i32.const 64)))
          (i32.store8 (i32.const 0x000900) (i32.const 1))
          (call $emit_reply (i32.const 18) (i32.const 8)
                            (i32.const 0x000900) (i32.const 1))
          (return)))

    ;; value != 0
    (if (local.get $had_value)
        (then
          (if (call $eq32 (i32.add (local.get $slot) (i32.const 64))
                          (local.get $val))
              (then
                (i32.store8 (i32.const 0x000900) (i32.const 0))
                (call $emit_reply (i32.const 18) (i32.const 8)
                                  (i32.const 0x000900) (i32.const 1))
                (return)))
          (call $memcpy32 (i32.add (local.get $slot) (i32.const 64))
                          (local.get $val)))
        (else
          (call $memcpy32 (local.get $slot) (i32.const 0x000140))
          (call $memcpy32 (i32.add (local.get $slot) (i32.const 32))
                          (local.get $spender))
          (call $memcpy32 (i32.add (local.get $slot) (i32.const 64))
                          (local.get $val))))

    (i32.store8 (i32.const 0x000900) (i32.const 1))
    (call $emit_reply (i32.const 18) (i32.const 8)
                      (i32.const 0x000900) (i32.const 1))
  )

  ;; transfer_from(from: ActorId, to: ActorId, value: U256) -> bool
  ;; spender == msg::source
  (func $h_transfer_from (param $params i32)
    (local $from i32) (local $to i32) (local $val i32)
    (local.set $from (local.get $params))
    (local.set $to   (i32.add (local.get $params) (i32.const 32)))
    (local.set $val  (i32.add (local.get $params) (i32.const 64)))

    ;; If spender (source) == from → behave as plain transfer.
    (if (i32.eqz (call $eq32 (i32.const 0x000140) (local.get $from)))
        (then
          ;; spender != from
          ;; if from == to || value == 0 → reply false
          (if (i32.or
                (call $eq32 (local.get $from) (local.get $to))
                (call $is_zero32 (local.get $val)))
              (then
                (i32.store8 (i32.const 0x000900) (i32.const 0))
                (call $emit_reply (i32.const 35) (i32.const 13)
                                  (i32.const 0x000900) (i32.const 1))
                (return)))
          ;; new_allowance = allowance(from, source) - value
          (call $allow_load (local.get $from) (i32.const 0x000140)
                            (i32.const 0x0001A0))
          (if (call $u256_sub (i32.const 0x0001A0) (local.get $val)
                              (i32.const 0x0001A0))
              (then (call $panic)))
          ;; perform transfer(from -> to, value)
          (call $do_transfer_unchecked (local.get $from)
                                       (local.get $to)
                                       (local.get $val))
          ;; update allowance
          (call $allow_store (local.get $from) (i32.const 0x000140)
                             (i32.const 0x0001A0))
          (i32.store8 (i32.const 0x000900) (i32.const 1))
          (call $emit_reply (i32.const 35) (i32.const 13)
                            (i32.const 0x000900) (i32.const 1))
          (return)))

    ;; spender == from: plain transfer behavior
    (if (i32.or
          (call $eq32 (local.get $from) (local.get $to))
          (call $is_zero32 (local.get $val)))
        (then
          (i32.store8 (i32.const 0x000900) (i32.const 0))
          (call $emit_reply (i32.const 35) (i32.const 13)
                            (i32.const 0x000900) (i32.const 1))
          (return)))
    (call $do_transfer_unchecked (local.get $from) (local.get $to)
                                 (local.get $val))
    (i32.store8 (i32.const 0x000900) (i32.const 1))
    (call $emit_reply (i32.const 35) (i32.const 13)
                      (i32.const 0x000900) (i32.const 1))
  )

  ;; Shared transfer subroutine (assumes from != to and value != 0).
  ;; Panics on underflow / overflow.
  (func $do_transfer_unchecked
        (param $from i32) (param $to i32) (param $val i32)
    (call $bal_load (local.get $from) (i32.const 0x0001C0))
    (if (call $u256_sub (i32.const 0x0001C0) (local.get $val)
                        (i32.const 0x0001C0))
        (then (call $panic)))
    (call $bal_load (local.get $to) (i32.const 0x0001E0))
    (if (call $u256_add (i32.const 0x0001E0) (local.get $val)
                        (i32.const 0x0001E0))
        (then (call $panic)))
    (call $bal_store (local.get $from) (i32.const 0x0001C0))
    (call $bal_store (local.get $to)   (i32.const 0x0001E0))
  )

  ;; balance_of(account: ActorId) -> U256
  (func $h_balance_of (param $params i32)
    (call $bal_load (local.get $params) (i32.const 0x0001A0))
    (call $emit_reply (i32.const 58) (i32.const 10)
                      (i32.const 0x0001A0) (i32.const 32))
  )

  ;; allowance(owner, spender) -> U256
  (func $h_allowance (param $params i32)
    (call $allow_load (local.get $params)
                      (i32.add (local.get $params) (i32.const 32))
                      (i32.const 0x0001A0))
    (call $emit_reply (i32.const 48) (i32.const 10)
                      (i32.const 0x0001A0) (i32.const 32))
  )

  ;; decimals() -> u8
  (func $h_decimals
    (call $emit_reply (i32.const 68) (i32.const 9)
                      (i32.const 0x010300) (i32.const 1))
  )

  ;; total_supply() -> U256
  (func $h_total_supply
    (call $emit_reply (i32.const 89) (i32.const 12)
                      (i32.const 0x010320) (i32.const 32))
  )

  ;; name() -> String (SCALE-encoded blob stored verbatim)
  (func $h_name
    (local $consumed i32) (local $val i32)
    (local.set $val
      (call $read_compact (i32.const 0x010200) (i32.const 0x000100)))
    (local.set $consumed (i32.load (i32.const 0x000100)))
    (call $emit_reply (i32.const 77) (i32.const 5)
                      (i32.const 0x010200)
                      (i32.add (local.get $consumed) (local.get $val)))
  )

  ;; symbol() -> String
  (func $h_symbol
    (local $consumed i32) (local $val i32)
    (local.set $val
      (call $read_compact (i32.const 0x010280) (i32.const 0x000100)))
    (local.set $consumed (i32.load (i32.const 0x000100)))
    (call $emit_reply (i32.const 82) (i32.const 7)
                      (i32.const 0x010280)
                      (i32.add (local.get $consumed) (local.get $val)))
  )

  ;; Emit Vec<ActorId> for one role set at $base. Encodes compact len, then
  ;; n * 32 B actor IDs.
  ;;   $route_off, $route_len → method route bytes inside ROUTES blob.
  (func $emit_set_reply
        (param $base i32) (param $route_off i32) (param $route_len i32)
    (local $n i32) (local $cl i32) (local $payload_len i32)
    (local.set $n (i32.load (local.get $base)))
    ;; Write compact-len into a fresh scratch region inside OUT_BUF reserved
    ;; for the Vec payload (use 0x000A00; emit_reply will rebuild around it).
    (local.set $cl (call $write_compact (i32.const 0x000A00) (local.get $n)))
    ;; Copy n * 32 bytes after the length prefix.
    (call $memcpy
          (i32.add (i32.const 0x000A00) (local.get $cl))
          (i32.add (local.get $base) (i32.const 16))
          (i32.shl (local.get $n) (i32.const 5)))
    (local.set $payload_len
      (i32.add (local.get $cl) (i32.shl (local.get $n) (i32.const 5))))
    (call $emit_reply (local.get $route_off) (local.get $route_len)
                      (i32.const 0x000A00) (local.get $payload_len))
  )

  (func $h_admins  (call $emit_set_reply (i32.const 0x020000)
                                         (i32.const 198) (i32.const 7)))
  (func $h_minters (call $emit_set_reply (i32.const 0x025000)
                                         (i32.const 205) (i32.const 8)))
  (func $h_burners (call $emit_set_reply (i32.const 0x02A000)
                                         (i32.const 213) (i32.const 8)))

  ;; ensure_admin → panics if source is not in admins set.
  (func $ensure_admin
    (if (i32.eqz
          (call $set_contains (i32.const 0x020000) (i32.const 0x000140)))
        (then (call $panic)))
  )

  ;; grant_admin_role(to: ActorId) -> ()
  (func $h_grant_admin (param $params i32)
    (call $ensure_admin)
    (call $set_insert (i32.const 0x020000) (local.get $params))
  )
  (func $h_grant_minter (param $params i32)
    (call $ensure_admin)
    (call $set_insert (i32.const 0x025000) (local.get $params))
  )
  (func $h_grant_burner (param $params i32)
    (call $ensure_admin)
    (call $set_insert (i32.const 0x02A000) (local.get $params))
  )
  (func $h_revoke_admin (param $params i32)
    (call $ensure_admin)
    (call $set_remove (i32.const 0x020000) (local.get $params))
  )
  (func $h_revoke_minter (param $params i32)
    (call $ensure_admin)
    (call $set_remove (i32.const 0x025000) (local.get $params))
  )
  (func $h_revoke_burner (param $params i32)
    (call $ensure_admin)
    (call $set_remove (i32.const 0x02A000) (local.get $params))
  )

  ;; ========================================================================
  ;; HANDLE — dispatch by service prefix "Vft" then method route
  ;; ========================================================================
  (func $handle
    (local $size i32) (local $rem i32) (local $p i32)

    (call $gr_size (i32.const 0x000100))
    (local.set $size (i32.load (i32.const 0x000100)))
    ;; IN_BUF is 1024 B; legitimate payloads top out at ~113 B (TransferFrom).
    ;; Anything bigger is malformed — panic before gr_read overflows.
    (if (i32.gt_u (local.get $size) (i32.const 1024))
        (then (call $panic)))
    (call $gr_read (i32.const 0) (local.get $size)
                   (i32.const 0x000400) (i32.const 0x000110))

    (call $gr_source (i32.const 0x000140))

    ;; Expect "Vft" prefix (4 bytes at ROUTES+0).
    (if (i32.eqz
          (call $memeq (i32.const 0x000400)
                       (i32.const 0x010000)
                       (i32.const 4)))
        (then (call $panic)))

    (local.set $rem (i32.sub (local.get $size) (i32.const 4)))
    (local.set $p   (i32.const 0x000404))

    ;; Dispatch on the method route prefix.  Tried in order; first match wins.
    ;; The macro for each block: check enough bytes remain, compare route
    ;; bytes, advance to params, invoke handler.
    ;; Frequency-ordered: Transfer first.

    ;; Transfer (route_off=26, len=9)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 9))
          (call $memeq (local.get $p) (i32.const 0x01001A)
                       (i32.const 9)))
        (then (call $h_transfer (i32.add (local.get $p) (i32.const 9)))
              (return)))
    ;; BalanceOf (off=58, len=10)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 10))
          (call $memeq (local.get $p) (i32.const 0x01003A)
                       (i32.const 10)))
        (then (call $h_balance_of (i32.add (local.get $p) (i32.const 10)))
              (return)))
    ;; Approve (off=18, len=8)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 8))
          (call $memeq (local.get $p) (i32.const 0x010012)
                       (i32.const 8)))
        (then (call $h_approve (i32.add (local.get $p) (i32.const 8)))
              (return)))
    ;; Allowance (off=48, len=10)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 10))
          (call $memeq (local.get $p) (i32.const 0x010030)
                       (i32.const 10)))
        (then (call $h_allowance (i32.add (local.get $p) (i32.const 10)))
              (return)))
    ;; TransferFrom (off=35, len=13)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 13))
          (call $memeq (local.get $p) (i32.const 0x010023)
                       (i32.const 13)))
        (then (call $h_transfer_from (i32.add (local.get $p) (i32.const 13)))
              (return)))
    ;; Mint (off=13, len=5)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 5))
          (call $memeq (local.get $p) (i32.const 0x01000D)
                       (i32.const 5)))
        (then (call $h_mint (i32.add (local.get $p) (i32.const 5)))
              (return)))
    ;; Burn (off=8, len=5)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 5))
          (call $memeq (local.get $p) (i32.const 0x010008)
                       (i32.const 5)))
        (then (call $h_burn (i32.add (local.get $p) (i32.const 5)))
              (return)))
    ;; Name (off=77, len=5)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 5))
          (call $memeq (local.get $p) (i32.const 0x01004D)
                       (i32.const 5)))
        (then (call $h_name)
              (return)))
    ;; Symbol (off=82, len=7)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 7))
          (call $memeq (local.get $p) (i32.const 0x010052)
                       (i32.const 7)))
        (then (call $h_symbol)
              (return)))
    ;; Decimals (off=68, len=9)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 9))
          (call $memeq (local.get $p) (i32.const 0x010044)
                       (i32.const 9)))
        (then (call $h_decimals)
              (return)))
    ;; TotalSupply (off=89, len=12)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 12))
          (call $memeq (local.get $p) (i32.const 0x010059)
                       (i32.const 12)))
        (then (call $h_total_supply)
              (return)))
    ;; Admins (off=198, len=7)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 7))
          (call $memeq (local.get $p) (i32.const 0x0100C6)
                       (i32.const 7)))
        (then (call $h_admins)
              (return)))
    ;; Minters (off=205, len=8)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 8))
          (call $memeq (local.get $p) (i32.const 0x0100CD)
                       (i32.const 8)))
        (then (call $h_minters)
              (return)))
    ;; Burners (off=213, len=8)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 8))
          (call $memeq (local.get $p) (i32.const 0x0100D5)
                       (i32.const 8)))
        (then (call $h_burners)
              (return)))
    ;; GrantAdminRole (off=101, len=15)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 15))
          (call $memeq (local.get $p) (i32.const 0x010065)
                       (i32.const 15)))
        (then (call $h_grant_admin (i32.add (local.get $p) (i32.const 15)))
              (return)))
    ;; GrantMinterRole (off=116, len=16)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 16))
          (call $memeq (local.get $p) (i32.const 0x010074)
                       (i32.const 16)))
        (then (call $h_grant_minter (i32.add (local.get $p) (i32.const 16)))
              (return)))
    ;; GrantBurnerRole (off=132, len=16)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 16))
          (call $memeq (local.get $p) (i32.const 0x010084)
                       (i32.const 16)))
        (then (call $h_grant_burner (i32.add (local.get $p) (i32.const 16)))
              (return)))
    ;; RevokeAdminRole (off=148, len=16)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 16))
          (call $memeq (local.get $p) (i32.const 0x010094)
                       (i32.const 16)))
        (then (call $h_revoke_admin (i32.add (local.get $p) (i32.const 16)))
              (return)))
    ;; RevokeMinterRole (off=164, len=17)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 17))
          (call $memeq (local.get $p) (i32.const 0x0100A4)
                       (i32.const 17)))
        (then (call $h_revoke_minter (i32.add (local.get $p) (i32.const 17)))
              (return)))
    ;; RevokeBurnerRole (off=181, len=17)
    (if (i32.and
          (i32.ge_u (local.get $rem) (i32.const 17))
          (call $memeq (local.get $p) (i32.const 0x0100B5)
                       (i32.const 17)))
        (then (call $h_revoke_burner (i32.add (local.get $p) (i32.const 17)))
              (return)))

    (call $panic)
  )
)
