#!/usr/bin/env bash
# A/B two AGENT LAYERS over the same models, same 100 problems, same grader.
#
#   A  ccagent     Claude Code's own loop  (`claude -p`, tools, multi-round, self-directed)
#   B  multiagent  the paper's v2 manager/worker scaffold over a ledger workspace
#   C  single      one call, no tools -- the paper's baseline, for anchoring A and B
#
# The point of the pairing: A and B are handed the SAME problem text, the SAME task framing
# (spec["solver_system"]), the SAME 100 pinned ids in the same order, and are scored by the
# SAME evaluator. The only thing that differs is who organises the work. See ccagent.py.
#
# MODELS. Anything you can put behind BOTH layers. Out of the box:
#   opus, fable   subscription auth via `claude -p` -- NO API KEY (unset below on purpose)
#   qwen          a local/OpenAI-compatible model, reached by pointing the CLI at a proxy
#                 (ANTHROPIC_BASE_URL) for layer A and by the usual MULTIAGENT_MODEL prefix
#                 for layers B/C. Edit the qwen row before using it.
#
# ---------------------------------------------------------------------------------------
# READ BEFORE TRUSTING ANY NUMBER THIS PRODUCES
#
#  1. RUN AS A NORMAL USER, NOT ROOT. Layer A needs --permission-mode bypassPermissions so
#     the agent can execute what it writes. The CLI REFUSES that mode under root/sudo.
#     Do not work around it with acceptEdits: that mode allows Write/Edit but DENIES Bash,
#     so the agent cannot run its own tests and layer A silently stops being an agent arm.
#     Measured, not guessed: acceptEdits under root produced solution.py with 3 denied Bash
#     calls. The script refuses such a pass -- see the permission_denied check below.
#
#  2. NO OUTPUT CAP AND NO REASONING SWITCH ON LAYER A. `claude -p` exposes neither, so
#     ESCALATION_CLOUD_MAX_TOKENS does not apply. Every arm in the paper's S2.1 is pinned at
#     128k; layer A is not. Footnote it.
#
#  3. LAYER A CAN RUN CODE, THE SINGLE-CALL ARM CANNOT. A vs B is a fair pairing (the v2
#     scaffold also verifies against the public examples). A vs C is not -- C is there only
#     as the anchor that ties both layers back to the published table.
# ---------------------------------------------------------------------------------------
#
# START HERE, then scale:
#     N=3 PASSES=1 MODELS=opus LAYERS="single ccagent" ./run_agentloop_ab.sh
set -u

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
cd "$REPO"

# run_bench.py / regrade.py do sys.path.insert(0, <parent-of-escalation>/LiveCodeBench), but
# this bundle ships the harness at codebase/livecodebench. Without this every one of them
# dies on `import lcb_runner`. Idempotent.
[ -e LiveCodeBench ] || ln -s ../livecodebench LiveCodeBench
python3 -c "import sys; sys.path.insert(0,'LiveCodeBench'); import lcb_runner" 2>/dev/null \
  || { echo "FATAL: cannot import lcb_runner (expected at $REPO/LiveCodeBench)"; exit 1; }
python3 -c "import datasets, numpy" 2>/dev/null \
  || { echo "FATAL: missing deps. pip install datasets numpy"; exit 1; }

export LCB_RELEASE=${LCB_RELEASE:-release_v6}
export MULTIAGENT_MAX_ITERS=${MULTIAGENT_MAX_ITERS:-10}   # v2 defaults; match the paper's S2.1
export MULTIAGENT_MAX_TASKS=${MULTIAGENT_MAX_TASKS:-12}
export CCAGENT_WALL_SECONDS=${CCAGENT_WALL_SECONDS:-1800}
export CCAGENT_PERMISSION_MODE=${CCAGENT_PERMISSION_MODE:-bypassPermissions}

MODELS=${MODELS:-"opus fable"}          # add qwen once its row below is filled in
LAYERS=${LAYERS:-"single multiagent ccagent"}
N=${N:-100}
PASSES=${PASSES:-5}
PAR=${PAR:-4}                           # subscription quota, not throughput, is the limit
export ESCALATION_CLAUDE_ATTEMPTS=${ESCALATION_CLAUDE_ATTEMPTS:-6}

IDS=escalation/lcb100_hardest_v6.json
RUN=escalation/runs/agentloop-ab
OUT="$RUN/results"; WS="$REPO/$RUN/ws"
mkdir -p "$OUT" "$WS"

