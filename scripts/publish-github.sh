#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: ./scripts/publish-github.sh OWNER/REPOSITORY' >&2; exit 2; }
[[ $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Expected OWNER/REPOSITORY' >&2; exit 2; }
command -v gh >/dev/null || { echo 'Install GitHub CLI (gh) first' >&2; exit 1; }
gh auth status >/dev/null || { echo 'Run gh auth login first' >&2; exit 1; }
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
if [[ ! -e .git ]]; then
    git init -b main
fi
[[ $(git rev-parse --show-toplevel) == "$PROJECT_DIR" ]] || { echo 'Repository root differs from project directory' >&2; exit 1; }
if [[ -n $(git status --porcelain) ]] || ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    git add --all
    git -c user.name='Kundan Kumar' -c user.email='kundan.kumar@samsung.com' commit -m 'Add UVP web UI and two-host orchestrator' --signoff
fi
if git remote get-url origin >/dev/null 2>&1; then
    echo 'An origin remote already exists; inspect it and push explicitly.' >&2
    exit 1
fi
gh repo create "$1" --private --source=. --remote=origin --push
