#!/usr/bin/env python3
"""Test Speechy's cleanup/structuring prompt against many examples.

Usage:
  python3 scripts/test_cleanup.py                       # run the built-in suite (3B)
  python3 scripts/test_cleanup.py --model qwen2.5:7b-instruct
  python3 scripts/test_cleanup.py "your dictation here" # test one input
  pbpaste | python3 scripts/test_cleanup.py -           # test piped text

For every example it prints the input, the model output, and a STRICT
multiset word-diff (words added / removed) so you can instantly see if the
model paraphrased, invented, or dropped anything. Add your own cases to
EXAMPLES below — the goal is to find inputs that break it.

STRUCTURE_PROMPT mirrors `structurePrompt` in Sources/Speechy/Cleanup.swift —
keep the two in sync if you change one.
"""
import argparse
import json
import re
import sys
import urllib.request
from collections import Counter

STRUCTURE_PROMPT = """You format dictated speech for readability. Keep EVERY word — never paraphrase, add, remove, or reorder words. Your only job is to join the words into natural sentences and paragraphs, and to use a bulleted list ONLY for a genuine list of parallel items. Never bullet ordinary sentences or trailing-off fragments like "and..." or "yeah, so...".

Example A
Input: i think the design is off the menu is cluttered separately the performance is bad the cold load is too slow
Output:
I think the design is off, the menu is cluttered.

Separately, the performance is bad. The cold load is too slow.

Example B
Input: for launch we need to finish the landing page set up the email campaign and reach out to beta users
Output:
For launch we need to:
- Finish the landing page
- Set up the email campaign
- Reach out to beta users"""

# (label, input). Inputs are realistic dictation — messy, run-on, with fillers,
# false starts, lists, quotes, jargon, numbers, questions, and long rambles.
EXAMPLES = [
    ("clean one-liner", "yeah I think that approach makes sense let's go with it"),
    ("two topics → 2 paragraphs",
     "the onboarding flow feels too long we should cut a step separately the pricing page needs better copy it's confusing right now"),
    ("real list (a few things)",
     "okay a few things we need to do ship the beta write the docs email the users and post the announcement"),
    ("real list (first/second/third)",
     "first finish the parser then add tests then write the readme and finally tag a release"),
    ("false starts / fragments (must NOT bullet)",
     "fine and how it should be the issue is the fallback text outside the images that's what we don't want and yeah so let's yeah let's fix telegram and prioritize images before voicing"),
    ("filler heavy",
     "um so like I was thinking you know maybe we should uh just refactor the whole thing honestly"),
    ("long ramble, multi-topic",
     "so the demo went okay but the latency was rough especially on the first request anyway the client liked the ui they had questions about security which I couldn't fully answer we should prep a doc for that and also the billing integration is still flaky we keep getting timeouts from stripe"),
    ("embedded list in prose",
     "before we ship we need to do a few things like update the changelog bump the version and notify support but honestly the changelog is the only urgent one"),
    ("technical jargon",
     "the race condition is in the actor reentrancy we await inside the lock so two tasks interleave and corrupt the buffer we should use a serial queue instead"),
    ("question + statement",
     "should we use websockets or just poll I lean towards polling for now it's simpler and we don't need realtime yet"),
    ("numbers and times",
     "let's meet tuesday at 3 we need about 45 minutes to cover the 4 open issues and the 2 blockers"),
    ("single fragment",
     "yeah totally"),
    ("contradiction kept (not a correction)",
     "I went to the store but actually it was closed so I came back empty handed"),
    ("two real lists",
     "for the frontend we need routing state and styling for the backend we need auth the database and the api"),
    ("quotes via spoken markers (manual)",
     "and then she said open quote I can't make it close quote which threw off the whole plan"),
    ("imperative steps",
     "clone the repo install the deps run the build then open the app and grant permissions"),
    ("opinion + hedge",
     "I'm not totally sure but I think the dark mode contrast is too low we might want to bump it a bit"),
    ("list of two (too short to bullet?)",
     "we should ship monday and tell the team friday"),
    ("self-reference / meta",
     "this is just a quick note to myself remember to follow up with the design team about the icon set"),
    ("all caps acronyms",
     "the API returns JSON but the SDK expects XML so we need a shim in the BFF layer"),
]


def clean(text, model):
    payload = {
        "model": model,
        "stream": False,
        "keep_alive": "5m",
        "options": {"temperature": 0.1},
        "prompt": f"{STRUCTURE_PROMPT}\n\nNow format this:\nInput: {text}\nOutput:",
    }
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    return json.loads(urllib.request.urlopen(req, timeout=120).read())["response"].strip()


def word_diff(src, out):
    """Strict multiset diff — catches count changes (e.g. an 'I' becoming 'she')."""
    a = Counter(re.findall(r"\w+", src.lower()))
    b = Counter(re.findall(r"\w+", out.lower()))
    added = sorted((b - a).elements())
    removed = sorted((a - b).elements())
    return added, removed


def show(label, src, model):
    out = clean(src, model)
    added, removed = word_diff(src, out)
    flag = "  ⚠️ WORDS CHANGED" if (added or removed) else "  ✓ words intact"
    print(f"\n=== {label} ===")
    print(f"IN : {src}")
    print(f"OUT:\n{out}")
    print(f"{flag}   added={added}  removed={removed}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="?", help="single input, or '-' to read stdin")
    ap.add_argument("--model", default="qwen2.5:3b-instruct")
    args = ap.parse_args()

    if args.text == "-":
        show("stdin", sys.stdin.read().strip(), args.model)
    elif args.text:
        show("custom", args.text, args.model)
    else:
        print(f"Running {len(EXAMPLES)} examples on {args.model}…")
        for label, src in EXAMPLES:
            show(label, src, args.model)


if __name__ == "__main__":
    main()
