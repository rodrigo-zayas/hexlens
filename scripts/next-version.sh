#!/bin/bash
# Calcula la siguiente versión a partir de los conventional commits desde el último tag vX.Y.Z.
#   tipo!: o BREAKING CHANGE → major, feat → minor, fix/perf → patch.
# Imprime la versión sin "v", o nada si no hay nada que publicar. Sin tags previos, 0.1.0.
set -euo pipefail

last=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
if [[ -z "$last" ]]; then
  echo 0.1.0
  exit 0
fi

IFS=. read -r major minor patch <<<"${last#v}"

breaking_re='^[a-z]+(\([^)]*\))?!:'
feat_re='^feat(\([^)]*\))?:'
fix_re='^(fix|perf)(\([^)]*\))?:'

bump=""
while IFS= read -r -d $'\x1e' msg; do
  msg="${msg#$'\n'}"
  subject="${msg%%$'\n'*}"
  if [[ "$subject" =~ $breaking_re || "$msg" == *"BREAKING CHANGE"* ]]; then
    bump=major
    break
  elif [[ "$subject" =~ $feat_re ]]; then
    bump=minor
  elif [[ "$subject" =~ $fix_re && -z "$bump" ]]; then
    bump=patch
  fi
done < <(git log --no-merges --format='%B%x1e' "$last..HEAD")

case "$bump" in
  major) echo "$((major + 1)).0.0" ;;
  minor) echo "$major.$((minor + 1)).0" ;;
  patch) echo "$major.$minor.$((patch + 1))" ;;
esac