# --- subscription auth, not API billing ---------------------------------------------------
# A key in the environment silently switches the CLI to API billing on BOTH layers.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "note: unsetting ANTHROPIC_API_KEY so the CLI uses subscription auth."
  unset ANTHROPIC_API_KEY
fi

command -v claude >/dev/null || { echo "FATAL: \`claude\` not on PATH."; exit 1; }
if [ "$CCAGENT_PERMISSION_MODE" = "bypassPermissions" ] && [ "$(id -u)" = "0" ]; then
  case " $LAYERS " in *" ccagent "*)
    echo "FATAL: layer ccagent needs bypassPermissions, which the CLI refuses under root."
    echo "       Run as a normal user. acceptEdits is NOT a workaround: it denies Bash."
    exit 1;; esac
fi

# --- per-model routing --------------------------------------------------------------------
# Sets MA_MODEL (layers single/multiagent) and the CC_* env (layer ccagent) for one model.
route() {
  case "$1" in
    opus)  MA_MODEL="claude:opus";  CC_MODEL="opus";  CC_ENV=() ;;
    fable) MA_MODEL="claude:fable"; CC_MODEL="fable"; CC_ENV=() ;;
    qwen)
      # EDIT ME. Layer A reaches a non-Anthropic model only through an Anthropic-compatible
      # proxy (this is exactly what codebase/livecodebench/.../claude_code_runner.py does
      # with litellm on :8216). Layers B/C use the orchestrator's own prefixes instead.
      MA_MODEL="${QWEN_MA_MODEL:-groq:qwen/qwen3.6-27b}"
      CC_MODEL="${QWEN_SERVED_NAME:-qwen3.6-27b-vllm}"
      CC_ENV=(ANTHROPIC_BASE_URL="${QWEN_PROXY:-http://localhost:8216/}"
              ANTHROPIC_AUTH_TOKEN="${QWEN_TOKEN:-x}"
              ANTHROPIC_MODEL="$CC_MODEL"
              ANTHROPIC_SMALL_FAST_MODEL="$CC_MODEL"
              CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1) ;;
    *) echo "FATAL: unknown model '$1'. Add a row to route()."; exit 1 ;;
  esac
}

# --- verify a finished pass ---------------------------------------------------------------
# Three ways a pass can be wrong while still LOOKING complete, all checked here:
#   ids      -- wrong or short problem set
#   n_infra  -- run_bench.py KEEPS infra rows in `records` but drops them from the pass@1
#               denominator, so a throttled pass reports a rate over fewer problems while
#               every id is still present. A silently wrong denominator.
#   denials  -- ccagent only: the agent was blocked from a tool, so the row is not that
#               agent layer's output at all.
check() {
  N="$N" python3 -c '
import json, os, sys
try:
    d = json.load(open(sys.argv[1])).get("lcb")
except Exception as e:
    print(f"  !! unreadable output ({e.__class__.__name__}) -- pass did not finish"); sys.exit(1)
if not d or not d.get("records"):
    print("  !! no lcb results -- the pass crashed before grading"); sys.exit(1)
n = int(os.environ["N"])
recs = d["records"]
got = [r["question_id"] for r in recs]
want = json.load(open("escalation/lcb100_hardest_v6.json"))[:n]
infra, graded, rate = d.get("n_infra") or 0, d.get("n_graded"), d["pass@1"]
denied = [r for r in recs if r.get("permission_denied")]
ok = True
if got != want:
    print(f"  !! ID MISMATCH: {len(got)}/{n}, missing={sorted(set(want)-set(got))[:5]}"); ok = False
if infra:
    print(f"  !! {infra} INFRA-EXCLUDED of {len(got)}: pass@1 is over {graded}, NOT {n}. "
          f"Quota throttling? Delete the file and re-run this pass."); ok = False
if denied:
    tools = sorted({t for r in denied for t in (r.get("denied_tools") or ["?"])})
    print(f"  !! {len(denied)}/{len(got)} problems had DENIED tool calls ({tools}). The "
          f"agent was blocked from acting -- this is not an agent-loop result. Check "
          f"CCAGENT_PERMISSION_MODE and that you are not root."); ok = False
if ok:
    cost = sum(r.get("total_cost_usd") or 0 for r in recs)
    tail = f", ${cost:.2f}" if cost else ""
    print(f"  OK: {len(got)}/{n} ids, 0 infra, 0 denials, pass@1={rate:.1f}{tail}")
sys.exit(0 if ok else 1)' "$1"
}

