#!/usr/bin/env bash
# veo.sh — generate a video with Google Veo through the LiteLLM gateway.
#
#   veo.sh [-m MODEL] [-s 4|6|8] [-r 1280x720|720x1280|1920x1080] [-o out.mp4] "prompt"
#
# Gateway URL and key: VEO_BASE_URL / VEO_API_KEY, else the Claude gateway in
# ~/.claude/settings.json (ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN).
# Every successful run is billed per second of video. Prints the saved path.
set -euo pipefail

model=veo-3.1-fast-generate-001 seconds=4 size=1280x720 out=""
while getopts "m:s:r:o:h" o; do case "$o" in
  m) model="$OPTARG";; s) seconds="$OPTARG";; r) size="$OPTARG";; o) out="$OPTARG";;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac; done
shift $((OPTIND - 1))
prompt="${*:-}"
[ -n "$prompt" ] || { echo "veo.sh: give a prompt (veo.sh -h)" >&2; exit 2; }
case "$seconds" in 4|6|8) ;; *) echo "veo.sh: -s must be 4, 6 or 8 (Veo's only durations)" >&2; exit 2;; esac
[ "$size" = 1920x1080 ] && [ "$seconds" != 8 ] && { echo "veo.sh: 1920x1080 needs -s 8" >&2; exit 2; }
case "$model" in vertex_ai/*) ;; *) model="vertex_ai/$model";; esac

s="$HOME/.claude/settings.json"
base="${VEO_BASE_URL:-$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$s" 2>/dev/null || true)}"
key="${VEO_API_KEY:-$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$s" 2>/dev/null || true)}"
[ -n "$base" ] && [ -n "$key" ] || { echo "veo.sh: no gateway: set VEO_BASE_URL/VEO_API_KEY or the Claude gateway in roost" >&2; exit 1; }
base="${base%/}"
auth=(-H "Authorization: Bearer $key")

[ -n "$out" ] || out="veo-$(date +%Y%m%d-%H%M%S).mp4"
mkdir -p "$(dirname "$out")"

r="$(curl -sS -m 120 "${auth[@]}" "$base/v1/videos" \
      -F "model=$model" -F "prompt=$prompt" -F "seconds=$seconds" -F "size=$size")"
id="$(jq -r '.id // empty' <<<"$r")"
[ -n "$id" ] || { echo "veo.sh: request refused: $(jq -r '.error.message // .' <<<"$r" | head -c 400)" >&2; exit 1; }
echo "veo.sh: started ${model#vertex_ai/}, ${seconds}s ${size}; waiting (usually 1-3 min)" >&2

for _ in $(seq 1 90); do       # up to 15 minutes
  sleep 10
  r="$(curl -sS -m 60 "${auth[@]}" "$base/v1/videos/$id")" || continue
  case "$(jq -r '.status // empty' <<<"$r")" in
    completed) break;;
    failed) echo "veo.sh: failed: $(jq -r '.error.message // .error // .' <<<"$r" | head -c 400)" >&2; exit 1;;
  esac
done
[ "$(jq -r '.status // empty' <<<"$r")" = completed ] || { echo "veo.sh: still not done after 15 minutes; id: $id" >&2; exit 1; }

curl -sS -m 300 -f "${auth[@]}" "$base/v1/videos/$id/content" -o "$out"
echo "$out"
