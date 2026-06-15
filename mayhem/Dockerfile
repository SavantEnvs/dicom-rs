# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the identities +
# the build-contract ENV. dicom-rs is a pure-Rust implementation of the DICOM medical-imaging
# standard (a cargo workspace). The fuzzed code is the DICOM file/object parser (dicom-object's
# OpenFileOptions::from_reader -> open_file) and the upper-layer PDU codec (dicom-ul's
# read_pdu/write_pdu -> pdu_roundtrip). The base ships NO Rust toolchain, so this image installs
# rustup (a pinned nightly — cargo-fuzz needs `-Z` flags) + cargo-fuzz as root into a SHARED
# location (/opt/toolchains/rust) usable by the non-root `mayhem` user, then runs build.sh (cargo fuzz build of
# the two upstream fuzz crates) + test.sh (dicom-object + dicom-ul cargo test suites).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t dicom-rs-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default,
# but cargo-fuzz drives Rust instrumentation via RUSTFLAGS (-Zsanitizer=address), NOT $SANITIZER_FLAGS.
# Declared here for parity; build.sh wires ASan into RUSTFLAGS the cargo-fuzz way.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the nightly toolchain (cargo-fuzz needs nightly for `-Z` flags / -Zsanitizer=address).
# Mirrors OSS-Fuzz's base-builder-rust which pins a dated nightly. dicom-rs ships no
# rust-toolchain.toml, so the image default toolchain governs cleanly.
ARG RUST_TOOLCHAIN=nightly-2026-01-15
ARG CARGO_FUZZ_VERSION=0.12.0

# Shared Rust install: CARGO_HOME/RUSTUP_HOME under /opt/toolchains/rust, world-readable, so the non-root
# `mayhem` user can invoke cargo/rustc/cargo-fuzz without owning the toolchain.
ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:$PATH

USER root
RUN set -eux; \
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"; \
    rustup component add rust-src --toolchain "$RUST_TOOLCHAIN"; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    # The non-root `mayhem` user runs `cargo fuzz build`, which WRITES into CARGO_HOME (registry
    # cache, git checkouts). Toolchain dirs stay read-only; the cargo home must be group/other
    # writable so the build can populate the registry. (Build image, not a hardened runtime.)
    chmod -R a+rX /opt/toolchains/rust; \
    mkdir -p "$CARGO_HOME/registry" "$CARGO_HOME/git" && chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git"; \
    # DWARF<4 gate (SPEC 6.2 item 10): the prebuilt std rlibs (DWARF-4) and the clang-built sanitizer
    # runtime archives (DWARF-5) carry debug CUs that -Zdwarf-version cannot rewrite, so the linked
    # fuzz binary would inherit a DWARF>=4 FIRST CU (which is exactly what verify-repo.sh reads).
    # Strip their debug info (rmeta/code preserved) so only our own DWARF-3 CUs remain.
    RLIBDIR="$RUSTUP_HOME/toolchains/${RUST_TOOLCHAIN}-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib"; \
    for a in "$RLIBDIR"/*.rlib "$RLIBDIR"/librustc-nightly_rt.*.a; do [ -e "$a" ] && objcopy --strip-debug "$a" || true; done; \
    rustc --version; cargo --version; cargo fuzz --version
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run dicom-rs's real test suite (dicom-object + dicom-ul) at build time; a failing suite fails the image.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
