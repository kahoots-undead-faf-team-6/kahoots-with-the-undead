#!/usr/bin/env bash
# Usage: ./push-to-github.sh https://github.com/<ORG>/kahoots-with-the-undead.git
set -e
URL="$1"
if [ -z "$URL" ]; then echo "Usage: $0 <repo-url>"; exit 1; fi
git init -b main
git add .
git commit -m "chore: initial CPR structure, README, PR template"
git remote add origin "$URL"
git push -u origin main
git checkout -b development
git push -u origin development
echo "Done: main and development pushed."
