#!/usr/bin/env bash
# Claude Code CLI on SUBSCRIPTION auth, both arms, LCB-100 (pinned ids), 5 passes.
#
# Fills the one gap in the paper's table: no Anthropic model has a manager arm on the v2
# scaffold. This runs {single, manager} through the SAME run_bench.py, the SAME pinned 100
# ids, the SAME v2 scaffold settings and the SAME grader as the arms in S2.1 -- so the two
# new numbers drop straight into that table's Single / Manager columns.
#
# NO API KEY. Routing goes MULTIAGENT_MODEL="claude:<alias>" -> orchestrator.claude_cli_chat()
# -> `claude -p --tools "" --model <alias>`, which uses the machine's subscription auth.
# ANTHROPIC_API_KEY is UNSET below on purpose: if it is present the CLI bills the API
# instead of the subscription, which is the opposite of what this script is for.
#
# ---------------------------------------------------------------------------------------
# THREE WAYS THIS ARM IS NOT LIKE THE OTHERS. All forced by the CLI, none chosen here.
# Record them next to any number this produces.
#
#  1. OUTPUT CAP IS NOT CONTROLLABLE. `claude -p` exposes no max_tokens, so
#     ESCALATION_CLOUD_MAX_TOKENS does NOT apply on this path (see claude_cli_chat's
#     docstring). Every other arm in S2.1 is pinned at 128k. This one is whatever the CLI
#     defaults to. It is the single largest comparability gap -- do not print these numbers
#     in a "128k cap" column without a footnote.
#
#  2. THINKING IS NEITHER SWITCHABLE NOR READABLE. No reasoning knob over this transport.
#     The CLI returns thinking blocks with an EMPTY text field and only a signature, so the
#     transcript can record THAT the model thought (meta.thinking_blocks) but never WHAT.
#     Same class of caveat as the Fable 5 and Opus-5 arms (which record a summary), and
#     weaker still -- those at least get a summary.
#
#  3. TEMPERATURE DOES NOT APPLY. Other arms run at 0.2; the CLI takes no temperature and
#     claude_cli_chat accepts the argument for signature parity only.
#
# What IS held identical to S2.1: the 100 problems and their order, the prompts, the v2
# scaffold (MAX_ITERS=10, MAX_TASKS=12), code extraction, and the corrected evaluator.
# ---------------------------------------------------------------------------------------
#
# QUOTA. A manager pass is many CLI calls per problem, so a full 5x2 run is on the order of
# thousands of invocations against a subscription. Start with the smoke test:
#
#     N=5 PASSES=1 ARMS=single ./run_claudecode_sub_5pass.sh
#
# then scale up. PAR is deliberately low; raising it just converts quota into 429s.
set -u

# --- where the repo is. Override REPO if this script is not run from inside it. ----------
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
cd "$REPO"

# run_bench.py / regrade.py both do sys.path.insert(0, <parent-of-escalation>/LiveCodeBench),
# but this bundle ships the harness at codebase/livecodebench (lowercase, one level up).
# Without this symlink every one of them dies on `import lcb_runner`. Idempotent.
[ -e LiveCodeBench ] || ln -s ../livecodebench LiveCodeBench
python3 -c "import sys; sys.path.insert(0,'LiveCodeBench'); import lcb_runner" 2>/dev/null \
  || { echo "FATAL: cannot import lcb_runner. Expected the harness at $REPO/LiveCodeBench"; exit 1; }
# The harness pulls the dataset and grades with these. Missing them fails the run AFTER the
# model calls on some paths, so check up front.
python3 -c "import datasets, numpy" 2>/dev/null \
  || { echo "FATAL: missing python deps. Install the harness first, e.g."
       echo "       pip install datasets numpy   (or: uv run --with datasets --with numpy ...)"; exit 1; }

export LCB_RELEASE=${LCB_RELEASE:-release_v6}
export MULTIAGENT_MAX_ITERS=${MULTIAGENT_MAX_ITERS:-10}   # v2 default; matches S2.1
export MULTIAGENT_MAX_TASKS=${MULTIAGENT_MAX_TASKS:-12}   # v2 default; matches S2.1

CC_MODEL=${CC_MODEL:-opus}          # any alias or id `claude --model` accepts
N=${N:-100}                         # problems, taken from the head of the pinned list
PASSES=${PASSES:-5}
ARMS=${ARMS:-"single multiagent"}
PAR=${PAR:-4}                       # keep low: subscription quota, not throughput, is the limit
export ESCALATION_CLAUDE_ATTEMPTS=${ESCALATION_CLAUDE_ATTEMPTS:-6}
export ESCALATION_CLAUDE_TIMEOUT=${ESCALATION_CLAUDE_TIMEOUT:-1800}

IDS=escalation/lcb100_hardest_v6.json
RUN=escalation/runs/claudecode-sub-5pass
OUT="$RUN/results"; WS="$REPO/$RUN/ws"
mkdir -p "$OUT" "$WS"

# --- subscription auth, not API billing --------------------------------------------------
# A stray key in the environment (or in escalation/.env) silently switches the CLI to API
# billing. Drop it for this process only; the outer shell is untouched.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "note: ANTHROPIC_API_KEY was set; unsetting it so the CLI uses subscription auth."
  unset ANTHROPIC_API_KEY
fi
unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL 2>/dev/null || true

command -v claude >/dev/null || { echo "FATAL: \`claude\` not on PATH."; exit 1; }
echo "claude: $(claude --version 2>&1 | head -1)"

