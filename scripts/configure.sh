#!/usr/bin/env bash
#
# First-time setup for a repository created from the Go DevSecOps template.
#
# Stage 1 fills the template placeholders locally. Commit and push the result,
# then run again: stage 2 configures the GitHub repository through the API.
# Both stages are safe to re-run.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

BRANCHES=(prod pre-prod staging dev)
DEFAULT_BRANCH=prod
DEPLOY_KEY_TITLE=release-tags
KEY_DIR=""
trap '[ -z "$KEY_DIR" ] || rm -rf "$KEY_DIR"' EXIT
PLACEHOLDERS=(
  PROJECT_NAME
  BINARY_NAME
  GITHUB_ADDRESS
  OPENCONTAINERS_ADDRESS
  OPENCONTAINERS_DESCRIPTION
  OPENCONTAINERS_SOURCE
  OPENCONTAINERS_LICENSE_SHORT
  RELEASE_OWNER
)

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

# ask VAR PROMPT [DEFAULT] [REGEX] [HINT]
ask() {
  local __var=$1 prompt=$2 def=${3:-} re=${4:-} hint=${5:-} reply
  while true; do
    if [ -n "$def" ]; then
      read -rp "$prompt [$def]: " reply
    else
      read -rp "$prompt: " reply
    fi
    reply=${reply:-$def}
    if [ -z "$reply" ]; then
      echo "  A value is required."
      continue
    fi
    if [ -n "$re" ] && ! [[ $reply =~ $re ]]; then
      echo "  $hint"
      continue
    fi
    printf -v "$__var" '%s' "$reply"
    return
  done
}

# ask_secret VAR PROMPT. Input is hidden and may be blank.
ask_secret() {
  local __var=$1 reply
  read -rsp "$2: " reply
  echo
  printf -v "$__var" '%s' "$reply"
}

# confirm PROMPT [y|n]
confirm() {
  local def=${2:-n} reply hint="y/N"
  [ "$def" = y ] && hint="Y/n"
  read -rp "$1 [$hint]: " reply
  reply=${reply:-$def}
  [[ $reply =~ ^[Yy] ]]
}

# try DESCRIPTION COMMAND...: a failure warns rather than aborts.
try() {
  local what=$1
  shift
  if "$@" >/dev/null; then
    info "$what"
  else
    warn "$what failed. Set it by hand in the repository settings."
  fi
}

remote_slug() {
  local url
  url="$(git remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  case "$url" in
    git@github.com:*) echo "${url#git@github.com:}" ;;
    ssh://git@github.com/*) echo "${url#ssh://git@github.com/}" ;;
    https://github.com/*) echo "${url#https://github.com/}" ;;
    *) return 1 ;;
  esac
}

placeholder_files() {
  local pattern
  pattern="<($(IFS='|'; echo "${PLACEHOLDERS[*]}"))>"
  grep -rlIE \
    --exclude-dir=.git --exclude-dir=scripts --exclude-dir=bin --exclude-dir=dist --exclude-dir=tmp \
    --exclude=CHANGE-INSTRUCTIONS.md \
    -e "$pattern" . || true
}

needs_fill() {
  [ -d "cmd/<BINARY_NAME>" ] || [ -n "$(placeholder_files)" ]
}

sed_escape() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# Writes LICENSE from GitHub's licence API. Only the SPDX key is sent.
# shellcheck disable=SC2153
write_licence() {
  local spdx=$1 key body holder
  key="$(tr '[:upper:]' '[:lower:]' <<<"$spdx")"
  key="${key%-only}"
  key="${key%-or-later}"
  if ! body="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/licenses/$key" | jq -r .body)"; then
    warn "No licence text found for '$spdx'. Add a LICENSE file by hand; GoReleaser packages it."
    return
  fi
  if [[ $body == *"[fullname]"* ]]; then
    ask holder "Copyright holder for LICENSE" "$RELEASE_OWNER"
    body="${body//\[fullname\]/$holder}"
  fi
  body="${body//\[year\]/$(date +%Y)}"
  printf '%s\n' "$body" >LICENSE
  info "Wrote LICENSE ($spdx)"
}

