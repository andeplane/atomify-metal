#!/usr/bin/env python3
"""Runs every example of an examples.json catalog with the host build of the
bridge and prints a results table (the Linux counterpart of
`swift run atomify-check-examples`).

Usage: check_examples.py --binary example_check [--examples DIR] [--steps N]
                         [--timeout S] [--filter TEXT] [--jobs N] [--threads T] [--continue] [--keep]

Each example runs in a fresh working copy (its files under their fileName,
`suffix kk` lines commented out, as AtomifyKit's ExampleCatalog does) and in
its own process, until its input completes or N steps after the first run
started, with a wall clock timeout. Examples marked
"atomifyMetal": {"skip": "reason"} are listed as skipped. Exits 1 if any
example failed or timed out.
"""

import argparse
import concurrent.futures
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_EXAMPLES = HERE.parents[3] / "src/macos/AtomifyMac/Examples"


def prepare(script: str) -> str:
    """Comments out `suffix kk` lines and turns `#/speed` and `#/label` lines
    into print commands, like ScriptPreparation.prepare."""
    lines = script.split("\n")
    changed = False
    for i, line in enumerate(lines):
        words = re.split(r"[ \t\r]+", line.strip(" \t\r"))
        if len(words) >= 2 and words[0] == "suffix" and (words[1] == "kk" or words[1].startswith("kk#")):
            lines[i] = f"# {line}  (KOKKOS is not in this build)"
            changed = True
        directive = re.match(r"^[ \t]*#/(speed|label)(?:[ \t]+(.*))?$", line.rstrip("\r"))
        if directive:
            argument = (directive.group(2) or "").strip()
            if directive.group(1) == "speed":
                try:
                    ok = float(argument) > 0
                except ValueError:
                    ok = False
                if ok:
                    lines[i] = f'print "@atomify speed {argument}"'
                    changed = True
            else:
                text = argument.replace('"', "").replace("$", "").replace("'", "`")
                lines[i] = f'print "@atomify label {text}"'
                changed = True
    return "\n".join(lines) if changed else script


def working_copy(catalog: pathlib.Path, example: dict, scratch: pathlib.Path) -> pathlib.Path:
    folder = pathlib.Path(tempfile.mkdtemp(prefix=f"atomify-{re.sub(r'[^A-Za-z0-9_-]', '_', example['id'])}-",
                                           dir=scratch))
    for file in example["files"]:
        url = file["url"]
        if url.startswith("/") or "://" in url or ".." in url.split("/"):
            raise ValueError(f"unsupported file location {url}")
        source = catalog / url
        if not source.is_file():
            raise FileNotFoundError(f"The example file {url} is missing.")
        shutil.copyfile(source, folder / file["fileName"])
    script = folder / example["inputScript"]
    if not script.exists():
        raise FileNotFoundError(f"The input script {example['inputScript']} is not one of the example's files.")
    text = script.read_text()
    prepared = prepare(text)
    if prepared != text:
        script.write_text(prepared)
    return folder


def run(binary, catalog, example, args, scratch):
    skip = (example.get("atomifyMetal") or {}).get("skip")
    if skip:
        return dict(status="skipped", atoms=0, steps=0, seconds=0.0, error=skip, line="")
    started = time.monotonic()
    try:
        folder = working_copy(catalog, example, scratch)
    except Exception as error:    # noqa: BLE001 - reported in the table
        return dict(status="failed", atoms=0, steps=0, seconds=0.0, error=str(error), line="")
    try:
        process = subprocess.run([str(binary), example["inputScript"], "--steps", str(args.steps),
                                  "--timeout", str(args.timeout), "--threads", str(args.threads),
                                  "--continue", "1" if getattr(args, "continue_after", False) else "0"],
                                 cwd=folder, capture_output=True, text=True, timeout=args.timeout + 60)
        lines = [line for line in process.stdout.splitlines() if line.startswith("{")]
        if lines:
            result = json.loads(lines[-1])
        else:
            tail = (process.stderr.strip().splitlines() or ["no result"])[-1]
            result = dict(status="failed", atoms=0, steps=0, error=f"crashed ({process.returncode}): {tail}", line="")
    except subprocess.TimeoutExpired:
        result = dict(status="timeout", atoms=0, steps=0, error="did not stop after cancelling", line="")
    result["seconds"] = round(time.monotonic() - started, 2)
    result["log"] = str(folder / "atomify-check.log")
    if not args.keep and result["status"] == "ok":
        shutil.rmtree(folder, ignore_errors=True)
    return result


def table(rows):
    """Same columns as ExampleRunResult.table in AtomifyKit."""
    headers = ["id", "status", "ended", "atoms", "steps", "seconds", "error"]
    last = len(headers) - 1
    widths = [max(len(str(row[i])) for row in [headers] + rows) for i in range(last)]

    def line(row, header=False):
        cells = []
        for i, value in enumerate(row):
            text = str(value)
            if i < last:
                text = text.rjust(widths[i]) if i in (3, 4, 5) and not header else text.ljust(widths[i])
            cells.append(text)
        return "  ".join(cells).rstrip()
    return "\n".join([line(headers, True)] + [line(row) for row in rows])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--examples", type=pathlib.Path, default=DEFAULT_EXAMPLES)
    parser.add_argument("--steps", type=int, default=100)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--filter", default="", help="only ids containing this text")
    parser.add_argument("--jobs", type=int, default=1, help="examples run at the same time")
    parser.add_argument("--threads", type=int, default=1, help="OpenMP threads per example")
    parser.add_argument("--continue", dest="continue_after", action="store_true",
                        help="keep running after the input completes, as the apps do")
    parser.add_argument("--keep", action="store_true", help="keep working copies of passing examples too")
    args = parser.parse_args()

    catalog = args.examples.resolve()
    examples = [e for e in json.loads((catalog / "examples.json").read_text())["examples"]
                if args.filter.lower() in e["id"].lower()]
    if not examples:
        sys.exit(f"No examples match '{args.filter}'")
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="atomify-examples-"))
    print(f"Running {len(examples)} examples from {catalog} ({args.steps} steps, {args.timeout:g} s timeout); "
          f"working copies in {scratch}", flush=True)

    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = {pool.submit(run, args.binary.resolve(), catalog, e, args, scratch): e["id"] for e in examples}
        for future in concurrent.futures.as_completed(futures):
            identifier = futures[future]
            results[identifier] = future.result()
            r = results[identifier]
            print(f"  {identifier}: {r['status']} ({r['seconds']} s)", file=sys.stderr, flush=True)

    rows = []
    for example in examples:
        r = results[example["id"]]
        message = r.get("error") or ""
        if r.get("line"):
            message += f"  [line: {r['line']}]"
        if r["status"] in ("failed", "timeout") and r.get("log"):
            message += f"  (log: {r['log']})"
        ended = {"completed": "input", "steps": "steps"}.get(r.get("reason"), "")
        rows.append([example["id"], r["status"], ended, r.get("atoms", 0), r.get("steps", 0),
                     f"{r['seconds']:.1f}", message])
    print(table(rows))
    counts = {s: sum(1 for r in results.values() if r["status"] == s) for s in ("ok", "failed", "timeout", "skipped")}
    print(f"\n{counts['ok']} ok, {counts['failed']} failed, {counts['timeout']} timed out, {counts['skipped']} skipped")
    sys.exit(1 if counts["failed"] or counts["timeout"] else 0)


if __name__ == "__main__":
    main()
