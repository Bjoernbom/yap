#!/bin/sh
# Runs the whole ASR spike end to end from spikes/asr and writes every
# command's stdout to .local/results/<step>.log. Takes ~15 min and ~1.3 GB disk.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .local/results
bench=.build/release/asr-bench
run() {
	name="$1"
	shift
	echo "== $name: $*"
	# FluidAudio logs to stderr with a leading "[" — keep only our own output.
	"$@" 2>&1 | grep -v '^\[' | tee ".local/results/$name.log"
}

python3 scripts/fetch_fleurs.py .local/data 30 sv_se en_us
./scripts/make_codeswitch.sh .local/data/codeswitch
swift build -c release

for model in v3 ultra; do
	run "download-$model" $bench download --model $model
	# First load after download compiles the models for the ANE (cold); the second is warm.
	run "load-$model-cold" $bench load --model $model
	run "load-$model-warm" $bench load --model $model
	for lang in sv_se en_us codeswitch; do
		run "bench-$model-$lang" $bench bench --model $model --lang $lang
	done
	run "long-$model-a" $bench long --model $model --offset 0
	run "long-$model-b" $bench long --model $model --offset 11
done

run bench-v3-sv_se-hint $bench bench --model v3 --lang sv_se --hint sv
run idle-v3 $bench idle --model v3
run vocab-v3 $bench vocab --model v3 --lang codeswitch \
	--terms "deploya,staging,pull request,React,npm,Kubernetes,Datadog,roadmap,reviewa,backlog,branch,cachen"

# Edge-case probes (non-zero exit is expected for some).
mkdir -p .local/data/probes
ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 3 -c:a pcm_s16le .local/data/probes/silence-3s.wav
ffmpeg -loglevel error -y -ss 2 -t 0.4 -i .local/data/sv_se/10011314709555999730.wav .local/data/probes/speech-0.4s.wav
ffmpeg -loglevel error -y -ss 2 -t 0.2 -i .local/data/sv_se/10011314709555999730.wav .local/data/probes/speech-0.2s.wav
head -c 20000 /dev/urandom > .local/data/probes/corrupt.wav
for probe in missing corrupt speech-0.2s speech-0.4s silence-3s; do
	echo "== probe $probe"
	$bench transcribe --model v3 --file ".local/data/probes/$probe.wav" 2>&1 | grep -v '^\[' || true
	echo "exit status: $($bench transcribe --model v3 --file ".local/data/probes/$probe.wav" >/dev/null 2>&1; echo $?)"
done | tee .local/results/probes.log

# Per-utterance WER of the clips that make up long clip a (0..10) and b (11..22).
for model in v3 ultra; do
	echo "== $model sv per-utterance"
	python3 scripts/wer_breakdown.py ".local/results/$model-sv_se-nohint.tsv" 0 11
	python3 scripts/wer_breakdown.py ".local/results/$model-sv_se-nohint.tsv" 11 23 | tail -2
	echo "== $model en per-utterance"
	python3 scripts/wer_breakdown.py ".local/results/$model-en_us-nohint.tsv"
done | tee .local/results/wer-breakdown.log
