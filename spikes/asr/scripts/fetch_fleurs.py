#!/usr/bin/env python3
"""Fetch the first N unique-sentence utterances of the FLEURS test split.

Streams the test tarball from Hugging Face and stops as soon as N clips are
extracted, so only a prefix of the ~300-450 MB archive is downloaded.

Writes .local/data/<lang>/<id>.wav and .local/data/<lang>/manifest.tsv
(file \t raw_transcription \t normalized_transcription).
"""

import csv
import io
import os
import sys
import tarfile
import urllib.request

BASE = "https://huggingface.co/datasets/google/fleurs/resolve/main/data"


def fetch(lang: str, count: int, out_root: str) -> None:
	out_dir = os.path.join(out_root, lang)
	os.makedirs(out_dir, exist_ok=True)

	with urllib.request.urlopen(f"{BASE}/{lang}/test.tsv") as response:
		text = response.read().decode("utf-8")
	rows = {}
	for row in csv.reader(io.StringIO(text), delimiter="\t", quoting=csv.QUOTE_NONE):
		# id, file_name, raw_transcription, transcription, phonemes, num_samples, gender
		rows[row[1]] = row

	seen_ids = set()
	kept = []
	with urllib.request.urlopen(f"{BASE}/{lang}/audio/test.tar.gz") as response:
		with tarfile.open(fileobj=response, mode="r|gz") as archive:
			for member in archive:
				name = os.path.basename(member.name)
				row = rows.get(name)
				if not member.isfile() or row is None or row[0] in seen_ids:
					continue
				seen_ids.add(row[0])
				data = archive.extractfile(member).read()
				with open(os.path.join(out_dir, name), "wb") as f:
					f.write(data)
				kept.append((name, row[2], row[3]))
				if len(kept) >= count:
					break

	with open(os.path.join(out_dir, "manifest.tsv"), "w", encoding="utf-8") as f:
		for name, raw, norm in kept:
			f.write(f"{name}\t{raw}\t{norm}\n")
	print(f"{lang}: {len(kept)} clips -> {out_dir}")


if __name__ == "__main__":
	out_root = sys.argv[1]
	count = int(sys.argv[2])
	for lang in sys.argv[3:]:
		fetch(lang, count, out_root)
