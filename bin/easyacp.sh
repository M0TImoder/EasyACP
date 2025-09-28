#!/usr/bin/env bash

mode='name-only'
add_mode='all'
do_rebase=0
force_push=0
run_gc=0
all_accept=0
confirm_stage_prompt=1
confirm_post_stage_prompt=1
confirm_tag_prompt=1
confirm_commit_prompt=1
confirm_push_prompt=1
stash_created=0
stash_applied=0
stash_ref='stash^{/easyacp-auto}'
use_template=0
use_editor=0
gpg_sign=0
signoff=0
message_provided=0
prev_head=''
trap_set=0
template_path="$HOME/.gitmessage"

# --- color configuration -------------------------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  color_count=$(tput colors 2>/dev/null || printf '0')
else
  color_count=0
fi

if [ "${color_count:-0}" -ge 8 ]; then
  BOLD=$(tput bold)
  RESET=$(tput sgr0)
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  MAGENTA=$(tput setaf 5)
  CYAN=$(tput setaf 6)
else
  BOLD=''
  RESET=''
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  MAGENTA=''
  CYAN=''
fi

info() {
  printf '%b%s%b\n' "${CYAN}${BOLD}" "$1" "$RESET"
}

success() {
  printf '%b%s%b\n' "${GREEN}${BOLD}" "$1" "$RESET"
}

warn() {
  printf '%b%s%b\n' "${YELLOW}${BOLD}" "$1" "$RESET" >&2
}

error() {
  printf '%b%s%b\n' "${RED}${BOLD}" "$1" "$RESET" >&2
}

print_usage() {
  cat <<'USAGE'
Usage: git easyacp [options] "commit message"
Options:
  -fd | -fulldiff     Show full diff instead of names
  -rebase             Pull with rebase/autostash
  -p                  Patch-based staging
  -s                  GPG sign
  -so | --signoff     Add Signed-off-by line
  -t                  Use commit template
  -v | -vim           Use editor for commit
  -f                  Force push with --force-with-lease
  -gc                 Run git gc --auto and git maintenance run --auto after push
  -h | -help | --help Show this message and exit
USAGE
}

cleanup() {
  if [ "$stash_created" -eq 1 ]; then
    if [ "$stash_applied" -eq 0 ]; then
      if git stash apply "$stash_ref" >/dev/null 2>&1; then
        stash_applied=1
      fi
    fi
    git stash drop "$stash_ref" >/dev/null 2>&1
  fi
}

safe_exit() {
  local status=$1
  if [ $trap_set -eq 1 ]; then
    trap - EXIT
  fi
  cleanup
  exit $status
}

trim_spaces() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

prompt_confirm() {
  local prompt="$1"
  local default_yes=${2:-1}
  local suffix
  local default_reply
  local reply

  if [ "$default_yes" -eq 1 ]; then
    suffix=" [${BOLD}Y${RESET}${MAGENTA}${BOLD}/${BOLD}n${RESET}${MAGENTA}${BOLD}]: "
    default_reply='y'
  else
    suffix=" [${BOLD}y${RESET}${MAGENTA}${BOLD}/${BOLD}N${RESET}${MAGENTA}${BOLD}]: "
    default_reply='n'
  fi

  while :; do
    printf '%b%s%b' "${MAGENTA}${BOLD}" "$prompt$suffix" "$RESET"
    read -r reply
    if [ -z "$reply" ]; then
      reply=$default_reply
    fi
    case "$reply" in
      [Yy])
        return 0
        ;;
      [Nn])
        return 1
        ;;
      *)
        warn 'Please answer with y or n.'
        ;;
    esac
  done
}

confirm_decision() {
  local flag=$1
  local default_yes=$2
  shift 2
  local prompt="$*"

  if [ "$all_accept" -eq 1 ] || [ "$flag" -ne 1 ]; then
    if [ "$default_yes" -eq 1 ]; then
      return 0
    else
      return 1
    fi
  fi

  if prompt_confirm "$prompt" "$default_yes"; then
    return 0
  else
    return 1
  fi
}

dedupe_alias_args() {
  local args=("$@")
  local total=${#args[@]}
  if [ $total -gt 0 ] && [ $(( total % 2 )) -eq 0 ]; then
    local half=$(( total / 2 ))
    local i
    for (( i=0; i<half; i++ )); do
      if [ "${args[i]}" != "${args[i+half]}" ]; then
        DEDUPED_ARGS=("${args[@]}")
        return
      fi
    done
    args=("${args[@]:0:half}")
  fi
  DEDUPED_ARGS=("${args[@]}")
}

dedupe_alias_args "$@"
if [ ${#DEDUPED_ARGS[@]} -gt 0 ]; then
  set -- "${DEDUPED_ARGS[@]}"
else
  set --
fi

while [ $# -gt 0 ]; do
  case "$1" in
    -h|-help|--help)
      print_usage
      exit 0
      ;;
    -fd|-fulldiff)
      mode='full'
      shift
      continue
      ;;
    -s|-sign)
      gpg_sign=1
      shift
      continue
      ;;
    -so|-signoff|--signoff)
      signoff=1
      shift
      continue
      ;;
    -t)
      use_template=1
      shift
      continue
      ;;
    -rebase)
      do_rebase=1
      shift
      continue
      ;;
    -p)
      add_mode='patch'
      shift
      continue
      ;;
    -f)
      force_push=1
      shift
      continue
      ;;
    -gc)
      run_gc=1
      shift
      continue
      ;;
    -v|-vim)
      use_editor=1
      shift
      continue
      ;;
    --)
      shift
      break
      ;;
    -*)
      warn "Unknown option '$1'."
      print_usage >&2
      safe_exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -gt 0 ]; then
  message_provided=1
