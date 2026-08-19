#!/usr/bin/env bash
# Wayline preflight — run BEFORE the first `git push` of the application source.
#
# Why this exists: commit fed1619 published a real .env (Postgres password,
# SESSION_SECRET, seed login) to a public repo. It was uploaded through GitHub's
# web uploader, which ignores .gitignore. This script is the guard so that
# cannot happen a second time.
#
# Usage, from the repo root on the machine holding the source:
#     bash scripts/preflight-push.sh
#
# Exit 0 = safe to push. Exit 1 = do not push, read the output.

set -uo pipefail

FAIL=0
WARN=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

fail() { red   "  FAIL  $*"; FAIL=$((FAIL+1)); }
warn() { yellow"  WARN  $*" 2>/dev/null || yellow "  WARN  $*"; WARN=$((WARN+1)); }
ok()   { green "  ok    $*"; }

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { red "Not inside a git repository."; exit 1; }

bold ""
bold "Wayline preflight — $(pwd)"
bold "================================================================"

# ---------------------------------------------------------------- 1. gitignore
bold ""
bold "1. .gitignore is present and covers secrets"
if [ ! -f .gitignore ]; then
  fail ".gitignore is missing — DO NOT run 'git add -A' until it is restored."
else
  ok ".gitignore present"
  for pat in '.env' 'node_modules' '*.csv' '*.xlsx'; do
    if grep -qF -- "$pat" .gitignore; then
      ok "covers $pat"
    else
      fail ".gitignore does not mention $pat"
    fi
  done
fi

# ------------------------------------------------------- 2. secrets not tracked
bold ""
bold "2. No real environment files are tracked or staged"
TRACKED_ENV=$(git ls-files | grep -E '(^|/)\.env' | grep -vE '\.example$' || true)
if [ -n "$TRACKED_ENV" ]; then
  fail "real env file(s) tracked by git:"
  printf '          %s\n' $TRACKED_ENV
  echo   "          Fix:  git rm --cached <file>"
else
  ok "no real .env files tracked"
fi

STAGED_ENV=$(git diff --cached --name-only | grep -E '(^|/)\.env' | grep -vE '\.example$' || true)
if [ -n "$STAGED_ENV" ]; then
  fail "real env file(s) STAGED for commit:"
  printf '          %s\n' $STAGED_ENV
else
  ok "no real .env files staged"
fi

# ------------------------------------------------------------- 3. customer PII
bold ""
bold "3. No customer data (Brian's account book is PII)"
PII=$(git ls-files | grep -iE '\.(csv|xlsx|xls)$|Account List' || true)
if [ -n "$PII" ]; then
  fail "customer-data file(s) tracked:"
  printf '          %s\n' $PII
else
  ok "no CSV/XLSX/account-list files tracked"
fi

# -------------------------------------------------------------- 4. build junk
bold ""
bold "4. No build output or dependencies committed"
JUNK=$(git ls-files | grep -E '^(node_modules|\.next|out|build|generated|coverage)/' | head -5 || true)
if [ -n "$JUNK" ]; then
  fail "build/dependency paths tracked (showing first 5):"
  printf '          %s\n' $JUNK
else
  ok "no node_modules / .next / generated / coverage tracked"
fi

# ------------------------------------------------ 5. entropy scan of tracked text
bold ""
bold "5. High-entropy strings in tracked files"
HITS=$(git grep -nIE \
  '(SESSION_SECRET|POSTGRES_PASSWORD|SEED_USER_PASSWORD|DATABASE_URL)[[:space:]]*=[[:space:]]*["'"'"']?[A-Za-z0-9/+_.:@-]{16,}' \
  -- . ':(exclude).env.example' ':(exclude).env.production.example' 2>/dev/null \
  | grep -vE '(change_me|replace_with|set_a_strong|placeholder|example\.com|<|\$\{|process\.env)' || true)
if [ -n "$HITS" ]; then
  fail "possible real secret(s) in tracked files:"
  printf '          %s\n' "$HITS"
else
  ok "no obvious hard-coded secrets in tracked files"
fi

# ------------------------------------------------------------ 6. completeness
bold ""
bold "6. Application source is actually present"
MISSING=""
for d in app components lib prisma; do
  if [ -d "$d" ]; then ok "$d/ present"; else fail "$d/ MISSING"; MISSING="yes"; fi
done
for d in tests public; do
  if [ -d "$d" ]; then ok "$d/ present"; else warn "$d/ missing"; fi
done
if [ -f prisma/schema.prisma ]; then
  ok "prisma/schema.prisma present (this is what switches CI to full verification)"
else
  fail "prisma/schema.prisma MISSING — CI will stay in skip mode"
fi

# ------------------------------------------------------------------- 7. summary
bold ""
bold "================================================================"
if [ "$FAIL" -gt 0 ]; then
  red "PREFLIGHT FAILED — $FAIL problem(s), $WARN warning(s). Do not push."
  exit 1
fi
green "PREFLIGHT PASSED — $WARN warning(s). Safe to commit and push."
bold ""
echo "Next:  git add -A && git status   # eyeball the list one last time"
echo "       git commit -m 'Add application source (Sessions 1-6)'"
echo "       git push -u origin main"
exit 0
