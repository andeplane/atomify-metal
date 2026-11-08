#!/usr/bin/env python3
"""Measures how fast examples run with 1, 2, 4, ... OpenMP threads.

Usage: bench_threads.py --binary example_check [--examples DIR] [--filter TEXT]
                        [--threads 1,2,4] [--steps N] [--timeout S]

Runs each example of an examples.json catalog once per thread count, one at a
time, through example_check (built by check-examples.sh), for N steps after
its first run starts, and prints steps per second of that run and the speedup
over the first thread count. Started by bench-threads.sh.
"""
import argparse
import json
import pathlib
import sys
import tempfile
from types import SimpleNamespace

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from check_examples import DEFAULT_EXAMPLES, run  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--examples", type=pathlib.Path, default=DEFAULT_EXAMPLES)
    parser.add_argument("--filter", default="", help="only ids containing this text")
    parser.add_argument("--threads", default="1,2,4", help="comma separated thread counts")
    parser.add_argument("--steps", type=int, default=500)
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()
    counts = [int(n) for n in args.threads.split(",")]

    catalog = args.examples.resolve()
    examples = [e for e in json.loads((catalog / "examples.json").read_text())["examples"]
                if args.filter.lower() in e["id"].lower()]
    if not examples:
        sys.exit(f"No examples match '{args.filter}'")
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="atomify-bench-"))
    headers = ["id", "atoms"] + [f"{n} thr steps/s" for n in counts] + [f"x{n}" for n in counts[1:]]
    rows = []
    for example in examples:
        rates, atoms, problem = [], 0, ""
        for n in counts:
            result = run(args.binary.resolve(), catalog, example,
                         SimpleNamespace(steps=args.steps, timeout=args.timeout, threads=n, keep=False), scratch)
            if result["status"] != "ok":
                problem = f"{result['status']} with {n} threads: {result.get('error', '')}"
                break
            atoms = result.get("atoms", 0)
            rates.append(result.get("steps_per_second", 0.0))
            print(f"  {example['id']}: {n} threads, {rates[-1]:.1f} steps/s", file=sys.stderr, flush=True)
        if problem:
            rows.append([example["id"], atoms, problem] + [""] * (len(headers) - 3))
            continue
        speedups = [f"{rate / rates[0]:.2f}" if rates[0] else "" for rate in rates[1:]]
        rows.append([example["id"], atoms] + [f"{rate:.1f}" for rate in rates] + speedups)
    print(table_with(headers, rows))


def table_with(headers, rows):
    widths = [max(len(str(row[i])) for row in [headers] + rows) for i in range(len(headers))]
    lines = ["  ".join(str(h).ljust(w) for h, w in zip(headers, widths)).rstrip()]
    for row in rows:
        lines.append("  ".join(str(v).ljust(w) if i == 0 else str(v).rjust(w)
                               for i, (v, w) in enumerate(zip(row, widths))).rstrip())
    return "\n".join(lines)


if __name__ == "__main__":
    main()
