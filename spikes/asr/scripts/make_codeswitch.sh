#!/bin/sh
# Synthesizes Swedish sentences with English tech terms using the macOS
# Swedish voice (Alva). Results from these clips are SYNTHETIC speech.
set -eu
out="${1:-.local/data/codeswitch}"
voice="${2:-Alva}"
mkdir -p "$out"
: > "$out/manifest.tsv"
i=0
while IFS= read -r line; do
	[ -z "$line" ] && continue
	i=$((i + 1))
	name=$(printf 'cs%02d.wav' "$i")
	say -v "$voice" -o "$out/$name" --data-format=LEI16@16000 "$line"
	printf '%s\t%s\t\n' "$name" "$line" >> "$out/manifest.tsv"
done <<'EOF'
Kan du deploya till staging innan lunch så att vi hinner testa?
Jag har kommenterat pull requesten, men React-komponenten behöver refaktoreras.
Vi måste fixa buggen i onboarding-flödet innan releasen på fredag.
Pusha din branch och skapa en pull request mot main.
Backend-teamet säger att API-anropet får en timeout när cachen är tom.
Kör npm install och starta om dev-servern.
Jag bokar ett möte med produktteamet om roadmapen för nästa sprint.
Kolla loggarna i Datadog, det ser ut som att Kubernetes-podden kraschar.
Kan du reviewa min feature branch innan du går hem?
Vi kör en retro på torsdag och sedan planerar vi backloggen.
EOF
echo "wrote $i clips to $out"