{ echo "sha=$(git rev-parse HEAD 2>/dev/null || echo n/a)"
  echo "models='$MODELS' layers='$LAYERS' n=$N passes=$PASSES par=$PAR"
  echo "auth=subscription(no API key) release=$LCB_RELEASE ids=$IDS"
  echo "max_iters=$MULTIAGENT_MAX_ITERS max_tasks=$MULTIAGENT_MAX_TASKS"
  echo "ccagent: permission_mode=$CCAGENT_PERMISSION_MODE wall=${CCAGENT_WALL_SECONDS}s"
  echo "caps: single/multiagent=uncontrolled(claude CLI) ccagent=uncontrolled(claude CLI)"
} > "$OUT/run_config.txt"
cat "$OUT/run_config.txt"

FAILED=0
for m in $MODELS; do
  route "$m"
  for layer in $LAYERS; do
    for p in $(seq 1 "$PASSES"); do
      tag="${m}_${layer}_p${p}"; out="$OUT/${tag}.json"
      if [ -f "$out" ]; then
        if check "$out" >/dev/null 2>&1; then echo "[skip done] $tag"; continue; fi
        echo "[redo] $tag: previous output did not verify"; rm -f "$out"
      fi
      echo "[$(date +%H:%M:%S)] start $tag"
      if [ "$layer" = "ccagent" ]; then
        env "${CC_ENV[@]+"${CC_ENV[@]}"}" CCAGENT_MODEL="$CC_MODEL" \
            MULTIAGENT_WS="$WS/$tag" \
          python escalation/run_bench.py --engine ccagent --only lcb --lcb "$N" \
            --ids-file "$IDS" --parallel "$PAR" --out "$out" > "$RUN/${tag}.log" 2>&1
      else
        env MULTIAGENT_MODEL="$MA_MODEL" MULTIAGENT_WS="$WS/$tag" \
          python escalation/run_bench.py --engine "$layer" --only lcb --lcb "$N" \
            --ids-file "$IDS" --parallel "$PAR" --out "$out" > "$RUN/${tag}.log" 2>&1
      fi
      printf '%s: ' "$tag"
      check "$out" || { FAILED=$((FAILED + 1)); echo "     (see $RUN/${tag}.log)"; }
    done
  done
done

python escalation/regrade.py "$OUT"/*_p[0-9].json

echo
if [ "$FAILED" -gt 0 ]; then
  echo "[$(date +%H:%M:%S)] $FAILED pass(es) did NOT verify -- the table below is incomplete."
  echo "Re-run this script once fixed: verified passes are skipped, broken ones redone."
else
  echo "[$(date +%H:%M:%S)] DONE, all passes verified."
fi
echo
python3 -c '
import glob, json, re, statistics as st
rows = {}
for f in sorted(glob.glob("escalation/runs/agentloop-ab/results/*.regraded.json")):
    tag = re.sub(r"_p\d+", "", f.split("/")[-1])[:-14]
    model, layer = tag.rsplit("_", 1)
    rows.setdefault((model, layer), []).append(json.load(open(f))["lcb"]["pass@1"])
LAYERS = ["single", "multiagent", "ccagent"]
NAMES = {"single": "single call", "multiagent": "paper manager", "ccagent": "Claude Code loop"}
models = sorted({m for m, _ in rows})
if models:
    w = max(max(len(v) for v in NAMES.values()), 16)
    head = "agent layer"
    print(head.ljust(w) + " " + " ".join(m.rjust(16) for m in models))
    for l in LAYERS:
        cells = []
        for m in models:
            v = rows.get((m, l))
            if not v:
                cells.append("-".rjust(16)); continue
            sd = f" +-{st.stdev(v):.1f}" if len(v) > 1 else "     "
            cells.append(f"{st.mean(v):10.1f}" + sd)
        print(NAMES[l].ljust(w) + " " + " ".join(cells))
    print()
    for m in models:
        b, a = rows.get((m, "multiagent")), rows.get((m, "ccagent"))
        if b and a:
            print(f"  {m}: Claude Code loop - paper manager = {st.mean(a) - st.mean(b):+.1f} pts")'
exit $(( FAILED > 0 ))
