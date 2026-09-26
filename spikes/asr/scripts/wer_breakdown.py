#!/usr/bin/env python3
"""Re-scores an asr-bench hypotheses TSV (name, duration, latency, ref, hyp).

Prints corpus WER for the first N clips (to compare with the long-clip run)
and WER over clips whose reference and hypothesis contain no digits (to see
how much of the error is numerals written as words vs digits).
"""

import sys


def normalize(text):
	chars = [c if c.isalpha() or c.isdigit() else " " for c in text.lower()]
	return "".join(chars).split()


def edits(ref, hyp):
	prev = list(range(len(hyp) + 1))
	for i in range(1, len(ref) + 1):
		cur = [i] + [0] * len(hyp)
		for j in range(1, len(hyp) + 1):
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ref[i - 1] != hyp[j - 1]))
		prev = cur
	return prev[len(hyp)]


def wer(rows):
	e = sum(edits(normalize(r), normalize(h)) for r, h in rows)
	n = sum(len(normalize(r)) for r, _ in rows)
	return 100 * e / n, e, n


path = sys.argv[1]
first = int(sys.argv[2]) if len(sys.argv) > 2 else 0
rows = [line.rstrip("\n").split("\t")[3:5] for line in open(path, encoding="utf-8")]
print("all clips:        %.2f %% (%d/%d)" % wer(rows))
if first:
	print("first %d clips:   %.2f %% (%d/%d)" % ((first,) + wer(rows[:first])))
no_digits = [(r, h) for r, h in rows if not any(c.isdigit() for c in r + h)]
print("no-digit clips:   %.2f %% (%d/%d), %d of %d clips" % (wer(no_digits) + (len(no_digits), len(rows))))
