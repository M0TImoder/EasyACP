#!/usr/bin/env bash

mode='name-only'
add_mode='all'
do_rebase=0
force_push=0
run_gc=0
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

if [ $# -gt 0 ] && [ $(( $# % 2 )) -eq 0 ]; then
  half=$(( $# / 2 ))
  i=1
  dedup_ok=1
  while [ $i -le $half ]; do
    eval "first=\${$i}"
    eval "second=\${$(( i + half ))}"
    if [ "${first-}" != "${second-}" ]; then
      dedup_ok=0
      break
    fi
    i=$(( i + 1 ))
  done
  if [ $dedup_ok -eq 1 ]; then
    set -- "${@:1:half}"
  fi
fi

print_usage() {
  echo 'Usage: git easyacp [options] "commit message"'
  echo 'Options:'
  echo '  -fd | -fulldiff     Show full diff instead of names'
  echo '  -rebase             Pull with rebase/autostash'
  echo '  -p                  Patch-based staging'
  echo '  -s                  GPG sign'
  echo '  -so | --signoff     Add Signed-off-by line'
  echo '  -t                  Use commit template'
  echo '  -v | -vim           Use editor for commit'
  echo '  -gc                 Run git gc --auto and git maintenance run --auto after push'
  echo '  -h | -help | --help Show this message and exit'
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

while [ $# -gt 0 ]; do
  case "$1" in
    -h|-help|--help)
      print_usage
      exit 0
      ;;
    -fd|-fulldiff)
      mode='full'
      shift
      ;;
    -s|-sign)
      gpg_sign=1
      shift
      ;;
    -so|-signoff|--signoff)
      signoff=1
      shift
      ;;
    -t)
      use_template=1
      shift
      ;;
    -rebase)
      do_rebase=1
      shift
      ;;
    -p)
      add_mode='patch'
      shift
      ;;
    -f)
      force_push=1
      shift
      ;;
    -gc)
      run_gc=1
      shift
      ;;
    -v|-vim)
      use_editor=1
      shift
      ;;
    --)
      shift
      break
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
    echo 'Discarding provided commit message because -v/-vim was specified; the editor will be opened.' >&2
  fi
  commit_msg=''
else
  if [ $# -eq 0 ]; then
    print_usage >&2
    exit 1
  fi
  commit_msg="$@"
fi

stash_output=$(git stash push -k -u -m easyacp-auto 2>&1)
stash_status=$?
if [ $stash_status -ne 0 ]; then
  printf '%s\n' "$stash_output" >&2
  exit $stash_status
fi

if ! printf '%s' "$stash_output" | grep -q 'No local changes to save'; then
  stash_created=1
  trap cleanup EXIT
  trap_set=1
fi

if ! git fetch --all --prune --tags; then
  safe_exit 1
fi

if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  echo 'No upstream tracking branch is configured. Please set an upstream (e.g., git branch --set-upstream-to) before running easyacp.' >&2
  safe_exit 1
fi

if ! git rev-list --left-right --count @{u}...HEAD; then
  safe_exit 1
fi

if [ "$do_rebase" -eq 1 ]; then
  if ! git pull --rebase --autostash --ff-only; then
    echo 'Fast-forward pull with rebase/autostash failed.' >&2
    while :; do
      printf 'Choose how to continue: [r]ebase / [m]erge / [a]bort: '
      read -r pull_choice
      case "$pull_choice" in
        [Rr])
          if git pull --rebase --autostash; then
            break
          else
            echo 'Rebase pull failed.' >&2
            safe_exit 1
          fi
          ;;
        [Mm])
          if git pull --autostash; then
            break
          else
            echo 'Merge pull failed.' >&2
            safe_exit 1
          fi
          ;;
        [Aa]|'')
          echo 'Pull aborted.'
          safe_exit 1
          ;;
        *)
          echo 'Please enter r, m, or a.'
          ;;
      esac
    done
  fi
else
  if ! git pull --ff-only; then
    safe_exit 1
  fi
fi

if [ "$stash_created" -eq 1 ] && [ "$stash_applied" -eq 0 ]; then
  if git stash apply "$stash_ref" >/dev/null 2>&1; then
    stash_applied=1
  else
    safe_exit 1
  fi
fi

if ! git status -sb; then
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
  echo 'No changes to commit.'
  safe_exit 0
fi

if [ "$mode" = 'full' ]; then
  git diff --cached
else
  git diff --cached --name-only
fi

printf 'Stage changes and continue to commit/push? [Y/n]: '
read -r ans
case "$ans" in
  ''|[Yy]*)
    ;;
  *)
    echo 'Operation cancelled.'
    safe_exit 0
    ;;
esac

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
  git diff --cached
else
  git diff --cached --name-only
fi

tag_list=()

printf 'Add tags to this commit before pushing? [Y/n]: '
read -r tag_ans
case "$tag_ans" in
  ''|[Yy]*)
    printf 'Enter tags separated by commas (e.g., tag1, tag2): '
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
    ;;
  *)
    ;;
esac
tag_count=${#tag_list[@]}

if [ "$use_editor" -eq 0 ]; then
  echo 'Commit message preview:'
  printf '%s\n' "$commit_msg"
else
  echo 'Commit message will be edited interactively.'
fi

printf 'Proceed with commit? [Y/n]: '
read -r commit_ans
case "$commit_ans" in
  ''|[Yy]*)
    ;;
  *)
    echo 'Commit cancelled.'
    safe_exit 0
    ;;
esac

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
      echo "Failed to create tag '$tag_name'." >&2
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
  git diff --cached "$push_diff_target"
else
  git diff --cached --name-only "$push_diff_target"
fi

printf 'Push the new commit to the remote? [Y/n]: '
read -r push_ans
case "$push_ans" in
  ''|[Yy]*)
    ;;
  *)
    echo 'Push cancelled.'
    safe_exit 0
    ;;
esac

if ! git fetch origin --prune --tags; then
  echo 'Failed to fetch from origin before push.' >&2
  safe_exit 1
fi

if ! git pull --rebase --autostash --ff-only; then
  echo 'Fast-forward pull with rebase/autostash before push failed.' >&2
  while :; do
    printf 'Choose how to continue: [r]ebase / [m]erge / [a]bort: '
    read -r push_pull_choice
    case "$push_pull_choice" in
      [Rr])
        if git pull --rebase --autostash; then
          break
        else
          echo 'Rebase pull failed.' >&2
          safe_exit 1
        fi
        ;;
      [Mm])
        if git pull --autostash; then
          break
        else
          echo 'Merge pull failed.' >&2
          safe_exit 1
        fi
        ;;
      [Aa]|'')
        echo 'Pull aborted.'
        safe_exit 1
        ;;
      *)
        echo 'Please enter r, m, or a.'
        ;;
    esac
  done
fi

push_cmd=(git push)
if [ $force_push -eq 1 ]; then
  push_cmd+=(--force-with-lease)
fi
if ! "${push_cmd[@]}"; then
  echo 'git push failed.' >&2
  safe_exit 1
fi

if ! git push --tags; then
  echo 'git push --tags failed.' >&2
  safe_exit 1
fi

if [ $run_gc -eq 1 ]; then
  if ! git gc --auto; then
    echo 'git gc --auto failed.' >&2
    safe_exit 1
  fi
  if ! git maintenance run --auto; then
    echo 'git maintenance run --auto failed.' >&2
    safe_exit 1
  fi
fi

if [ $trap_set -eq 1 ]; then
  trap - EXIT
fi
cleanup
