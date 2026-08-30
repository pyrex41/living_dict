#!/usr/bin/env bash
# Warm-across-Terminal-Bench driver for the BEAM Living Dictionary shim.
#
# Harbor fixes --ae env per JOB and runs trials concurrently, so warm
# carry-over across tasks means ONE harbor job per task, run sequentially,
# with the accumulated dictionary passed to each job as a base64'd tarball
# via the shim's dict_seed_b64 kwarg (inside the command string, not --ae).
#
# Usage:
#   bench/tb_warm.sh [--out DIR] [--dry-run] [--multiplier M] [--max-episodes N]
#
# Requires XAI_API_KEY in the environment (except with --dry-run).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# macOS otherwise writes AppleDouble `._*.fs` next to copied word files.
# Those match `*.fs`, get packed into the seed, and the in-container critic
# rejects every episode with `invalid encoding` (byte 0xA3 / ATTR fork).
export COPYFILE_DISABLE=1

# Family-ordered: git family, log/regex family, certs/logging, db family,
# then the singletons.
TASKS=(
  fix-git
  git-multibranch
  git-leak-recovery
  sanitize-git-repo
  regex-log
  log-summary-date-ranges
  openssl-selfsigned-cert
  nginx-request-logging
  sqlite-db-truncate
  db-wal-recovery
  extract-elf
  overfull-hbox
  schemelike-metacircular-eval
  fix-code-vulnerability
  filter-js-from-html
)

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/bench/results/beam/tbwarm-$STAMP"
DRY_RUN=0
MULTIPLIER="2.0"
MAX_EPISODES="8"
SEED_MAX_BYTES=120000  # under Linux MAX_ARG_STRLEN (131072) per review  # 200KB hard cap; argv ceiling is ~256KB

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --multiplier) MULTIPLIER="$2"; shift 2 ;;
    --max-episodes) MAX_EPISODES="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "tb_warm.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$DRY_RUN" -eq 0 ] && [ -z "${XAI_API_KEY:-}" ]; then
  echo "tb_warm.sh: XAI_API_KEY is not set; refusing to start (use --dry-run to preview)" >&2
  exit 1
fi

mkdir -p "$OUT"
echo "tb_warm: out=$OUT multiplier=$MULTIPLIER max_episodes=$MAX_EPISODES tasks=${#TASKS[@]}"

# Merge the dictionary words from ALL previous jobs' trial dirs into $2/words.
# Jobs are visited in order 01..(N-1) so later jobs win on name clash.
merge_accumulator() {
  # $1 = index of the current task (1-based); $2 = accumulator dir
  local upto="$1" acc="$2" j jj f
  mkdir -p "$acc/words"
  j=1
  while [ "$j" -lt "$upto" ]; do
    jj="$(printf '%02d' "$j")"
    for f in "$OUT/beam-tbwarm-$jj"/*/agent/dict/words/*.fs \
             "$OUT/beam-tbwarm-$jj"/*/agent/run/dictionary/words/*.fs; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      # Skip AppleDouble / hidden files; word names match Dictionary.@safe_name.
      case "$base" in
        .*) continue ;;
      esac
      case "$base" in
        [A-Z]*.fs) ;;
        *) continue ;;
      esac
      if ! printf '%s' "$base" | grep -Eq '^[A-Z][A-Z0-9-]{0,62}\.fs$'; then
        continue
      fi
      cp -f "$f" "$acc/words/"
    done
    j=$((j + 1))
  done
  return 0
}

# Pull the reward out of a job's result.json without depending on python.
job_reward() {
  # $1 = job dir
  local rj="$1/result.json"
  if [ -f "$rj" ]; then
    { grep -o '"reward"[[:space:]]*:[[:space:]]*[0-9.eE+-]*' "$rj" || true; } \
      | head -n 1 | sed 's/.*:[[:space:]]*//'
  else
    echo "no-result"
  fi
}

