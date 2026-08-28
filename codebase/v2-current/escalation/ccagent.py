#!/usr/bin/env python3
"""Engine: Claude Code's OWN agent loop, as a drop-in alternative to multiagent_solve().

WHY THIS EXISTS. The paper measures one agent layer -- its manager/worker scaffold over a
shared ledger workspace -- against a single call. It never measures that scaffold against
ANOTHER agent. This module supplies the missing arm: `claude -p` with tools and multiple
rounds, driving itself, on the same problem.

WHAT IS HELD IDENTICAL to multiagent_solve(), so the only difference is the agent layer:

  - the problem text (run_bench.py passes build_code_prompt(prob) to both),
  - the 100 problems and their order (--ids-file),
  - the task framing: spec["solver_system"] is prepended verbatim to the system prompt,
  - the return contract: a ```python fenced block, extracted by the same
    extract_code(raw, LMStyle.ClaudeCode) call,
  - grading, status classification and regrade.

WHAT NECESSARILY DIFFERS -- record these next to any number this produces:

  1. THE DELIVERY CONTRACT. An agent with tools has to be told where to put the answer, so
     DELIVERY_CONTRACT below is appended to the system prompt. The manager arm needs no such
     text because its scaffold writes solution.py itself. This is the one prompt asymmetry
     and it is unavoidable; it is kept as short as possible for that reason.
  2. NO OUTPUT CAP, NO REASONING SWITCH, NO TEMPERATURE. `claude -p` exposes none of them,
     so ESCALATION_CLOUD_MAX_TOKENS and the reasoning knobs do NOT apply here (same caveat
     as orchestrator.claude_cli_chat). Every arm in S2.1 is pinned at 128k; this one is not.
  3. THE AGENT MAY EXECUTE CODE. It gets Bash and can run its own tests against the public
     examples. The manager arm's v2 verifier does the same, so this is a fair pairing -- but
     it is NOT comparable to the single-call arm, which cannot run anything.
  4. TOOL BUDGET IS THE CLI'S, NOT MULTIAGENT_MAX_ITERS. Rounds are bounded by the CLI's own
     loop and by CCAGENT_WALL_SECONDS, not by the scaffold's round budget.

MODEL SELECTION.
  - Subscription auth (no API key): CCAGENT_MODEL=opus  (any alias or id `claude --model`
    takes). Make sure ANTHROPIC_API_KEY is UNSET or the CLI bills the API instead.
  - A local/OpenAI-compatible model: point the CLI at a proxy, e.g.
        ANTHROPIC_BASE_URL=http://localhost:8216/  ANTHROPIC_AUTH_TOKEN=x
        ANTHROPIC_MODEL=<served-name>  CCAGENT_MODEL=<served-name>
    which is how the same model can be put behind BOTH agent layers.
"""
import json
import os
import shutil
import subprocess
import time

from multiagent import WS_ROOT, _record, _slug, _write

MODEL = os.environ.get("CCAGENT_MODEL", "opus")
TOOLS = os.environ.get("CCAGENT_TOOLS", "Read,Write,Edit,Bash,Glob,Grep")
# bypassPermissions is the only mode that lets the agent actually RUN what it writes.
# Under acceptEdits the CLI allows Write/Edit but DENIES Bash, which silently turns this
# arm into a slow single-shot -- it can still produce solution.py, it just cannot verify it.
# _denials below is what stops that from being scored as an agent result.
PERMISSION_MODE = os.environ.get("CCAGENT_PERMISSION_MODE", "bypassPermissions")
WALL_SECONDS = int(os.environ.get("CCAGENT_WALL_SECONDS", "1800"))
ATTEMPTS = int(os.environ.get("CCAGENT_ATTEMPTS", "3"))

# Deliberately minimal: where to put the answer and in what shape. Everything about HOW to
# solve the problem stays in spec["solver_system"], which the manager arm also sees, so the
# two agent layers are given the same task and differ only in how they are organised.
DELIVERY_CONTRACT = """

You are working in the current directory and may use your tools freely -- write scratch
files, run python3, test against the examples in the statement.

Your deliverable is a file named `solution.py` in the current working directory, containing
your final, complete solution and nothing else (no prose, no fences). Write it last, once
you are done. It must match the required I/O format exactly: read stdin and print stdout, or
complete the given function signature without renaming it.
"""


def preflight():
    """Fail before a run rather than 100 problems into one."""
    if PERMISSION_MODE == "bypassPermissions" and hasattr(os, "geteuid") and os.geteuid() == 0:
        raise SystemExit(
            "ccagent: --permission-mode bypassPermissions is refused by the CLI under "
            "root/sudo. Run as a normal user. Do NOT work around it with acceptEdits: that "
            "mode denies Bash, so the agent cannot run its own tests and the arm stops "
            "being an agent-loop arm at all.")