fi

if [ "$use_editor" -eq 1 ]; then
  if [ "$message_provided" -eq 1 ]; then
    warn 'Discarding provided commit message because -v/-vim was specified; the editor will be opened.'
  fi
  commit_msg=''
else
  if [ $# -eq 0 ]; then
    print_usage >&2
    safe_exit 1
  fi
  commit_msg="$@"
fi

stash_output=$(git stash push -k -u -m easyacp-auto 2>&1)
stash_status=$?
if [ $stash_status -ne 0 ]; then
  error "$stash_output"
  safe_exit $stash_status
fi

if ! printf '%s' "$stash_output" | grep -q 'No local changes to save'; then
  stash_created=1
  trap cleanup EXIT
  trap_set=1
fi

if ! git fetch --all --prune --tags; then
  error 'git fetch --all --prune --tags failed.'
  safe_exit 1
fi

if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  error 'No upstream tracking branch is configured. Please set an upstream (e.g., git branch --set-upstream-to) before running easyacp.'
  safe_exit 1
fi

divergence_output=$(git rev-list --left-right --count @{u}...HEAD 2>/dev/null)
if [ $? -ne 0 ]; then
  error 'Unable to determine divergence from upstream.'
  safe_exit 1
fi

IFS=$'\t' read -r upstream_only local_only <<EOF
$divergence_output
EOF

info "Commits only on upstream: ${upstream_only:-0}"
info "Commits only on local HEAD: ${local_only:-0}"

if [ "$do_rebase" -eq 1 ]; then
  if ! git pull --rebase --autostash --ff-only; then
    error 'Fast-forward pull with rebase/autostash failed.'
    while :; do
      printf '%bChoose how to continue: [r]ebase / [m]erge / [a]bort:%b ' "${BLUE}${BOLD}" "$RESET"
      read -r pull_choice
      case "$pull_choice" in
        [Rr])
          if git pull --rebase --autostash; then
            break
          else
            error 'Rebase pull failed.'
            safe_exit 1
          fi
          ;;
        [Mm])
          if git pull --autostash; then
            break
          else
            error 'Merge pull failed.'
            safe_exit 1
          fi
          ;;
        [Aa]|'')
          warn 'Pull aborted.'
          safe_exit 1
          ;;
        *)
          warn 'Please enter r, m, or a.'
          ;;
      esac
    done
  fi
else
  if ! git pull --ff-only; then
    error 'Fast-forward pull failed.'
    safe_exit 1
  fi
fi

if [ "$stash_created" -eq 1 ] && [ "$stash_applied" -eq 0 ]; then
  if git stash apply "$stash_ref" >/dev/null 2>&1; then
    stash_applied=1
  else
    error 'Failed to reapply stashed changes.'
    safe_exit 1
  fi
fi

if ! git status -sb; then
  error 'git status -sb failed.'
  safe_exit 1
fi

git diff --quiet
diff_status=$?
if [ $diff_status -ne 0 ] && [ $diff_status -ne 1 ]; then
  safe_exit $diff_status
fi

git diff --cached --quiet
cached_status=$?
if [ $cached_status -ne 0 ] && [ $cached_status -ne 1 ]; then
  safe_exit $cached_status
fi

if [ $diff_status -eq 0 ] && [ $cached_status -eq 0 ]; then
  success 'No changes to commit.'
  safe_exit 0
fi

if [ "$mode" = 'full' ]; then
  if [ $diff_status -eq 1 ]; then
    info 'Working tree changes:'
    git diff
  else
    info 'No unstaged changes detected.'
  fi
else
  if [ $diff_status -eq 1 ]; then
    info 'Files with unstaged changes:'
    git diff --name-only
  else
    info 'No unstaged files detected.'
  fi
fi

if ! confirm_decision "$confirm_stage_prompt" 1 'Stage changes before continuing?'; then
  warn 'Operation cancelled.'
  safe_exit 0
fi

if [ "$add_mode" = 'patch' ]; then
  if ! git add -p; then
    status=$?
    safe_exit $status
  fi
else
  if ! git add -A; then
    status=$?
    safe_exit $status
  fi