FAILED_TASKS=""
N=0
for TASK in "${TASKS[@]}"; do
  N=$((N + 1))
  NN="$(printf '%02d' "$N")"
  JOB="beam-tbwarm-$NN"

  ACC="$(mktemp -d "${TMPDIR:-/tmp}/tbwarm-acc.XXXXXX")"
  merge_accumulator "$N" "$ACC"

  SEED=""
  WORD_COUNT=0
  if [ -n "$(ls -A "$ACC/words" 2>/dev/null)" ]; then
    WORD_COUNT="$(find "$ACC/words" -maxdepth 1 -type f -name '*.fs' ! -name '.*' | wc -l | tr -d ' ')"
    # gzip outside tar: bsdtar pads compressed stdout to 10240B records,
    # which both bloats the seed and leaves trailing garbage for the
    # container's gunzip; tar|gzip keeps the padding inside the stream.
    SEED="$(tar -cf - -C "$ACC" words | gzip -cn | base64 | tr -d '\n')"
  fi
  SEED_BYTES=${#SEED}
  if [ "$SEED_BYTES" -gt "$SEED_MAX_BYTES" ]; then
    echo "tb_warm: ABORT at task $NN ($TASK): seed ${SEED_BYTES}B > ${SEED_MAX_BYTES}B cap" >&2
    rm -rf "$ACC"
    exit 1
  fi

  CMD=(harbor run -t "terminal-bench/$TASK"
       -a bench.harbor_ld_beam:LivingDictBeam -m xai/grok-4.6
       --ak "max_episodes=$MAX_EPISODES")
  if [ -n "$SEED" ]; then
    CMD+=(--ak "dict_seed_b64=$SEED")
  fi
  CMD+=(--agent-timeout-multiplier "$MULTIPLIER"
        --ae "XAI_API_KEY=\$XAI_API_KEY"
        -n 1 -o "$OUT" --job-name "$JOB")

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY [%s/%02d] %s: seed=%dB words=%d\n' \
      "$NN" "${#TASKS[@]}" "$TASK" "$SEED_BYTES" "$WORD_COUNT"
    printf '  PYTHONPATH=%s' "$REPO"
    for a in "${CMD[@]}"; do
      case "$a" in
        dict_seed_b64=*) printf ' %q' "dict_seed_b64=<${SEED_BYTES}B>" ;;
        *) printf ' %s' "$a" ;;
      esac
    done
    printf '\n'
    rm -rf "$ACC"
    continue
  fi

  echo "tb_warm: [$NN/${#TASKS[@]}] $TASK (seed=${SEED_BYTES}B, words=$WORD_COUNT)"
  # OAuth access tokens outlive neither this chain nor a long job: refresh
  # per task via the planner's own flow (persists the rotated record to
  # ~/.grok/auth.json). Falls back to the env key on failure.
  # env -u: credentials() short-circuits on ANY non-empty XAI_API_KEY, so
  # the helper must not inherit ours or "refresh" returns it verbatim.
  FRESH_KEY="$(cd "$REPO/beam" && env -u XAI_API_KEY mix run -e '
    case LdHost.Planner.credentials() do
      {:ok, key} -> IO.puts(key)
      {:error, reason} -> IO.puts(:stderr, reason); System.halt(1)
    end' 2>/dev/null | tail -1)"
  # Sanity: OAuth JWTs are hundreds of chars; anything short is garbage.
  if [ "${#FRESH_KEY}" -lt 100 ]; then
    echo "tb_warm: [$NN] token refresh failed (len=${#FRESH_KEY}); falling back to env key" >&2
    FRESH_KEY="$XAI_API_KEY"
  fi
  if [ "${#FRESH_KEY}" -lt 100 ]; then
    echo "tb_warm: ABORT: no usable API key" >&2
    exit 1
  fi
  # Real run: pass the key by value (never echoed; set -x stays off).
  RCMD=()
  for a in "${CMD[@]}"; do
    case "$a" in
      "XAI_API_KEY=\$XAI_API_KEY") RCMD+=("XAI_API_KEY=$FRESH_KEY") ;;
      *) RCMD+=("$a") ;;
    esac
  done
  if PYTHONPATH="$REPO" "${RCMD[@]}" > "$OUT/$JOB.harbor.log" 2>&1; then
    STATUS=ok
  else
    STATUS="failed(rc=$?)"
    FAILED_TASKS="$FAILED_TASKS $TASK"
  fi
  echo "tb_warm: [$NN/${#TASKS[@]}] task=$TASK status=$STATUS reward=$(job_reward "$OUT/$JOB")"
  rm -rf "$ACC"
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "tb_warm: dry run complete (${#TASKS[@]} commands, nothing executed)"
elif [ -n "$FAILED_TASKS" ]; then
  echo "tb_warm: chain complete; failed jobs:$FAILED_TASKS" >&2
else
  echo "tb_warm: chain complete; all ${#TASKS[@]} jobs ran"
fi
