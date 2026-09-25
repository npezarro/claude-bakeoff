#!/usr/bin/env python3
"""Calibrate the bakeoff judge against human Pass/Fail labels.

Every verdict in evaluations/ is an LLM judge's opinion, and nothing has ever measured how
often that opinion matches a human's. This measures it, the validate-evaluator way: binary
(output, criterion) items, human labels, disjoint train/dev/test splits, TPR/TNR, and the
bias-corrected pass rate. Items and labels hold real arm outputs, so they live in the
private repo (calibration/ is a symlink into privateContext); this file is code only.

  extract   build the labeling set from runs/ (deterministic, seeded)
  serve     local labeling page for the human (never shows the judge's verdict)
  judge     one binary judge call per item, resumable
  report    TPR/TNR on dev (--final: test, meant to be run once), disagreements, theta

Run through `arena calibrate <cmd>`, which sets up the isolated judge config.
"""
import argparse
import datetime as dt
import http.server
import json
import math
import os
import random
import re
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(os.environ.get("ARENA_ROOT", Path(__file__).resolve().parent.parent))
CAL = Path(os.environ.get("CALIB_DIR", ROOT / "calibration"))
RUNS = ROOT / "runs"
SEED = 20260924

# Which tasks, how many outputs each, and how many criteria per output. Only criteria a
# reader can decide from the response text alone are used: the human labels from the text,
# so the judge must see exactly the same thing or the comparison measures access, not
# judgment. Indices are into the task's eval_criteria list; None = all of them.
PLAN = {
    "report-fluff": {"outputs": 5, "per_output": 6, "criteria": [0, 1, 3, 4, 5], "facts": True},
    "verify-claims": {"outputs": 8, "per_output": 5, "criteria": [2, 3, 4, 5, 6], "facts": False},
    "code-review": {"outputs": 4, "per_output": 5, "criteria": None, "facts": False},
}
SPLIT_FRACTIONS = (0.15, 0.45)  # train, dev; test is the rest


def cfg(key, default=""):
    for line in (ROOT / "config.yaml").read_text().splitlines():
        if line.startswith(key + ":"):
            v = line.split(":", 1)[1].split("#", 1)[0].strip().strip('"')
            return v or default
    return default


def task_block(task, field):
    """Same shape as common.sh get_task_block / the eval_criteria awk: list items or a | block."""
    text = (ROOT / "tasks" / task / "task.yaml").read_text().splitlines()
    out, on = [], False
    for line in text:
        if line.startswith(field + ":"):
            rest = line.split(":", 1)[1].strip()
            if rest and rest not in ("|", ">"):
                return [rest]
            on = True
            continue
        if on:
            if re.match(r"^[a-z_]+:", line):
                break
            s = line.strip()
            if not s:
                continue
            out.append(re.sub(r"^-\s*", "", s) if field == "eval_criteria" else s)
    return out


def task_prompt(task):
    """The prompt block verbatim, blank lines kept (task_block drops them)."""
    lines, on = [], False
    for line in (ROOT / "tasks" / task / "task.yaml").read_text().splitlines():
        if line.startswith("prompt:"):
            rest = line.split(":", 1)[1].strip()
            if rest and rest not in ("|", ">"):
                return rest
            on = True
            continue
        if on:
            if re.match(r"^[a-z_]+:", line):
                break
            lines.append(line[2:] if line.startswith("  ") else line)
    return "\n".join(lines).strip()


def outputs_for(task):
    found = []
    for meta in sorted(RUNS.glob("*/meta.yaml")):
        m = re.search(r"^task:\s*(\S+)", meta.read_text(), re.M)
        if not m or m.group(1) != task:
            continue
        run = meta.parent
        for resp in sorted(list(run.glob("arms/*/response.txt")) + list(run.glob("env-*/response.txt"))):
            text = resp.read_text(errors="replace")
            # A dead arm (the CLI's error JSON, or under run.sh's 20-word FAILED floor) fails
            # every criterion trivially: it would pad TNR without testing any judgment.
            if len(text.split()) < 20 or re.match(r'\s*\{\s*"type":\s*"result"', text):
                continue
            found.append((f"{run.name}/{resp.parent.relative_to(run)}", text))
    return found