def _events(stdout):
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def ccagent_solve(problem_text, spec, log=None, status_out=None, tests=None):
    """Same signature as multiagent_solve()/single_solve(); returns text for grading.

    `tests` is accepted for interface parity and NOT passed to the agent: the public
    examples are already in the problem statement, and handing them over separately would
    give this arm an input the other arms do not get.
    """
    log = log or (lambda *a, **k: None)
    ws = os.path.join(WS_ROOT, _slug(problem_text))
    # Clean slate, for the reason multiagent_solve gives: the dir is keyed by
    # md5(problem_text), so a re-run would otherwise let the previous attempt's solution.py
    # be read back as this run's answer.
    if os.path.isdir(ws):
        shutil.rmtree(ws)
    os.makedirs(ws, exist_ok=True)
    _write(ws, "task.md", problem_text)
    _record(ws, {"_meta": True, "t": time.time(), "model": MODEL, "kind": spec["kind"],
                 "engine": "ccagent", "tools": TOOLS, "problem": problem_text})

    system = spec["solver_system"] + DELIVERY_CONTRACT
    cmd = ["claude", "-p", "--output-format", "stream-json", "--verbose",
           "--no-session-persistence", "--add-dir", ws,
           "--permission-mode", PERMISSION_MODE, "--model", MODEL,
           "--append-system-prompt", system]
    # --tools is variadic, so it must not be the last flag before a positional, and the
    # prompt must go on stdin or it would be swallowed as a tool name.
    cmd += ["--tools"] + TOOLS.split(",")

    status_out = status_out if status_out is not None else {}
    status_out["ws"] = ws
    for attempt in range(ATTEMPTS):
        timed_out = False
        try:
            proc = subprocess.run(cmd, input=problem_text, capture_output=True, text=True,
                                  timeout=WALL_SECONDS, cwd=ws)
            stdout, stderr, rc = proc.stdout, proc.stderr, proc.returncode
        except subprocess.TimeoutExpired as e:
            timed_out = True
            stdout = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
            stderr = (e.stderr or b"").decode() if isinstance(e.stderr, bytes) else (e.stderr or "")
            rc = None

        text, usage, stop, err, turns = "", {}, None, False, None
        blocks, denials, cost, model_usage = 0, [], None, None
        for ev in _events(stdout):
            if ev.get("type") == "assistant":
                for b in (ev.get("message") or {}).get("content") or []:
                    if b.get("type") == "thinking":
                        blocks += 1
            if ev.get("type") == "result":
                text = ev.get("result") or ""
                usage = ev.get("usage") or {}
                stop = ev.get("stop_reason")
                err = bool(ev.get("is_error"))
                turns = ev.get("num_turns")
                denials = ev.get("permission_denials") or []
                cost = ev.get("total_cost_usd")
                model_usage = ev.get("modelUsage")

        _record(ws, {"t": time.time(), "role": "ccagent", "attempt": attempt + 1,
                     "request": [{"role": "system", "content": system},
                                 {"role": "user", "content": problem_text}],
                     "response": text, "num_turns": turns, "thinking_blocks": blocks,
                     "returncode": rc, "timed_out": timed_out, "stderr": stderr[:2000],
                     "permission_denials": denials, "total_cost_usd": cost,
                     "usage": usage, "model_usage": model_usage,
                     # The CLI returns thinking blocks with an EMPTY text field, so this arm
                     # can record THAT the model thought but never WHAT -- same limitation
                     # as orchestrator.claude_cli_chat.
                     "reasoning": None, "reasoning_is_summary": False})

        status_out.update({
            "finish_reason": ("length" if stop == "max_tokens"
                              else "error" if (err or timed_out) else stop or "stop"),
            "completion_tokens": usage.get("output_tokens"),
            "prompt_tokens": usage.get("input_tokens"),
            "n_calls": turns, "thinking_blocks": blocks, "attempts": attempt + 1,
            # A denied tool call means the agent was PREVENTED from acting, so whatever it
            # produced is not this agent layer's real output. Surfaced per problem and
            # aggregated by the driver, which refuses to report a pass that has any.
            "permission_denied": len(denials),
            "denied_tools": sorted({d.get("tool_name") for d in denials if d.get("tool_name")}),
            "total_cost_usd": cost,
        })
        if denials:
            log(f"    [ccagent] !! {len(denials)} tool call(s) DENIED "
                f"({', '.join(sorted({d.get('tool_name', '?') for d in denials}))}) -- this "
                f"is NOT an agent-loop result; fix --permission-mode before trusting it")

        # The deliverable is the FILE. Fall back to the final message only if the agent
        # answered in a fence instead of writing it -- scoring that as empty would punish
        # the arm for a delivery slip rather than for being wrong.
        sol = os.path.join(ws, "solution.py")
        if os.path.isfile(sol):
            code = open(sol).read().strip()
            if code:
                log(f"    [ccagent] solution.py {len(code)} chars, {turns} turns")
                return f"```python\n{code}\n```"
        if "```" in text:
            log(f"    [ccagent] no solution.py; fenced answer in final message ({turns} turns)")
            return text

        log(f"    [ccagent] no solution (rc={rc} stop={stop} timed_out={timed_out}); "
            f"retrying (attempt {attempt + 1})")
        time.sleep(3 * (attempt + 1))

    # Nothing usable after every attempt: an infra failure, not the model answering wrong.
    # run_bench.py excludes these from pass@1 rather than scoring them as a fail.
    status_out["infra_exhausted"] = True
    return ""
