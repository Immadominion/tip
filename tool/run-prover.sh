#!/usr/bin/env bash
#
# Stands up a STRK20 proving service on a fresh machine.
#
# The pool is secured by zk-STARK proofs, and building one is server work: the
# reference deployment budgets about half a minute on 48 cores. That is why
# proving is a remote call rather than something the phone does, and it is also
# why the service is meant to be run by whoever runs the wallet rather than by
# StarkWare. This script is that, start to finish, on a machine you rent.
#
#   ./tool/run-prover.sh --rpc-url https://your-node/rpc/v0_10
#
# What it needs, and none of these are negotiable:
#
#   amd64      the Stwo prover is built for it
#   a v0.10 RPC   the prover re-executes against block state through it, and
#                 v0.8 or v0.9 will not answer the calls it makes
#   48 vCPU / 96 GB   StarkWare's recommendation (c4d-highcpu-48). Less will
#                     work and will be slower; the proving time is roughly
#                     inverse in core count
#
# The build is a multi-stage Rust build on nightly and takes a while the first
# time. It is cached afterwards, so a restart is seconds.
set -euo pipefail

RPC_URL=""
CHAIN_ID="SN_MAIN"
PORT="3000"
TARGET_CPU=""
CONCURRENCY="2"
SEQUENCER_REF="main"
SRC_DIR="${HOME}/sequencer"
IMAGE="tx_prover:latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc-url)     RPC_URL="$2"; shift 2 ;;
    --chain-id)    CHAIN_ID="$2"; shift 2 ;;
    --port)        PORT="$2"; shift 2 ;;
    --target-cpu)  TARGET_CPU="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --ref)         SEQUENCER_REF="$2"; shift 2 ;;
    --src)         SRC_DIR="$2"; shift 2 ;;
    -h|--help)     sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

if [[ -z "$RPC_URL" ]]; then
  echo "--rpc-url is required, and the node behind it must speak v0.10" >&2
  exit 64
fi

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---- the machine ----------------------------------------------------------

arch="$(uname -m)"
if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
  echo "This is $arch. The prover image is amd64 only." >&2
  exit 1
fi

cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
if (( cores < 16 )); then
  echo "Warning: $cores cores. Proving will be slow; 48 is the recommendation." >&2
fi

# ---- the RPC node ---------------------------------------------------------
#
# Checked before anything is built, because it is the requirement most likely
# to be wrong and the most expensive to discover late. Plenty of well known
# endpoints are still on v0.8.

say "Checking the RPC node speaks v0.10"
spec="$(curl -s -m 20 -X POST "$RPC_URL" \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"starknet_specVersion","params":[]}' \
  | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')"

if [[ -z "$spec" ]]; then
  echo "No answer from $RPC_URL" >&2
  exit 1
fi
echo "  reports $spec"
case "$spec" in
  0.10.*) ;;
  *) echo "  the prover needs v0.10 and this is $spec" >&2; exit 1 ;;
esac

# ---- docker ---------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER" || true
  echo "  added $USER to the docker group; if the next step is denied, log out and back in"
fi

# ---- source ---------------------------------------------------------------

if [[ ! -d "$SRC_DIR/.git" ]]; then
  say "Cloning starkware-libs/sequencer at $SEQUENCER_REF"
  git clone --depth 1 --branch "$SEQUENCER_REF" \
    https://github.com/starkware-libs/sequencer.git "$SRC_DIR"
else
  say "Updating $SRC_DIR"
  git -C "$SRC_DIR" fetch --depth 1 origin "$SEQUENCER_REF"
  git -C "$SRC_DIR" checkout FETCH_HEAD
fi

# ---- build ----------------------------------------------------------------
#
# -C target-cpu for the host microarchitecture is a meaningful proving speedup
# and costs nothing, so it is worth detecting rather than leaving generic.

if [[ -z "$TARGET_CPU" ]]; then
  if grep -qi 'EPYC 9' /proc/cpuinfo 2>/dev/null; then
    TARGET_CPU="znver5"
  elif grep -qi 'EPYC' /proc/cpuinfo 2>/dev/null; then
    TARGET_CPU="znver3"
  else
    TARGET_CPU="native"
  fi
fi

say "Building the prover image, target-cpu=$TARGET_CPU"
echo "  first build takes a while; it is cached after that"
docker build \
  -f crates/starknet_transaction_prover/Dockerfile \
  --build-arg "TARGET_CPU=$TARGET_CPU" \
  -t "$IMAGE" \
  "$SRC_DIR"

# ---- run ------------------------------------------------------------------

say "Starting the prover on port $PORT"
docker rm -f strk20-prover >/dev/null 2>&1 || true
docker run -d \
  --name strk20-prover \
  --restart unless-stopped \
  -p "${PORT}:${PORT}" \
  -e "RPC_URL=$RPC_URL" \
  -e "CHAIN_ID=$CHAIN_ID" \
  -e "PROVER_PORT=$PORT" \
  -e "MAX_CONCURRENT_REQUESTS=$CONCURRENCY" \
  -e "PREFETCH_STATE=true" \
  "$IMAGE"

# ---- prove it is up -------------------------------------------------------
#
# Asking rather than assuming, since a container that starts and then dies on a
# bad RPC URL looks identical to a healthy one for the first few seconds.

say "Waiting for it to answer"
for _ in $(seq 1 30); do
  version="$(curl -s -m 5 -X POST "http://localhost:${PORT}" \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"starknet_specVersion","params":[]}' \
    | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')"
  if [[ -n "$version" ]]; then
    printf '\n  prover up, spec %s\n\n' "$version"
    echo "  point the app at it:"
    echo "    --dart-define=STRK20_PROVER=http://<this-host>:${PORT}"
    echo "    --dart-define=STRK20_SELF_HOSTED_PROVER=true"
    echo
    echo "  the second one is required. Without it the app expects an OHTTP"
    echo "  gateway in front of the prover, which a bare one does not have."
    exit 0
  fi
  sleep 2
done

echo "It did not answer in a minute. Logs:" >&2
docker logs --tail 50 strk20-prover >&2
exit 1
