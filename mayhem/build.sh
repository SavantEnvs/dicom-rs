#!/usr/bin/env bash
#
# dicom-rs/mayhem/build.sh — build dicom-rs's UPSTREAM cargo-fuzz targets as sanitized libFuzzer
# binaries, replicating OSS-Fuzz's Rust path (base-builder-rust `compile` + `cargo fuzz build -O`).
#
# dicom-rs is a pure-Rust implementation of the DICOM medical-imaging standard, organized as a
# cargo workspace of many crates. Two of those crates ship their OWN in-tree cargo-fuzz crate
# (libfuzzer-sys 0.4, modern layout, maintained by the project) — we build them AS-IS and DO NOT
# touch them, so the integration stays purely additive (everything we add lives under mayhem/):
#   * object/fuzz  -> target `open_file`     (crate dicom-object): parses a DICOM byte stream via
#                     dicom_object::OpenFileOptions::from_reader, strips group-length elements,
#                     re-serializes with write_all and asserts the re-parsed object is equal.
#   * ul/fuzz      -> target `pdu_roundtrip` (crate dicom-ul):     read_pdu over arbitrary bytes
#                     (with arbitrary (maxlen,strict) params), write_pdu, re-read, assert equal.
# These are the two targets the old mayhemheroes fork shipped (open_file, pdu_roundtrip); we keep
# both, each exposed at /mayhem/<target>.
#
# cargo-fuzz drives the build: it provides its own libFuzzer runtime (the produced binary IS a
# libFuzzer target — Mayhem runs it directly via `libfuzzer: true`). ASan is enabled the Rust way
# via RUSTFLAGS `-Zsanitizer=address` (NOT clang's $SANITIZER_FLAGS / CFLAGS — those don't apply to
# rustc), matching OSS-Fuzz's `compile` for FUZZING_LANGUAGE=rust. nightly is required for `-Z`.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (cargo's cc-built deps may
# invoke a C compiler).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Each fuzzed crate ships its own self-contained cargo-fuzz crate (its own [workspace]) under
# <crate>/fuzz. Map fuzz-dir -> single target by discovering its fuzz_targets/*.rs, so the set stays
# in lock-step with upstream (a renamed/added upstream fuzzer is picked up automatically on sync).
FUZZ_DIRS=(object/fuzz ul/fuzz)
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
# Debug-info contract (SPEC §6.2 item 10): the fuzz binaries must carry .debug_info at DWARF < 4.
# -Cdebuginfo=1 alone emits DWARF 5 on the image's nightly, which fails the gate, so thread
# $RUST_DEBUG_FLAGS (overridable by the base image) and pin the DWARF version explicitly.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=3}"
# Three things are required together for the DWARF<4 gate; each alone is insufficient:
#   1. this RUSTFLAGS pin, for our own Rust CUs;
#   2. CFLAGS/CXXFLAGS -gdwarf-3 below, for the libFuzzer C/C++ objects the cc crate builds (clang
#      defaults to DWARF-5);
#   3. objcopy --strip-debug over the prebuilt std rlibs + sanitizer runtime archives in the
#      Dockerfile — -Zdwarf-version cannot rewrite those, and their CUs would otherwise be the
#      binary's FIRST CU, which is precisely what verify-repo.sh reads.
# Also note a stale `target/` masks all of this: a cached build silently keeps the old DWARF-5
# objects, so the Dockerfile/build must not reuse one (a clean build dir is assumed here).
export RUST_DEBUG_FLAGS
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS"
# libfuzzer-sys compiles a bundled libFuzzer via the cc crate (clang -> DWARF-5 by default); force
# DWARF-3 on those C/C++ objects too, so no compilation unit in the linked binary is >= 4.
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

built_any=0
for fdir in "${FUZZ_DIRS[@]}"; do
  [ -d "$SRC/$fdir/fuzz_targets" ] || { echo "ERROR: $fdir/fuzz_targets/ missing" >&2; exit 1; }
  for f in "$SRC/$fdir"/fuzz_targets/*.rs; do
    t="$(basename "${f%.*}")"
    echo "--- building fuzz target: $t (fuzz-dir $fdir) ---"
    # `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's Rust build (catches
    # overflow/debug asserts during fuzzing). Use the image's DEFAULT toolchain (the Dockerfile
    # pins the required nightly); a `+toolchain` override would make rustup try to install another
    # channel into the read-only shared /opt/rust.
    cargo fuzz build --fuzz-dir "$fdir" -O --debug-assertions "$t"
    bin="$SRC/$fdir/target/$TRIPLE/release/$t"
    if [ ! -x "$bin" ]; then
      echo "ERROR: expected fuzz binary not found at $bin" >&2
      exit 1
    fi
    cp "$bin" "/mayhem/$t"
    echo "built /mayhem/$t"
    built_any=1
  done
done
[ "$built_any" -eq 1 ] || { echo "ERROR: no fuzz targets built" >&2; exit 1; }

echo "build.sh complete:"
ls -la /mayhem/open_file /mayhem/pdu_roundtrip 2>&1 || true
