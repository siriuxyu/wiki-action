#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CodeNib Contributors
#
# SPDX-License-Identifier: Apache-2.0

# Decides where the Wiki goes. For deploy: auto it reads how the repository's
# Pages site is published; for deploy: branch it checks that Pages serves the
# branch and finds the folder and address the Wiki gets there.
#
# Inputs (environment): INPUT_DEPLOY, INPUT_BRANCH, INPUT_BASE_PATH,
# PATH_SET, WIKI_PATH, GH_TOKEN, and the runner's GITHUB_REPOSITORY,
# GITHUB_RUN_ID, GITHUB_SERVER_URL and RUNNER_TEMP. Writes
# deploy, and for branch also branch, branch_path, pages_root, base_path and
# site_url, to GITHUB_OUTPUT.
set -euo pipefail

fail() {
  echo "::error title=CodeNib Wiki::$1"
  exit 2
}

out() {
  echo "$1=$2" >> "$GITHUB_OUTPUT"
}

# Path part of a URL without the trailing slash: "" for a site at the root.
url_path() {
  local rest="${1#*://}"
  if [[ "$rest" == */* ]]; then
    rest="/${rest#*/}"
  else
    rest=""
  fi
  echo "${rest%/}"
}

# HTTP status of a URL, or 000 when it cannot be reached.
http_status() {
  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' --retry 2 --max-time 20 "$1" 2>/dev/null)" || true
  echo "${status:-000}"
}

# Whether the repository has a deployment from another run. A Pages deploy
# is recorded under its job's environment, and not at all when the job names
# none, so this alone cannot prove that nothing was deployed. A job that names
# an environment records a deployment as it starts; this run's are skipped.
has_deployments() {
  local ids id
  ids="$(gh api "repos/$GITHUB_REPOSITORY/deployments?per_page=20" --jq '.[].id' 2>"$err")" \
    || fail "Could not read the repository's deployments: $(head -n 1 "$err"). Grant the workflow deployments: read."
  for id in $ids; do
    if ! gh api "repos/$GITHUB_REPOSITORY/deployments/$id/statuses?per_page=100" \
      --jq '.[].log_url // empty' 2>/dev/null | grep -q "/actions/runs/${GITHUB_RUN_ID:-none}/"; then
      return 0
    fi
  done
  return 1
}

deploy="$INPUT_DEPLOY"
if [[ "$deploy" == pages || "$deploy" == none ]]; then
  out deploy "$deploy"
  exit 0
fi

# gh talks to the server the workflow runs on, GitHub Enterprise included.
export GH_HOST="${GITHUB_SERVER_URL:-https://github.com}"
GH_HOST="${GH_HOST#*://}"

# Read the Pages settings. Not Found means the repository has no Pages site.
# Fields are split on the unit separator, since tabs would merge empty ones.
err="${RUNNER_TEMP:?}/codenib-pages-settings.err"
build_type="" source_branch="" source_path="" html_url=""
if info="$(gh api "repos/$GITHUB_REPOSITORY/pages" \
  --jq '[.build_type, (.source.branch // ""), (.source.path // "/"), (.html_url // "")] | join("\u001f")' 2>"$err")"; then
  IFS=$'\x1f' read -r build_type source_branch source_path html_url <<<"$info"
elif ! grep -q 'HTTP 404' "$err"; then
  fail "Could not read the Pages settings: $(head -n 1 "$err"). Grant the workflow pages: read."
fi

if [[ "$deploy" == auto ]]; then
  if [[ -z "$build_type" ]]; then
    fail "This repository has no Pages site. Under Settings > Pages, choose GitHub Actions to publish the Wiki as the site, or Deploy from a branch to add it to that branch, then run the workflow again."
  elif [[ "$build_type" == workflow ]]; then
    # A workflow deploy replaces the whole site, so the Wiki can take it over
    # only if it is the Wiki already or nothing has been deployed: the site
    # root is missing and the repository has no deployment. A site without
    # a root page also answers 404 there, hence both checks.
    keep="A workflow deploy replaces the whole site, so this action cannot add the Wiki to it. Build the Wiki with deploy: none and add site-path to that deploy, or set deploy: pages to replace the site."
    if [[ "$(http_status "${html_url%/}/codenib-static.json")" == 200 ]]; then
      reason="the Pages site is already this Wiki"
      deploy=pages
    elif [[ "$(http_status "$html_url")" != 404 ]]; then
      fail "Pages is deployed by a workflow and already serves a site at $html_url. $keep"
    elif has_deployments; then
      fail "Pages is deployed by a workflow, and the repository has deployments, so $html_url may already serve a site without a root page. $keep"
    else
      reason="nothing has been deployed to Pages yet"
      deploy=pages
    fi
  else
    reason="Pages serves the $source_branch branch"
    deploy=branch
  fi
  if [[ "$deploy" == pages && ( "$PATH_SET" == true || -n "$INPUT_BASE_PATH" ) ]]; then
    fail "deploy: auto chose pages because $reason, which publishes the Wiki as the whole site; path and base-path apply only to a branch or none. Remove them, or set deploy: branch or none."
  fi
  echo "deploy: auto chose $deploy because $reason."
fi

out deploy "$deploy"
[[ "$deploy" == pages ]] && exit 0

# deploy: branch.
if [[ -z "$INPUT_BASE_PATH" ]]; then
  if [[ -z "$build_type" ]]; then
    fail "This repository has no Pages site. Under Settings > Pages, choose Deploy from a branch, or set base-path if another host serves the branch."
  elif [[ "$build_type" == workflow ]]; then
    fail "Pages is deployed by a workflow, so it does not serve a branch. Build the Wiki with deploy: none and add site-path to that deploy, or use deploy: pages."
  fi
fi

branch="${INPUT_BRANCH:-}"
served=false
if [[ "$build_type" == legacy ]]; then
  if [[ -z "$branch" || "$branch" == "$source_branch" ]]; then
    branch="$source_branch"
    served=true
  else
    echo "::warning title=CodeNib Wiki::Pages serves $source_branch, not $branch, so the Wiki appears only once Pages serves $branch."
  fi
fi
branch="${branch:-gh-pages}"

default_branch="$(gh api "repos/$GITHUB_REPOSITORY" --jq .default_branch)"
if [[ "$branch" == "$default_branch" ]]; then
  fail "$branch is the repository's default branch, and the action does not commit the built Wiki to it. Serve Pages from a separate branch such as gh-pages, or use deploy: none."
fi

# Pages can serve the branch's /docs folder as the site root.
pages_root=""
if [[ "$served" == true && "$source_path" == /docs ]]; then
  pages_root=docs
fi

if [[ -n "$INPUT_BASE_PATH" ]]; then
  base_path="${INPUT_BASE_PATH%/}"
  site_url=""
else
  base_path="$(url_path "$html_url")/$WIKI_PATH"
  site_url="${html_url%/}/$WIKI_PATH"
fi

out branch "$branch"
out branch_path "${pages_root:+$pages_root/}$WIKI_PATH"
out pages_root "$pages_root"
out base_path "$base_path"
out site_url "$site_url"