def cmd_extract(args):
    items_path = CAL / "items.jsonl"
    if items_path.exists() and not args.force:
        sys.exit(f"{items_path} exists; labels are keyed to it. --force rebuilds (and orphans labels).")
    rng = random.Random(SEED)
    (CAL / "outputs").mkdir(parents=True, exist_ok=True)
    items, outputs_meta = [], []
    for task, plan in PLAN.items():
        pool = outputs_for(task)
        if not pool:
            print(f"skip {task}: no outputs in runs/")
            continue
        # The shortest output is kept on purpose: short arms are where the fails are
        # (dead arms, weak models), and a set with no fails cannot measure TNR.
        shortest = min(pool, key=lambda p: len(p[1].split()))
        rest = [p for p in pool if p is not shortest]
        chosen = [shortest] + rng.sample(rest, min(plan["outputs"] - 1, len(rest)))
        crit = task_block(task, "eval_criteria")
        cands = [("criterion", c) for i, c in enumerate(crit) if plan["criteria"] is None or i in plan["criteria"]]
        if plan["facts"]:
            cands += [("fact", f"The report states this fact, in any wording: {f}") for f in task_block(task, "required_facts")]
        order = list(range(len(chosen)))
        rng.shuffle(order)
        n = len(chosen)
        n_train = max(1, round(SPLIT_FRACTIONS[0] * n))
        n_dev = max(1, round(SPLIT_FRACTIONS[1] * n))
        split_of = {}
        for rank, idx in enumerate(order):
            split_of[idx] = "train" if rank < n_train else "dev" if rank < n_train + n_dev else "test"
        for k, (src, text) in enumerate(chosen):
            oid = f"{task}--{src.replace('/', '--')}"
            (CAL / "outputs" / f"{oid}.txt").write_text(text)
            outputs_meta.append({"output_id": oid, "task": task, "source": src, "split": split_of[k],
                                 "words": len(text.split())})
            # Rotate through the candidate criteria so every one gets labeled somewhere.
            for j in range(min(plan["per_output"], len(cands))):
                kind, c = cands[(k * plan["per_output"] + j) % len(cands)]
                items.append({"id": f"{oid}::{len(items):03d}", "output_id": oid, "task": task,
                              "split": split_of[k], "kind": kind, "criterion": c})
    with items_path.open("w") as f:
        for it in items:
            f.write(json.dumps(it) + "\n")
    (CAL / "outputs.json").write_text(json.dumps(outputs_meta, indent=1))
    prompts = {t: task_prompt(t) for t in PLAN}
    (CAL / "task-prompts.json").write_text(json.dumps(prompts, indent=1))
    print(f"{len(items)} items from {len(outputs_meta)} outputs -> {items_path}")
    summarize(items)


def summarize(items):
    tab = {}
    for it in items:
        tab.setdefault((it["task"], it["split"]), 0)
        tab[(it["task"], it["split"])] += 1
    for (t, s), n in sorted(tab.items()):
        print(f"  {t:15s} {s:6s} {n}")


def load_items():
    p = CAL / "items.jsonl"
    if not p.exists():
        sys.exit("No items yet: run `arena calibrate extract` first.")
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


def labels_path():
    return Path(os.environ.get("CALIB_LABELS", CAL / "labels.json"))


def load_labels():
    p = labels_path()
    return json.loads(p.read_text()) if p.exists() else {}


# ---------------------------------------------------------------- serve

PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><title>Judge calibration labels</title>
<style>
:root{--bg:#faf8f4;--fg:#222;--mut:#777;--card:#fff;--line:#ddd;--pass:#1f7a3a;--fail:#b3261e;--acc:#2b5fb4}
@media (prefers-color-scheme:dark){:root{--bg:#1b1b1b;--fg:#e8e8e8;--mut:#999;--card:#252525;--line:#3a3a3a;--pass:#5cc97a;--fail:#ff7a70;--acc:#8ab4ff}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}
header{position:sticky;top:0;background:var(--card);border-bottom:1px solid var(--line);padding:10px 16px;z-index:2}
.crit{font-size:17px;font-weight:600;margin:4px 0 8px}
.meta{color:var(--mut);font-size:13px}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
button{font:inherit;padding:6px 14px;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--fg);cursor:pointer}
button.p.on{background:var(--pass);color:#fff;border-color:var(--pass)}
button.f.on{background:var(--fail);color:#fff;border-color:var(--fail)}
input#note{flex:1;min-width:200px;font:inherit;padding:6px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)}
main{max-width:900px;margin:0 auto;padding:16px}
details{margin-bottom:12px}
pre{white-space:pre-wrap;word-wrap:break-word;background:var(--card);border:1px solid var(--line);border-radius:6px;padding:14px;font:14px/1.5 ui-monospace,monospace}
.same{color:var(--acc);font-size:13px}
</style></head><body>
<header>
 <div class="meta" id="pos"></div>
 <div class="crit" id="crit"></div>
 <div class="row">
  <button class="p" id="bp">Pass (p)</button><button class="f" id="bf">Fail (f)</button>
  <input id="note" placeholder="optional note: why (Enter saves, Esc leaves the box)">
  <button id="bprev">Back (b)</button><button id="bnext">Next (n)</button><button id="bskip">Next unlabeled (u)</button>
 </div>
</header>
<main>
 <div class="same" id="same"></div>
 <details><summary>What the author was asked (task prompt)</summary><pre id="prompt"></pre></details>
 <pre id="out"></pre>
</main>
<script>
let items=[],labels={},prompts={},outs={},i=0;
const $=id=>document.getElementById(id);
async function boot(){
 const d=await (await fetch('/api/data')).json();
 items=d.items;labels=d.labels;prompts=d.prompts;
 try{const b=JSON.parse(localStorage.getItem('calib-labels')||'{}');for(const k in b)if(!labels[k])labels[k]=b[k]}catch(e){}
 i=Math.max(0,items.findIndex(x=>!labels[x.id]));if(i<0)i=0;show();
}
async function out(oid){if(!outs[oid])outs[oid]=await (await fetch('/api/output?id='+encodeURIComponent(oid))).text();return outs[oid]}
async function show(){
 const it=items[i],l=labels[it.id]||{};
 const done=items.filter(x=>labels[x.id]).length;
 $('pos').textContent=`${i+1} / ${items.length}  ·  ${done} labeled  ·  ${it.task}  ·  ${it.kind}`;
 $('crit').textContent=it.criterion;
 $('bp').classList.toggle('on',l.label==='pass');$('bf').classList.toggle('on',l.label==='fail');
 $('note').value=l.note||'';
 const prev=items[i-1];$('same').textContent=prev&&prev.output_id===it.output_id?'Same response as the previous item.':'New response.';
 $('prompt').textContent=prompts[it.task]||'';
 const o=await out(it.output_id);if(items[i]===it){$('out').textContent=o}
 if(!(prev&&prev.output_id===it.output_id))window.scrollTo(0,0);
}
async function save(){
 try{localStorage.setItem('calib-labels',JSON.stringify(labels))}catch(e){}
 await fetch('/api/labels',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(labels)});
}
function set(v){const it=items[i];labels[it.id]={label:v,note:$('note').value,at:new Date().toISOString()};save();show()}
function go(d){i=Math.min(items.length-1,Math.max(0,i+d));show()}
function nextUnlabeled(){for(let k=1;k<=items.length;k++){const j=(i+k)%items.length;if(!labels[items[j].id]){i=j;return show()}}}
$('bp').onclick=()=>set('pass');$('bf').onclick=()=>set('fail');
$('bnext').onclick=()=>go(1);$('bprev').onclick=()=>go(-1);$('bskip').onclick=nextUnlabeled;
$('note').addEventListener('keydown',e=>{if(e.key==='Enter'){const it=items[i];if(labels[it.id]){labels[it.id].note=$('note').value;save()}$('note').blur()}if(e.key==='Escape')$('note').blur()});
document.addEventListener('keydown',e=>{if(e.target.tagName==='INPUT')return;
 if(e.key==='p')set('pass');else if(e.key==='f')set('fail');else if(e.key==='n')go(1);else if(e.key==='b')go(-1);else if(e.key==='u')nextUnlabeled();});
boot();
</script></body></html>"""


def cmd_serve(args):
    items = load_items()
    prompts = json.loads((CAL / "task-prompts.json").read_text())
    # Grouped by response so a long output is read once and labeled several times.
    # Short tasks first (report-fluff, then verify-claims), the ~2000-word code reviews last.
    order = list(PLAN)
    items.sort(key=lambda x: (order.index(x["task"]) if x["task"] in order else 99, x["output_id"], x["id"]))
    # The judge's verdicts are never read here: a label made after seeing the judge is an
    # agreement measurement of nothing.
    public_items = [{k: it[k] for k in ("id", "output_id", "task", "kind", "criterion")} for it in items]
    known = {it["output_id"] for it in items}
    lock = threading.Lock()

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, body, ctype):
            b = body.encode() if isinstance(body, str) else body
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            if self.path == "/":
                return self.send(200, PAGE, "text/html; charset=utf-8")
            if self.path == "/api/data":
                return self.send(200, json.dumps({"items": public_items, "labels": load_labels(), "prompts": prompts}), "application/json")
            if self.path.startswith("/api/output?id="):
                from urllib.parse import unquote
                oid = unquote(self.path.split("=", 1)[1])
                if oid not in known:
                    return self.send(404, "unknown output", "text/plain")
                return self.send(200, (CAL / "outputs" / f"{oid}.txt").read_text(), "text/plain; charset=utf-8")
            self.send(404, "not found", "text/plain")

        def do_POST(self):
            if self.path != "/api/labels":
                return self.send(404, "not found", "text/plain")
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            data = {k: v for k, v in data.items() if v.get("label") in ("pass", "fail")}
            with lock:
                # Merge, never replace: a stale second tab must not erase labels it never saw.
                merged = {**load_labels(), **data}
                p = labels_path()
                tmp = p.with_suffix(".tmp")
                tmp.write_text(json.dumps(merged, indent=1, sort_keys=True))
                tmp.replace(p)
            self.send(200, '{"ok":true}', "application/json")

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), H)
    print(f"Labeling {len(items)} items: http://localhost:{args.port}/  (Ctrl-C to stop; labels -> {labels_path()})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


# ---------------------------------------------------------------- judge

JUDGE_TEMPLATE = """You are checking ONE criterion against ONE response. Decide from the response text alone.

An AI agent was given this task:
<task>
{prompt}
</task>

This is its final response:
<response>
{output}
</response>

The criterion:
<criterion>
{criterion}
</criterion>

PASS means the response meets the criterion. FAIL means it does not, including when the
response is silent on it or only gestures at it. Do not give credit for what the author
may have done but did not show or say.

Return ONLY a JSON object, no prose, no code fence:
{{"verdict": "PASS" or "FAIL", "reason": "one sentence"}}"""


def judge_one(it, prompts, model):
    out = (CAL / "outputs" / f"{it['output_id']}.txt").read_text()
    prompt = JUDGE_TEMPLATE.format(prompt=prompts[it["task"]], output=out, criterion=it["criterion"])
    with tempfile.TemporaryDirectory() as cwd:
        r = subprocess.run(["claude", "--print", "--model", model, "--max-turns", "3",
                            "--dangerously-skip-permissions"], input=prompt, capture_output=True,
                           text=True, cwd=cwd, timeout=600)
    raw = r.stdout.strip()
    m = re.search(r"\{.*\}", raw, re.S)
    verdict, reason, err = None, "", None
    try:
        j = json.loads(m.group(0)) if m else None
        v = str(j.get("verdict", "")).upper() if j else ""
        if v in ("PASS", "FAIL"):
            verdict, reason = v.lower(), j.get("reason", "")
        else:
            err = "no PASS/FAIL in output"
    except Exception as e:
        # The judge sometimes puts unescaped quotes in its reason; the verdict is still there.
        mv = re.search(r'"verdict"\s*:\s*"(PASS|FAIL)"', raw, re.I)
        mr = re.search(r'"reason"\s*:\s*"(.*)"\s*\}', raw, re.S)
        if mv:
            verdict, reason = mv.group(1).lower(), mr.group(1) if mr else ""
        else:
            err = f"unparseable: {e}"
    if err:
        err += f" | rc={r.returncode} | {raw[:200]!r} | {r.stderr[-200:]!r}"
    return {"id": it["id"], "verdict": verdict, "reason": reason, "error": err, "model": model,
            "at": dt.datetime.now().isoformat(timespec="seconds")}


def verdicts_path(model):
    return CAL / "verdicts" / f"{model}.jsonl"


def load_verdicts(model):
    p = verdicts_path(model)
    v = {}
    if p.exists():
        for line in p.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                if r.get("verdict"):
                    v[r["id"]] = r
    return v


def cmd_judge(args):
    model = args.model or cfg("judge_model", "claude-fable-5")
    items = load_items()
    prompts = json.loads((CAL / "task-prompts.json").read_text())
    done = load_verdicts(model)
    todo = [it for it in items if it["id"] not in done][: args.limit or None]
    if not todo:
        print(f"All {len(items)} items already judged by {model}.")
        return
    if not os.environ.get("CLAUDE_CONFIG_DIR"):
        print("WARNING: no isolated CLAUDE_CONFIG_DIR; run through `arena calibrate judge`.", file=sys.stderr)
    print(f"Judging {len(todo)} items with {model} ({args.jobs} at a time)")
    p = verdicts_path(model)
    p.parent.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()
    n_ok = n_err = 0

    def run(it):
        nonlocal n_ok, n_err
        try:
            rec = judge_one(it, prompts, model)
        except Exception as e:
            rec = {"id": it["id"], "verdict": None, "error": f"exception: {e}", "model": model}
        with lock:
            with p.open("a") as f:
                f.write(json.dumps(rec) + "\n")
            if rec["verdict"]:
                n_ok += 1
            else:
                n_err += 1
                print(f"  ERROR {it['id']}: {rec['error'][:160]}", file=sys.stderr)
            print(f"  {n_ok + n_err}/{len(todo)}", end="\r", flush=True)

    with ThreadPoolExecutor(args.jobs) as ex:
        list(ex.map(run, todo))
    print(f"\nDone: {n_ok} verdicts, {n_err} errors (errors are retried on the next run) -> {p}")


# ---------------------------------------------------------------- report

def wilson(k, n, z=1.96):
    if n == 0:
        return (float("nan"), float("nan"))
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0, c - h), min(1, c + h))


def pct(x):
    return "  n/a" if x != x else f"{100 * x:5.1f}%"


def cmd_report(args):
    model = args.model or cfg("judge_model", "claude-fable-5")
    items = {it["id"]: it for it in load_items()}
    labels = load_labels()
    verdicts = load_verdicts(model)
    split = "test" if args.final else "dev"
    if args.final:
        log = CAL / "FINAL_RUNS.log"
        prior = log.read_text() if log.exists() else ""
        if prior and not args.again:
            sys.exit(f"The test split was already scored ({log}). It is meant to be looked at once; "
                     "--again overrides, and whatever you learn from it is no longer a held-out number.")
        with log.open("a") as f:
            f.write(f"{dt.datetime.now().isoformat(timespec='seconds')} model={model} labels={labels_path()}\n")

    print(f"Judge: {model}   split: {split}   labels: {labels_path()}")
    print(f"Items: {len(items)}   labeled: {sum(1 for k in labels if k in items)}   judged: {sum(1 for k in verdicts if k in items)}")
    pairs = [(items[k], labels[k], verdicts[k]) for k in items
             if items[k]["split"] == split and k in labels and k in verdicts]
    if not pairs:
        print(f"\nNo {split} items have both a human label and a verdict yet.")
        return

    def rates(ps):
        hp = [p for p in ps if p[1]["label"] == "pass"]
        hf = [p for p in ps if p[1]["label"] == "fail"]
        tp = sum(1 for p in hp if p[2]["verdict"] == "pass")
        tn = sum(1 for p in hf if p[2]["verdict"] == "fail")
        return tp, len(hp), tn, len(hf)

    print(f"\n{'slice':22s} {'n':>4s} {'H-pass':>6s} {'H-fail':>6s} {'TPR':>7s} {'95% CI':>15s} {'TNR':>7s} {'95% CI':>15s}")
    slices = [("ALL", pairs)] + [(t, [p for p in pairs if p[0]["task"] == t]) for t in sorted({p[0]["task"] for p in pairs})]
    for name, ps in slices:
        tp, npos, tn, nneg = rates(ps)
        tpr = tp / npos if npos else float("nan")
        tnr = tn / nneg if nneg else float("nan")
        a, b = wilson(tp, npos)
        c, d = wilson(tn, nneg)
        print(f"{name:22s} {len(ps):4d} {npos:6d} {nneg:6d} {pct(tpr):>7s} {pct(a)+'-'+pct(b):>15s} {pct(tnr):>7s} {pct(c)+'-'+pct(d):>15s}")

    tp, npos, tn, nneg = rates(pairs)
    tpr = tp / npos if npos else float("nan")
    tnr = tn / nneg if nneg else float("nan")
    if nneg < 15 or npos < 15:
        print(f"\nWARNING: {npos} human-pass / {nneg} human-fail items. Under ~15 of either class the rate "
              "is too noisy to act on (see the CI width).")
    verdict_word = ("meets the 90/90 target" if tpr > .9 and tnr > .9 else
                    "meets the 80/80 minimum" if tpr > .8 and tnr > .8 else "below the 80/80 minimum")
    print(f"\nOverall: TPR {pct(tpr).strip()}, TNR {pct(tnr).strip()}: {verdict_word}.")

    # Bias-corrected pass rate over everything the judge scored, not just the labeled split.
    judged = [v for k, v in verdicts.items() if k in items]
    if judged and npos and nneg:
        p_obs = sum(1 for v in judged if v["verdict"] == "pass") / len(judged)
        denom = tpr + tnr - 1
        if denom <= 0:
            print(f"Judge pass rate {pct(p_obs).strip()} over {len(judged)} items; no correction possible "
                  f"(TPR + TNR - 1 = {denom:.2f}, the judge is no better than chance).")
        else:
            theta = min(1, max(0, (p_obs + tnr - 1) / denom))
            print(f"Judge pass rate {pct(p_obs).strip()} over {len(judged)} items; "
                  f"bias-corrected true pass rate theta = (p_obs + TNR - 1)/(TPR + TNR - 1) = {pct(theta).strip()}")

    dis = [p for p in pairs if p[1]["label"] != p[2]["verdict"]]
    print(f"\nDisagreements: {len(dis)} of {len(pairs)}")
    for it, lab, ver in dis:
        kind = "FALSE PASS (judge too lenient)" if ver["verdict"] == "pass" else "FALSE FAIL (judge too strict)"
        print(f"\n- {kind}  [{it['id']}]")
        print(f"  criterion: {it['criterion']}")
        print(f"  judge:     {ver.get('reason', '')}")
        if lab.get("note"):
            print(f"  human:     {lab['note']}")


def main():
    ap = argparse.ArgumentParser(prog="arena calibrate")
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("extract"); e.add_argument("--force", action="store_true")
    s = sub.add_parser("serve"); s.add_argument("--port", type=int, default=8787)
    j = sub.add_parser("judge"); j.add_argument("--model"); j.add_argument("--jobs", type=int, default=4); j.add_argument("--limit", type=int)
    r = sub.add_parser("report"); r.add_argument("--model"); r.add_argument("--final", action="store_true"); r.add_argument("--again", action="store_true")
    a = ap.parse_args()
    if not CAL.exists():
        sys.exit(f"{CAL} missing. It should be a symlink into privateContext (see README, Judge calibration).")
    {"extract": cmd_extract, "serve": cmd_serve, "judge": cmd_judge, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