# --- preflight: prove the CLI answers on this auth BEFORE spending a pass -----------------
# Also resolves and records which model the alias actually served.
RESOLVED=$(printf 'Reply with just: ok' \
  | claude -p --output-format stream-json --verbose --no-session-persistence \
      --tools "" --model "$CC_MODEL" 2>/dev/null \
  | python3 -c '
import json, sys
model, text, err = None, "", None
for line in sys.stdin:
    try: ev = json.loads(line)
    except json.JSONDecodeError: continue
    if ev.get("type") == "assistant":
        model = (ev.get("message") or {}).get("model") or model
    if ev.get("type") == "result":
        text, err = ev.get("result") or "", ev.get("is_error")
if not text.strip() or err:
    print("PROBE_FAILED", file=sys.stderr); sys.exit(1)
print(model or "unknown")') || {
  echo "FATAL: probe failed. Is the CLI logged in? Try: claude -p --tools \"\" --model $CC_MODEL"
  exit 1; }
echo "  probe OK: alias=$CC_MODEL resolved=$RESOLVED"

{ echo "sha=$(git rev-parse HEAD 2>/dev/null || echo n/a)"
  git status --porcelain -- escalation/ 2>/dev/null | sed 's/^/dirty: /'
  echo "model=claude:$CC_MODEL resolved=$RESOLVED auth=subscription(no API key)"
  echo "n=$N passes=$PASSES arms='$ARMS' par=$PAR release=$LCB_RELEASE ids=$IDS"
  echo "max_iters=$MULTIAGENT_MAX_ITERS max_tasks=$MULTIAGENT_MAX_TASKS"
  echo "cap=UNCONTROLLED (CLI exposes no max_tokens) thinking=UNCONTROLLED temperature=n/a"
} > "$OUT/run_config.txt"
cat "$OUT/run_config.txt"

# --- verify a finished pass: all ids present AND nothing silently dropped ----------------
# The id check alone is not enough. run_bench.py KEEPS infra records in `records` but
# excludes them from pass@1, so a quota-throttled pass reports a rate over fewer than N
# problems while every id is still present -- a silently wrong denominator. n_infra is the
# field that catches it.
check() {
  N="$N" python3 -c '
import json, os, sys
try:
    d = json.load(open(sys.argv[1])).get("lcb")
except Exception as e:
    print(f"  !! unreadable output ({e.__class__.__name__}) -- pass did not finish"); sys.exit(1)
if not d or not d.get("records"):
    print("  !! no lcb results in output -- the pass crashed before grading"); sys.exit(1)
n = int(os.environ["N"])
got = [r["question_id"] for r in d["records"]]
want = json.load(open("escalation/lcb100_hardest_v6.json"))[:n]
infra, graded, rate = d.get("n_infra") or 0, d.get("n_graded"), d["pass@1"]
ok = True
if got != want:
    missing = sorted(set(want) - set(got))[:5]
    print(f"  !! ID MISMATCH: {len(got)}/{n} ids, missing={missing}"); ok = False
if infra:
    print(f"  !! {infra} INFRA-EXCLUDED of {len(got)}: pass@1 is over {graded} problems, "
          f"NOT {n}. Quota throttling? Delete this file and re-run the pass."); ok = False
if ok:
    print(f"  OK: {len(got)}/{n} ids, 0 infra, pass@1={rate:.1f}")
sys.exit(0 if ok else 1)' "$1"
}

FAILED=0

# --- run ---------------------------------------------------------------------------------
for arm in $ARMS; do
  for p in $(seq 1 "$PASSES"); do
    out="$OUT/cc_${arm}_p${p}.json"
    # A crashed pass still leaves a stub file ({"engine":..,"model":..} and no "lcb"),
    # which would otherwise be skipped forever as "done". Only skip a pass that verifies.
    if [ -f "$out" ]; then
      if check "$out" >/dev/null 2>&1; then echo "[skip done] cc_${arm}_p${p}"; continue; fi
      echo "[redo] cc_${arm}_p${p}: previous output incomplete, re-running"; rm -f "$out"
    fi
    echo "[$(date +%H:%M:%S)] start cc_${arm}_p${p}  (model=claude:$CC_MODEL)"
    MULTIAGENT_MODEL="claude:$CC_MODEL" \
    MULTIAGENT_WS="$WS/cc_${arm}_p${p}" \
      python escalation/run_bench.py \
        --engine "$arm" --only lcb --lcb "$N" --ids-file "$IDS" \
        --parallel "$PAR" --out "$out" \
        > "$RUN/cc_${arm}_p${p}.log" 2>&1
    printf 'cc_%s_p%s: ' "$arm" "$p"
    check "$out" || { FAILED=$((FAILED + 1)); echo "     (see $RUN/cc_${arm}_p${p}.log)"; }
  done
done

# --- regrade on the corrected evaluator: this is what the paper's tables read -------------
python escalation/regrade.py "$OUT"/cc_*_p[0-9].json

echo
if [ "$FAILED" -gt 0 ]; then
  echo "[$(date +%H:%M:%S)] $FAILED pass(es) did NOT verify -- the numbers below are incomplete."
  echo "Fix the cause, then re-run this script: verified passes are skipped, broken ones redone."
else
  echo "[$(date +%H:%M:%S)] DONE, all passes verified. Scores (regraded):"
fi
python3 -c '
import glob, json, re, statistics as st
g = {}
for f in sorted(glob.glob("escalation/runs/claudecode-sub-5pass/results/cc_*.regraded.json")):
    d = json.load(open(f))["lcb"]
    g.setdefault(re.sub(r"_p\d+", "", f.split("/")[-1])[:-14], []).append(d["pass@1"])
for k, v in sorted(g.items()):
    sd = f" ± {st.stdev(v):.1f}" if len(v) > 1 else ""
    print(f"  {k:16s} n={len(v)}  {st.mean(v):5.1f}{sd}   passes={[round(x) for x in v]}")'

exit $(( FAILED > 0 ))