fi

if [ "$mode" = 'full' ]; then
  info 'Staged changes:'
  git diff --cached
else
  info 'Staged file list:'
  git diff --cached --name-only
fi

if ! confirm_decision "$confirm_post_stage_prompt" 1 'Continue with these staged changes?'; then
  warn 'Operation cancelled after staging.'
  safe_exit 0
fi

tag_list=()

if confirm_decision "$confirm_tag_prompt" 1 'Add tags to this commit before pushing?'; then
  printf '%bEnter tags separated by commas (e.g., tag1, tag2):%b ' "${BLUE}${BOLD}" "$RESET"
  IFS= read -r raw_tags
  if [ -n "$raw_tags" ]; then
    IFS=',' read -r -a split_tags <<<"$raw_tags"
    for raw_tag in "${split_tags[@]}"; do
      trimmed=$(trim_spaces "$raw_tag")
      if [ -n "$trimmed" ]; then
        tag_list+=("$trimmed")
      fi
    done
  fi
fi
tag_count=${#tag_list[@]}

if [ "$use_editor" -eq 0 ]; then
  info 'Commit message preview:'
  printf '%s\n' "$commit_msg"
else
  info 'Commit message will be edited interactively.'
fi

if ! confirm_decision "$confirm_commit_prompt" 1 'Proceed with commit?'; then
  warn 'Commit cancelled.'
  safe_exit 0
fi

prev_head=$(git rev-parse HEAD 2>/dev/null)
if [ $? -ne 0 ]; then
  prev_head=''
fi

set -- git commit
if [ "$gpg_sign" -eq 1 ]; then
  set -- "$@" --gpg-sign
fi
if [ "$signoff" -eq 1 ]; then
  set -- "$@" --signoff
fi
if [ "$use_template" -eq 1 ]; then
  set -- "$@" -t "$template_path" --verbose
fi
if [ "$use_editor" -eq 0 ]; then
  set -- "$@" -m "$commit_msg"
fi

"$@" || {
  status=$?
  safe_exit $status
}

if [ $tag_count -gt 0 ]; then
  commit_subject=$(git log -1 --pretty=%s 2>/dev/null)
  for tag_name in "${tag_list[@]}"; do
    tag_message="$commit_subject"
    if [ -z "$tag_message" ]; then
      tag_message="Tag $tag_name created by easyacp"
    fi
    if ! git tag -m "$tag_message" "$tag_name"; then
      error "Failed to create tag '$tag_name'."
      safe_exit 1
    fi
  done
fi

if [ -n "$prev_head" ]; then
  push_diff_target="$prev_head"
else
  push_diff_target=$(git hash-object -t tree /dev/null)
fi

if [ "$mode" = 'full' ]; then
  info 'Diff of new commit against previous HEAD:'
  git diff --cached "$push_diff_target"
else
  info 'Files changed in new commit:'
  git diff --cached --name-only "$push_diff_target"
fi

if ! confirm_decision "$confirm_push_prompt" 1 'Push the new commit to the remote?'; then
  warn 'Push cancelled.'
  safe_exit 0
fi

if ! git fetch origin --prune --tags; then
  error 'Failed to fetch from origin before push.'
  safe_exit 1
fi

if ! git pull --rebase --autostash --ff-only; then
  error 'Fast-forward pull with rebase/autostash before push failed.'
  while :; do
    printf '%bChoose how to continue: [r]ebase / [m]erge / [a]bort:%b ' "${BLUE}${BOLD}" "$RESET"
    read -r push_pull_choice
    case "$push_pull_choice" in
      [Rr])
        if git pull --rebase --autostash; then
          break
        else
          error 'Rebase pull failed.'
          safe_exit 1
        fi
        ;;
      [Mm])
        if git pull --autostash; then
          break
        else
          error 'Merge pull failed.'
          safe_exit 1
        fi
        ;;
      [Aa]|'')
        warn 'Pull aborted.'
        safe_exit 1
        ;;
      *)
        warn 'Please enter r, m, or a.'
        ;;
    esac
  done
fi

push_cmd=(git push)
if [ $force_push -eq 1 ]; then
  push_cmd+=(--force-with-lease)
fi
if ! "${push_cmd[@]}"; then
  error 'git push failed.'
  safe_exit 1
fi

if ! git push --tags; then
  error 'git push --tags failed.'
  safe_exit 1
fi

if [ $run_gc -eq 1 ]; then
  info 'Running repository maintenance (git gc --auto)...'
  if ! git gc --auto; then
    error 'git gc --auto failed.'
    safe_exit 1
  fi
  info 'Running repository maintenance (git maintenance run --auto)...'
  if ! git maintenance run --auto; then
    error 'git maintenance run --auto failed.'
    safe_exit 1
  fi
fi

if [ $trap_set -eq 1 ]; then
  trap - EXIT
fi
cleanup
success 'Workflow completed successfully.'
