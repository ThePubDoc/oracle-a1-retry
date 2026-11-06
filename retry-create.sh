#!/usr/bin/env bash
# Keeps trying to create the Always Free A1 instance until Oracle has capacity.
# Config comes from env vars (GitHub secrets in CI, local.env on the Mac).
#
# Exit codes: 0 = created, 10 = already exists, 20 = time budget used up, 1 = unexpected error
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$DIR/local.env" ] && . "$DIR/local.env"

: "${OCI_COMPARTMENT:?}" "${OCI_AD:?}" "${OCI_SUBNET:?}" "${OCI_IMAGE:?}" "${SSH_PUBKEY_FILE:?}"
NAME=${INSTANCE_NAME:-server-1}
INTERVAL=${INTERVAL:-60}
SIZES=${SIZES:-"2:12 1:6"}   # OCPU:GB, alternated between attempts
BACKOFF_MIN=120; BACKOFF_MAX=600
MAX_RUNTIME=${MAX_RUNTIME:-0}   # seconds; 0 = run forever

export SUPPRESS_LABEL_WARNING=True PYTHONWARNINGS=ignore

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
notify() { command -v osascript >/dev/null && osascript -e "display notification \"$2\" with title \"$1\" sound name \"Glass\"" 2>/dev/null; }

start=$(date +%s)
attempt=0
backoff=$BACKOFF_MIN
while true; do
  if [ "$MAX_RUNTIME" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$MAX_RUNTIME" ]; then
    log "Time budget used up after $attempt attempts — exiting so the next run takes over."
    exit 20
  fi
  attempt=$((attempt + 1))

  # Guard against duplicates: stop if an instance with this name already exists.
  existing=$(oci compute instance list -c "$OCI_COMPARTMENT" --display-name "$NAME" \
    --query 'data[?"lifecycle-state"!=`TERMINATED`] | length(@)' --raw-output 2>/dev/null || echo 0)
  if [ "${existing:-0}" != "0" ]; then
    log "Instance '$NAME' already exists — stopping."
    exit 10
  fi

  # Alternate sizes between attempts (2 OCPU/12 GB, then 1/6, ...) so we send a
  # single launch request per interval — Oracle's launch rate limit is tight.
  set -- $SIZES
  idx=$(( (attempt - 1) % $# + 1 ))
  size=${!idx}
  ocpus=${size%%:*}; mem=${size##*:}
  # --no-retry: the CLI otherwise silently re-sends each failed launch up to 7
  # times, which is what was burning through Oracle's rate limit.
  out=$(oci compute instance launch --no-retry \
    --compartment-id "$OCI_COMPARTMENT" \
    --availability-domain "$OCI_AD" \
    --display-name "$NAME" \
    --shape VM.Standard.A1.Flex \
    --shape-config "{\"ocpus\":$ocpus,\"memoryInGBs\":$mem}" \
    --image-id "$OCI_IMAGE" \
    --boot-volume-size-in-gbs 100 \
    --subnet-id "$OCI_SUBNET" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "$SSH_PUBKEY_FILE" \
    --user-data-file "$DIR/cloud-init.yaml" \
    --wait-for-state RUNNING --max-wait-seconds 600 2>&1)
  rc=$?

  if [ $rc -eq 0 ]; then
    result=success
  elif echo "$out" | grep -qiE "out of (host )?capacity"; then
    result=capacity
  elif echo "$out" | grep -qiE "TooManyRequests|\"status\": 429"; then
    result=ratelimited
  else
    result=error
  fi

  case $result in
    success)
      id=$(echo "$out" | sed -n 's/.*"id": "\(ocid1.instance[^"]*\)".*/\1/p' | head -1)
      ip=$(oci compute instance list-vnics --instance-id "$id" --query 'data[0]."public-ip"' --raw-output 2>/dev/null)
      [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$ip"
      log "SUCCESS after $attempt attempts with ${ocpus} OCPU / ${mem} GB. Public IP: $ip"
      echo "$ip" > "$DIR/public-ip.txt"
      notify "Oracle server created!" "${ocpus} OCPU / ${mem} GB — Public IP: $ip"
      exit 0 ;;
    capacity)
      backoff=$BACKOFF_MIN
      log "Attempt $attempt: out of capacity (${ocpus}/${mem}), retrying in ${INTERVAL}s"
      sleep "$INTERVAL" ;;
    ratelimited)
      log "Attempt $attempt: rate limited (at ${ocpus}/${mem}), backing off ${backoff}s"
      sleep "$backoff"
      backoff=$(( backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2 )) ;;
    *)
      # Without CLI retries, a transient error while waiting for RUNNING could hide a
      # launch that actually succeeded — let the duplicate guard decide on the next loop.
      if [ "$(oci compute instance list -c "$OCI_COMPARTMENT" --display-name "$NAME" \
            --query 'data[?"lifecycle-state"!=`TERMINATED`] | length(@)' --raw-output 2>/dev/null)" != "0" ]; then
        log "Attempt $attempt: error after launch, but the instance exists — treating as created."
        exit 0
      fi
      log "Attempt $attempt: unexpected error — stopping:"
      echo "$out"
      notify "Oracle retry" "Retry script stopped on an error — check the log"
      exit 1 ;;
  esac
done
