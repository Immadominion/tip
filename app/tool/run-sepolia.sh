#!/usr/bin/env bash
# Runs the app against the STRK20 Sepolia environment.
#
# Reads the endpoints from ../.strk20-env.json, which is gitignored because
# that environment was shared in confidence. This script is committed; the
# values it reads are not.
#
#   ./tool/run-sepolia.sh                 # first connected device
#   ./tool/run-sepolia.sh -d <device-id>  # a specific one
set -euo pipefail

ENV_FILE="$(dirname "$0")/../../.strk20-env.json"
if [ ! -f "$ENV_FILE" ]; then
  echo "No .strk20-env.json at $ENV_FILE" >&2
  exit 1
fi

read -r POOL PROVER DISCOVERY RPC <<<"$(python3 -c "
import json,sys
e=json.load(open('$ENV_FILE'))
print(e['poolAddress'], e['provingUrl'], e['discoveryUrl'], e['rpcUrl'])
")"

# Pinned so the key config is not fetched over the same TLS the encryption
# exists to be independent of. Refresh it if the service rotates keys:
#   curl -sS "$DISCOVERY/ohttp-keys" | base64
OHTTP_KEY="${STRK20_OHTTP_KEY:-$(curl -sS --max-time 20 "$DISCOVERY/ohttp-keys" | base64)}"

exec flutter run "$@" \
  --dart-define=TIP_CHAIN=sepolia \
  --dart-define=STRK20_POOL="$POOL" \
  --dart-define=STRK20_PROVER="$PROVER" \
  --dart-define=STRK20_DISCOVERY="$DISCOVERY" \
  --dart-define=STRK20_RPC="$RPC" \
  --dart-define=STRK20_OHTTP_KEY="$OHTTP_KEY"
