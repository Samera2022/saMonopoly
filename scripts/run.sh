#!/usr/bin/env bash
set -euo pipefail

# Use g++ if clang++ is not available (Flutter Linux desktop build requirement)
if ! command -v clang++ &>/dev/null && command -v g++ &>/dev/null; then
  export CXX=g++
fi

# ─── saMonopoly Build & Run Script ───────────────────────────────────────────
# Usage:
#   ./scripts/run.sh            # Build Rust + run Flutter (release)
#   ./scripts/run.sh --debug    # Build Rust (debug) + run Flutter (debug)
#   ./scripts/run.sh --no-rust  # Skip Rust build, run Flutter directly
#   ./scripts/run.sh --help     # Show this message
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FLUTTER_DIR="$PROJECT_DIR/flutter"

echo "========================================"
echo " saMonopoly - Build & Run"
echo "========================================"

# Parse arguments
RUST_MODE="release"
FLUTTER_MODE="release"
SKIP_RUST=false

for arg in "$@"; do
  case "$arg" in
    --debug)
      RUST_MODE=""
      FLUTTER_MODE=""
      ;;
    --no-rust)
      SKIP_RUST=true
      ;;
    --help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      echo "Usage: $0 [--debug] [--no-rust] [--help]"
      exit 1
      ;;
  esac
done

# ── Step 1: Build Rust shared library ────────────────────────────────────────

if [ "$SKIP_RUST" = false ]; then
  echo ""
  echo "[1/2] Building Rust engine (${RUST_MODE:-debug})..."

  BUILD_FLAGS="--release"
  if [ -z "$RUST_MODE" ]; then
    BUILD_FLAGS=""
  fi

  cd "$PROJECT_DIR"
  cargo build $BUILD_FLAGS -p sa-monopoly-application

  echo "  ✓ Rust engine built successfully"
else
  echo ""
  echo "[1/2] Skipping Rust build (--no-rust)"
fi

# ── Step 2: Run Flutter ──────────────────────────────────────────────────────

echo ""
echo "[2/2] Starting Flutter (${FLUTTER_MODE:-debug})..."

RUN_FLAGS="--release"
if [ -z "$FLUTTER_MODE" ]; then
  RUN_FLAGS=""
fi

cd "$FLUTTER_DIR"
flutter run $RUN_FLAGS

echo ""
echo "Done."
