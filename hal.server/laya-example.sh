#!/usr/bin/env bash
# Classify recipes as dinner | breakfast | snack | lunch | treat | dessert
# using the Laya choice question served by laya.cpp on hal (port 8001).
#
# Usage:
#   ./laya-example.sh "recipe text"           classify one recipe
#   ./laya-example.sh -f recipes.json         batch: JSON array of strings, or
#                                             [{"name": "...", "recipe": "..."}]
#   ./laya-example.sh -f recipe.txt           a plain-text file = one recipe
#   cat recipe.txt | ./laya-example.sh        one recipe from stdin
#
# Environment:
#   LAYA_URL   service base URL (default http://10.1.1.105:8001)
#
# Requires: curl, jq. The server admits 8 questions per HTTP call by default,
# so larger batches are automatically chunked at 8.
#
# Accuracy note: Laya classifies on the text in front of it. Recipes that
# state their context ("a breakfast of ...", "served after dinner") classify
# cleanly; context-free recipes fall back on flavor profile (pancakes with
# maple syrup -> dessert). When confidence is low, read the probability
# distribution rather than the single label.
set -euo pipefail

BASE="${LAYA_URL:-http://10.1.1.105:8001}"
CHUNK=8

die() { echo "error: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

# The single classification question: 6-way choice.
QUESTION='{"type":"choice",
           "criteria":["dinner","breakfast","snack","lunch","treat","dessert"],
           "instructions":"Which meal category does this recipe best fit? Choose exactly one."}'

# --- collect recipes into a JSON array of {name, recipe} ----------------------
recipes_file="$(mktemp)"; results_dir="$(mktemp -d)"
trap 'rm -f "$recipes_file"; rm -rf "$results_dir"' EXIT
printf '[]' > "$recipes_file"

add_recipe() { # $1=name (may be empty)  $2=recipe text
  jq --arg n "${1:-}" --arg r "$2" '. + [{name:$n, recipe:$r}]' \
    "$recipes_file" > "$recipes_file.tmp" && mv "$recipes_file.tmp" "$recipes_file"
}

if [[ ${1:-} == "-f" ]]; then
  [[ $# -eq 2 && -r "${2:-/nonexistent}" ]] || die "usage: $0 -f <file>"
  file="$2"
  if [[ "$(head -c100 "$file" | tr -d '[:space:]' | head -c1)" == "[" ]]; then
    # JSON array: strings or {name, recipe} objects
    while IFS= read -r obj; do
      add_recipe "$(jq -r '.name // ""' <<<"$obj")" "$(jq -r '.recipe' <<<"$obj")"
    done < <(jq -c '.[] | if type == "string" then {name:"", recipe:.}
                    else {name:(.name // ""), recipe:(.recipe // .text // "")} end' "$file")
  else
    add_recipe "$(basename "$file")" "$(cat "$file")"
  fi
elif [[ $# -eq 1 ]]; then
  add_recipe "" "$1"
else
  add_recipe "" "$(cat)"
fi

total="$(jq 'length' "$recipes_file")"
[[ "$total" -gt 0 ]] || die "no recipes to classify"

echo "classifying $total recipe(s) via $BASE"
echo

# --- send in chunks of $CHUNK, collect results in request order ---------------
for ((start = 0; start < total; start += CHUNK)); do
  body="$(jq -c --argjson q "$QUESTION" --argjson start "$start" --argjson chunk "$CHUNK" \
    ".[$start:\$start+\$chunk] | map({state: .recipe, questions: {meal_category: \$q}})" \
    "$recipes_file")"

  resp="$(curl -sS --fail-with-body "$BASE/predict" \
    -H 'Content-Type: application/json' -d "$body")"

  jq '.results' <<<"$resp" > "$results_dir/$(printf '%04d' "$start")"
done

# --- report --------------------------------------------------------------------
jq -r -n --slurpfile recs "$recipes_file" \
  --argjson res "$(jq -s 'add // []' "$results_dir"/*)" '
  $recs[0] as $R | $res as $A |
  [ range(0; $R | length) as $i
    | $A[$i].answers.meal_category as $m
    | (if ($R[$i].name // "") == ""
       then ($R[$i].recipe | gsub("[\n\r]+"; " ") | .[0:70])
       else $R[$i].name end) as $label
    | "── \($label)"
      + "\n   category:   \($m.choice)   (confidence \($m.confidence))"
      + "\n   probability: "
      + ($m.probabilities | to_entries | sort_by(-.value)
           | map("\(.key) \(.value)") | join("   "))
  ] | join("\n")'