stage_fill() {
  info "Stage 1: fill the template placeholders"
  echo

  local slug owner repo name value f
  slug="$(remote_slug || true)"
  ask slug "GitHub repository (owner/name)" "$slug" \
    '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' "Use the form owner/name."
  owner=${slug%%/*}
  repo=${slug#*/}

  ask PROJECT_NAME "Project name" "${repo//[-.]/_}" \
    '^[A-Za-z0-9_]+$' "Letters, digits and underscores only."
  ask BINARY_NAME "Binary name" "$(tr '[:upper:]_.' '[:lower:]--' <<<"$repo")" \
    '^[a-z0-9]+(-[a-z0-9]+)*$' "Lowercase letters, digits and single dashes only."
  ask OPENCONTAINERS_DESCRIPTION "One-line description" "" \
    '^[^"\\]+$' 'Must not contain " or \.'
  ask OPENCONTAINERS_LICENSE_SHORT "Licence as an SPDX identifier, e.g. AGPL-3.0-only" "" \
    '^[A-Za-z0-9.+-]+$' "See https://spdx.org/licenses/"
  ask RELEASE_OWNER "GitHub user allowed to tag and release" "$owner" \
    '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' "A GitHub username, without @."

  # Read indirectly through ${!name} below.
  # shellcheck disable=SC2034
  GITHUB_ADDRESS="github.com/$slug"
  # shellcheck disable=SC2034
  OPENCONTAINERS_SOURCE="https://$GITHUB_ADDRESS"
  # shellcheck disable=SC2034
  OPENCONTAINERS_ADDRESS="ghcr.io/${slug,,}"

  echo
  for name in "${PLACEHOLDERS[@]}"; do
    printf '  %-30s %s\n' "$name" "${!name}"
  done
  echo
  confirm "Write these values into the template?" y || die "Aborted. Nothing was changed."

  local -a expr=()
  for name in "${PLACEHOLDERS[@]}"; do
    value="$(sed_escape "${!name}")"
    expr+=(-e "s|<$name>|$value|g")
  done
  while IFS= read -r f; do
    sed -i "${expr[@]}" "$f"
    info "Filled $f"
  done < <(placeholder_files)

  if [ -d "cmd/<BINARY_NAME>" ]; then
    mv "cmd/<BINARY_NAME>" "cmd/$BINARY_NAME"
    info "Renamed cmd/<BINARY_NAME> to cmd/$BINARY_NAME"
  fi

  [ -f LICENSE ] || write_licence "$OPENCONTAINERS_LICENSE_SHORT"

  cat <<EOF

Review the changes, then commit them signed and push:

  git add -A
  git commit -S -m "Configure from template"
  git push origin HEAD

Then run \`make configure\` again to configure GitHub.

EOF
}

print_token_help() {
  cat <<EOF

Create a fine-grained token at https://github.com/settings/personal-access-tokens/new

  Resource owner:     ${1%%/*}
  Expiration:         1 day
  Repository access:  Only select repositories, ${1#*/}
  Permissions:        Administration, Contents, Environments, Secrets (Read and write)

The token stays in memory for this run only and is never written to disk.
Delete it once configuration finishes.

EOF
}

# add_policies ENVIRONMENT: limits deployments to prod, pre-prod and version tags.
add_policies() {
  local env=$1 existing entry
  existing="$(gh api "repos/$SLUG/environments/$env/deployment-branch-policies" --jq '.branch_policies[].name')"
  for entry in branch:prod branch:pre-prod 'tag:v*'; do
    grep -qxF "${entry#*:}" <<<"$existing" && continue
    gh api "repos/$SLUG/environments/$env/deployment-branch-policies" \
      -f name="${entry#*:}" -f type="${entry%%:*}" --silent
  done
}

apply_ruleset() {
  local file=$1 body name id
  body="$(cat "$file")"
  if [ "$(basename "$file")" = pr-review.json ]; then
    body="$(jq --argjson n "$APPROVALS" --argjson solo "$SOLO" '
      .rules |= map(
        if .type == "pull_request" then
          .parameters.required_approving_review_count = $n
          | if $solo then
              .parameters.require_code_owner_review = false
              | .parameters.require_last_push_approval = false
            else . end
        else . end)' <<<"$body")"
  fi
  name="$(jq -r .name <<<"$body")"
  id="$(awk -F'\t' -v n="$name" '$2 == n { print $1 }' <<<"$RULESETS")"
  if [ -n "$id" ]; then
    gh api -X PUT "repos/$SLUG/rulesets/$id" --input - --silent <<<"$body"
    info "Updated ruleset: $name"
  else
    gh api -X POST "repos/$SLUG/rulesets" --input - --silent <<<"$body"
    info "Created ruleset: $name"
  fi
}

stage_github() {
  command -v gh >/dev/null || die "gh missing. Install github-cli (pacman) or gh (apt)."
  command -v jq >/dev/null || die "jq missing."
  command -v ssh-keygen >/dev/null || die "ssh-keygen missing. It generates the release deploy key."

  SLUG="$(remote_slug)" || die "origin is not a GitHub remote."
  confirm "Configure GitHub settings, rulesets and secrets for $SLUG?" y || return 0

  [ -z "$(git status --porcelain)" ] || die "Commit and push local changes first, so GitHub has the configured template."
  local sha
  sha="$(git rev-parse HEAD)"

  local release_owner
  release_owner="$(sed -n 's|^/\.github/ *@||p' .github/CODEOWNERS)"
  [ -n "$release_owner" ] || die "Could not read the release owner from CODEOWNERS. Was stage 1 completed?"

  print_token_help "$SLUG"
  local token
  ask_secret token "Token"
  [ -n "$token" ] || die "A token is required."
  export GH_TOKEN="$token" GH_PROMPT_DISABLED=1

  local repo_json visibility owner_type old_default
  repo_json="$(gh api "repos/$SLUG")" || die "The token cannot read $SLUG."
  visibility="$(jq -r .visibility <<<"$repo_json")"
  owner_type="$(jq -r .owner.type <<<"$repo_json")"
  old_default="$(jq -r .default_branch <<<"$repo_json")"
  gh api "repos/$SLUG/commits/$sha" --silent 2>/dev/null || die "HEAD ($sha) is not on GitHub. Push it first."

  echo
  SOLO=false
  APPROVALS=1
  if confirm "Is this a solo project? Pull requests stay mandatory but need no approval, and you accept the risk of working without a second reviewer."; then
    SOLO=true
    APPROVALS=0
  else
    ask APPROVALS "Approvals required per pull request" 1 '^[1-9]$' "A number from 1 to 9."
  fi

  local delete_old=false
  if [[ " ${BRANCHES[*]} " != *" $old_default "* ]] &&
    confirm "Delete the current default branch '$old_default' once $DEFAULT_BRANCH exists?"; then
    delete_old=true
  fi

  local claude_token gitleaks_licence=""
  echo "Release notes need a Claude Code OAuth token. Create one with: claude setup-token"
  ask_secret claude_token "Claude Code OAuth token (blank to skip)"
  if [ "$owner_type" = Organization ]; then
    echo "gitleaks-action needs a free licence key for organisation repositories, from https://gitleaks.io"
    ask_secret gitleaks_licence "gitleaks licence key (blank to skip)"
  fi

  local default_note="$DEFAULT_BRANCH" claude_note=skipped
  $delete_old && default_note+=", deleting $old_default"
  [ -z "$claude_token" ] || claude_note="set"

  cat <<EOF

  Repository:       $SLUG ($visibility)
  Branches:         ${BRANCHES[*]}, created at ${sha:0:12}
  Default branch:   $default_note
  Solo:             $SOLO, $APPROVALS approval(s) per pull request
  Release owner:    $release_owner
  Claude token:     $claude_note

EOF
  confirm "Apply?" y || die "Aborted. Nothing was changed on GitHub."

  local b
  for b in "${BRANCHES[@]}"; do
    if gh api "repos/$SLUG/git/ref/heads/$b" --silent 2>/dev/null; then
      info "Branch $b exists"
    else
      gh api "repos/$SLUG/git/refs" -f ref="refs/heads/$b" -f sha="$sha" --silent
      info "Created branch $b"
    fi
  done

  # Merge commits only: squash or rebase would diverge the promotion branches.
  gh api -X PATCH "repos/$SLUG" --silent \
    -f default_branch="$DEFAULT_BRANCH" \
    -F allow_merge_commit=true \
    -F allow_squash_merge=false \
    -F allow_rebase_merge=false \
    -F allow_auto_merge=false
  info "Default branch $DEFAULT_BRANCH, merge commits only"

  # Before the rulesets, which forbid deleting it.
  if $delete_old; then
    gh api -X DELETE "repos/$SLUG/git/refs/heads/$old_default" --silent
    info "Deleted branch $old_default"
  fi

  try "Dependabot alerts on" gh api -X PUT "repos/$SLUG/vulnerability-alerts" --silent
  try "Dependabot security updates off" gh api -X DELETE "repos/$SLUG/automated-security-fixes" --silent
  try "Private vulnerability reporting on" gh api -X PUT "repos/$SLUG/private-vulnerability-reporting" --silent
  try "Secret scanning and push protection on" gh api -X PATCH "repos/$SLUG" --silent --input - <<<'{
    "security_and_analysis": {
      "secret_scanning": { "status": "enabled" },
      "secret_scanning_push_protection": { "status": "enabled" }
    }
  }'
  # The CodeQL job in ci.yml cannot upload while default setup is on.
  try "CodeQL default setup off" gh api -X PATCH "repos/$SLUG/code-scanning/default-setup" -f state=not-configured --silent
  try "Workflow token read-only, cannot approve pull requests" \
    gh api -X PUT "repos/$SLUG/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false --silent

  local owner_id policy
  owner_id="$(gh api "users/$release_owner" --jq .id)"
  policy='{"protected_branches": false, "custom_branch_policies": true}'
  gh api -X PUT "repos/$SLUG/environments/release" --silent --input - \
    <<<"$(jq -n --argjson p "$policy" '{deployment_branch_policy: $p}')"
  add_policies release
  info "Environment release"
  # Required reviewers are unavailable on private repositories without a paid plan.
  if gh api -X PUT "repos/$SLUG/environments/release-major" --silent --input - \
    <<<"$(jq -n --argjson p "$policy" --argjson id "$owner_id" \
      '{reviewers: [{type: "User", id: $id}], prevent_self_review: false, deployment_branch_policy: $p}')"; then
    add_policies release-major
    info "Environment release-major, approved by $release_owner"
  else
    warn "Environment release-major failed. Create it by hand with $release_owner as a required reviewer."
  fi

  # Secret first: if adding the key then fails, a re-run regenerates both.
  if [ -n "$(gh api "repos/$SLUG/keys" --jq ".[] | select(.title == \"$DEPLOY_KEY_TITLE\") | .id")" ]; then
    info "Deploy key $DEPLOY_KEY_TITLE exists. Delete it under Settings > Deploy keys to rotate."
  else
    KEY_DIR="$(mktemp -d)"
    ssh-keygen -q -t ed25519 -N '' -C "$SLUG $DEPLOY_KEY_TITLE" -f "$KEY_DIR/key"
    gh secret set RELEASE_DEPLOY_KEY --repo "$SLUG" --env release <"$KEY_DIR/key"
    gh api "repos/$SLUG/keys" --silent \
      -f title="$DEPLOY_KEY_TITLE" -f key="$(cat "$KEY_DIR/key.pub")" -F read_only=false
    rm -rf "$KEY_DIR"
    info "Deploy key $DEPLOY_KEY_TITLE, private half stored as RELEASE_DEPLOY_KEY"
  fi

  if [ -n "$claude_token" ]; then
    printf '%s' "$claude_token" | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$SLUG" --env release
    info "Secret CLAUDE_CODE_OAUTH_TOKEN"
  fi
  if [ -n "$gitleaks_licence" ]; then
    printf '%s' "$gitleaks_licence" | gh secret set GITLEAKS_LICENSE --repo "$SLUG"
    info "Secret GITLEAKS_LICENSE"
  fi

  RULESETS="$(gh api "repos/$SLUG/rulesets" --paginate \
    --jq '.[] | select(.source_type == "Repository") | [.id, .name] | @tsv')"
  local file
  for file in .github/rulesets/*.json; do
    apply_ruleset "$file"
  done

  echo
  info "GitHub configured."
  if [ "$visibility" != public ]; then
    warn "$SLUG is $visibility. CodeQL, dependency review and SARIF upload need GitHub Advanced Security,"
    warn "and Scorecard cannot publish results. Without them those required checks fail."
  fi
  cat <<EOF

Delete the token now: https://github.com/settings/personal-access-tokens

Pull requests open against $DEFAULT_BRANCH by default. Set the base to dev for issue branches.

EOF
}

if needs_fill; then
  stage_fill
else
  stage_github
fi
