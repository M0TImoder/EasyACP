#!/usr/bin/env bash
set -euo pipefail

# 実行時の状態を初期化
initialize_state()
{

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
  template_path="${HOME}/.gitmessage"
  commit_msg=''
  stash_output=''
  divergence_output=''
  upstream_only='0'
  local_only='0'
  diff_status=0
  cached_status=0
  tag_count=0
  DEDUPED_ARGS=()
  REMAINING_ARGS=()
  tag_list=()
  log_verbose=0
  NUMSTAT_ENTRIES=()
}

log_info()
{

  echo "[INFO] $1"
  print_blank_line
}

log_warn()
{

  echo "[WARN] $1"
  print_blank_line
}

log_error()
{

  echo "[ERR] $1" >&2
  print_blank_line
}

log_question()
{

  echo "[QSTN] $1"
  print_blank_line
}

log_ok()
{

  echo "[OK] $1"
  print_blank_line
}

# 入力プロンプトを表示
show_input_prompt()
{

  echo -n '>>> '
}

# コマンド出力を整形して表示
display_command_output()
{

  local allow_status_one=0
  if [ "$1" = '--allow-status-one' ]; then
    allow_status_one=1
    shift
  fi

  local prefix="$1"
  shift

  local status=0

  if [ "${log_verbose}" -eq 1 ]; then
    "$@"
    status=$?
  else
    local output
    output=$("$@" 2>&1)
    status=$?

    if [ -n "${output}" ]; then
      while IFS= read -r line; do
        if [ -n "${prefix}" ]; then
          echo "${prefix}${line}"
        else
          echo "${line}"
        fi
      done <<<"${output}"
    fi
  fi

  if [ "${status}" -eq 0 ]; then
    print_blank_line
    return 0
  fi

  if [ "${status}" -eq 1 ] && [ "${allow_status_one}" -eq 1 ]; then
    print_blank_line
    return 0
  fi

  print_blank_line
  return "${status}"
}

# 表示系の汎用ヘルパー
print_plain_line()
{

  if [ $# -eq 0 ]; then
    echo ""
  else
    echo "$1"
  fi
}

print_blank_line()
{

  print_plain_line
}

# ファイル一覧を番号付きで表示
print_numbered_entries()
{

  local entries=("$@")
  local index=1
  local entry

  for entry in "${entries[@]}"; do
    print_plain_line "${index}. ${entry}"
    index=$((index + 1))
  done
}

# NUMSTAT の結果を保持
NUMSTAT_ENTRIES=()

# 複数行のテキストをそのまま出力
print_multiline_text()
{

  echo "$1"
}

# git diff --numstat の結果を集計
collect_numstat_entries()
{

  NUMSTAT_ENTRIES=()
  local output

  if ! output=$(git diff --numstat "$@" 2>&1); then
    if [ -n "${output}" ]; then
      log_error "${output}"
    fi
    return 1
  fi

  if [ -z "${output}" ]; then
    return 0
  fi

  while IFS=$'\t' read -r added deleted path; do
    if [ -z "${path}" ]; then
      continue
    fi
    local counts=()
    if [ "${added}" = '-' ] || [ "${deleted}" = '-' ]; then
      counts+=("[binary]")
    else
      if [ "${added}" != '0' ]; then
        counts+=("[+${added}]")
      fi
      if [ "${deleted}" != '0' ]; then
        counts+=("[-${deleted}]")
      fi
      if [ ${#counts[@]} -eq 0 ]; then
        counts+=("[±0]")
      fi
    fi
    local entry="${path}"
    if [ ${#counts[@]} -gt 0 ]; then
      entry="${entry} ${counts[*]}"
    fi
    NUMSTAT_ENTRIES+=("${entry}")
  done <<<"${output}"

  return 0
}

# ヘルプ表示
print_usage()
{

  echo "使い方: git easyacp [オプション] \"commit message\""
  echo "利用可能なオプション:"
  echo "  -fd | -fulldiff     ファイル名ではなく差分全文を表示"
  echo "  -rebase             rebase/autostash付きで pull を試行"
  echo "  -p                  git add -p でインタラクティブにステージ"
  echo "  -s                  git commit --gpg-sign を付与"
  echo "  -so | --signoff     git commit --signoff を付与"
  echo "  -t                  コミットテンプレートを使用 (-t ~/.gitmessage --verbose)"
  echo "  -v | -vim           エディタでコミットメッセージを編集"
  echo "  -f                  push に --force-with-lease を付与"
  echo "  -gc                 push 後に git gc --auto と git maintenance run --auto を実行"
  echo "  -l | -log | --l | --log  Gitコマンドの生出力を許可"
  echo "  -h | -help | --help このメッセージを表示して終了"
}

# フロー案内をまとめて表示
advance_with_info()
{

  log_info "$1"
}

# stash を片付ける
cleanup()
{

  if [ "${stash_created}" -eq 1 ]; then
    if [ "${stash_applied}" -eq 0 ]; then
      if git stash apply "${stash_ref}" >/dev/null 2>&1; then
        stash_applied=1
      fi
    fi
    git stash drop "${stash_ref}" >/dev/null 2>&1 || true
  fi
}

# 終了前の後始末
safe_exit()
{

  local status=$1
  if [ "${trap_set}" -eq 1 ]; then
    trap - EXIT
  fi
  cleanup
  exit "${status}"
}

# 文字列の前後空白を除去
trim_spaces()
{

  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  echo -n "${value}"
}

# Y/n 確認を共通化
prompt_confirm()
{

  local prompt="$1"
  local default_yes=${2:-1}
  local suffix
  local default_reply
  local reply
  local raw_reply

  if [ "${default_yes}" -eq 1 ]; then
    suffix=" [Y/n]:"
    default_reply='y'
  else
    suffix=" [y/N]:"
    default_reply='n'
  fi

  while :; do
    print_blank_line
    log_question "${prompt}${suffix}"
    show_input_prompt
    if ! read -r raw_reply; then
      reply=''
      raw_reply=''
    fi
    print_blank_line
    reply="${raw_reply}"
    if [ -z "${reply}" ]; then
      reply="${default_reply}"
    else
      reply=$(echo "${reply}" | tr '[:upper:]' '[:lower:]')
    fi
    case "${reply}" in
      [Yy])
        return 0
        ;;
      [Nn])
        return 1
        ;;
      *)
        log_warn 'y か n で入力してください。'
        ;;
    esac
  done
}

# 設定値に応じて確認をスキップ
confirm_decision()
{

  local flag=$1
  local default_yes=$2
  shift 2
  local prompt="$*"

  if [ "${all_accept}" -eq 1 ] || [ "${flag}" -ne 1 ]; then
    if [ "${default_yes}" -eq 1 ]; then
      return 0
    fi
    return 1
  fi

  if prompt_confirm "${prompt}" "${default_yes}"; then
    return 0
  fi
  return 1
}

# エイリアス由来の引数重複を除去
dedupe_alias_args()
{

  local args=("$@")
  local total=${#args[@]}
  if [ "${total}" -gt 0 ] && [ $(( total % 2 )) -eq 0 ]; then
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

# コマンドライン引数を解析
parse_arguments()
{

  set -- "$@"
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|-help|--help)
        print_usage
        safe_exit 0
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
      -l|-log|--l|--log)
        log_verbose=1
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
        log_warn "不明なオプション '$1' です。"
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

  REMAINING_ARGS=("$@")
}

# コミットメッセージを組み立て
prepare_commit_message()
{

  if [ "${use_editor}" -eq 1 ]; then
    if [ "${message_provided}" -eq 1 ]; then
      log_warn '-v/-vim が指定されたため、渡されたコミットメッセージは破棄されエディタが起動します。'
    fi
    commit_msg=''
    return
  fi

  if [ "${#REMAINING_ARGS[@]}" -eq 0 ]; then
    print_usage >&2
    safe_exit 1
  fi

  commit_msg="${REMAINING_ARGS[0]}"
  if [ "${#REMAINING_ARGS[@]}" -gt 1 ]; then
    local idx
    for (( idx=1; idx<${#REMAINING_ARGS[@]}; idx++ )); do
      commit_msg="${commit_msg} ${REMAINING_ARGS[idx]}"
    done
  fi
}

# 未コミット変更を退避
create_stash()
{

  if ! stash_output=$(git stash push -k -u -m easyacp-auto 2>&1); then
    log_error "${stash_output}"
    safe_exit 1
  fi

  if ! echo "${stash_output}" | grep -q 'No local changes to save'; then
    stash_created=1
    trap cleanup EXIT
    trap_set=1
  fi
}

# 同期処理前の安全確認
do_checks()
{

  log_info 'リモートと同期中...'
  if ! display_command_output '' git fetch --all --prune --tags; then
    log_error 'git fetch --all --prune --tags に失敗しました。'
    safe_exit 1
  fi

  if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    log_error 'upstream の追跡ブランチが設定されていません。git branch --set-upstream-to などで設定してから再実行してください。'
    safe_exit 1
  fi

  log_info 'コミット数を計算中...'
  if ! divergence_output=$(git rev-list --left-right --count @{u}...HEAD 2>/dev/null); then
    log_error 'upstream との差分を取得できませんでした。'
    safe_exit 1
  fi

  IFS=$'	' read -r upstream_only local_only <<EOF
${divergence_output}
EOF

  log_info "upstream のみのコミット数: ${upstream_only:-0}"
  log_info "ローカルのみのコミット数: ${local_only:-0}"

  if [ "${do_rebase}" -eq 1 ]; then
    if ! display_command_output '' git pull --rebase --autostash --ff-only; then
      log_error 'rebase/autostash 付きの fast-forward pull に失敗しました。'
      while :; do
        print_blank_line
        log_question '続行方法を選択してください: [r]ebase / [m]erge / [a]bort:'
        show_input_prompt
        if ! read -r pull_choice; then
          pull_choice=''
        fi
        print_blank_line
        case "${pull_choice}" in
          [Rr])
            if display_command_output '' git pull --rebase --autostash; then
              break
            fi
            log_error 'rebase pull に失敗しました。'
            safe_exit 1
            ;;
          [Mm])
            if display_command_output '' git pull --autostash; then
              break
            fi
            log_error 'merge pull に失敗しました。'
            safe_exit 1
            ;;
          [Aa]|'')
            log_warn 'pull を中止しました。'
            safe_exit 1
            ;;
          *)
            log_warn 'r / m / a のいずれかを入力してください。'
            ;;
        esac
      done
    fi
  else
    if ! display_command_output '' git pull --ff-only; then
      log_error 'fast-forward pull に失敗しました。'
      safe_exit 1
    fi
  fi
}

# stash を戻す
restore_stash_if_needed()
{

  if [ "${stash_created}" -eq 1 ] && [ "${stash_applied}" -eq 0 ]; then
    if git stash apply "${stash_ref}" >/dev/null 2>&1; then
      stash_applied=1
      return
    fi
    log_error 'stash に退避した変更を戻せませんでした。'
    safe_exit 1
  fi
}

# ステージング処理
do_add()
{

  print_blank_line

  if ! display_command_output '' git status -sb; then
    log_error 'git status -sb が失敗しました。'
    safe_exit 1
  fi

  if git diff --quiet; then
    diff_status=0
  else
    diff_status=$?
    if [ "${diff_status}" -ne 1 ]; then
      safe_exit "${diff_status}"
    fi
  fi

  if git diff --cached --quiet; then
    cached_status=0
  else
    cached_status=$?
    if [ "${cached_status}" -ne 1 ]; then
      safe_exit "${cached_status}"
    fi
  fi

  if [ "${diff_status}" -eq 0 ] && [ "${cached_status}" -eq 0 ]; then
    log_ok 'コミットする変更はありません。'
    safe_exit 0
  fi

  if [ "${mode}" = 'full' ]; then
    if [ "${diff_status}" -eq 1 ]; then
      if ! collect_numstat_entries; then
        local status=$?
        safe_exit "${status}"
      fi
      if [ "${#NUMSTAT_ENTRIES[@]}" -gt 0 ]; then
        log_info '未ステージの変更があるファイル:'
        print_numbered_entries "${NUMSTAT_ENTRIES[@]}"
        print_blank_line
      fi
      if ! display_command_output --allow-status-one '' git diff; then
        local status=$?
        safe_exit "${status}"
      fi
    else
      log_info '未ステージのファイルはありません。'
    fi
  else
    if [ "${diff_status}" -eq 1 ]; then
      if ! collect_numstat_entries; then
        local status=$?
        safe_exit "${status}"
      fi
      if [ "${#NUMSTAT_ENTRIES[@]}" -gt 0 ]; then
        log_info '未ステージの変更があるファイル:'
        print_numbered_entries "${NUMSTAT_ENTRIES[@]}"
        print_blank_line
      fi
    else
      log_info '未ステージのファイルはありません。'
    fi
  fi

  if ! confirm_decision "${confirm_stage_prompt}" 1 'ステージングを実行して続行しますか？'; then
    log_warn '処理を中止しました。'
    safe_exit 0
  fi

  log_info 'ステージング中...'
  if [ "${add_mode}" = 'patch' ]; then
    if ! git add -p; then
      local status=$?
      safe_exit "${status}"
    fi
  else
    if ! git add -A; then
      local status=$?
      safe_exit "${status}"
    fi
  fi

  if [ "${mode}" = 'full' ]; then
    if ! collect_numstat_entries --cached; then
      local status=$?
      safe_exit "${status}"
    fi
    if [ "${#NUMSTAT_ENTRIES[@]}" -gt 0 ]; then
      log_info 'ステージ済みのファイル一覧:'
      print_numbered_entries "${NUMSTAT_ENTRIES[@]}"
      print_blank_line
    fi
    log_info 'ステージ済みの差分:'
    if ! display_command_output --allow-status-one '' git diff --cached; then
      local status=$?
      safe_exit "${status}"
    fi
    print_blank_line
  else
    if ! collect_numstat_entries --cached; then
      local status=$?
      safe_exit "${status}"
    fi
    if [ "${#NUMSTAT_ENTRIES[@]}" -gt 0 ]; then
      log_info 'ステージ済みのファイル一覧:'
      print_numbered_entries "${NUMSTAT_ENTRIES[@]}"
      print_blank_line
    else
      log_info 'ステージ済みのファイルはありません。'
    fi
  fi

  if ! confirm_decision "${confirm_post_stage_prompt}" 1 'このステージ内容で続行しますか？'; then
    log_warn 'ステージング後の処理を中止しました。'
    safe_exit 0
  fi
}

# タグ入力処理
collect_tags()
{

  tag_list=()

  if confirm_decision "${confirm_tag_prompt}" 1 'プッシュ前にタグを追加しますか？'; then
    print_blank_line
    log_question 'カンマ区切りでタグ名を入力してください (例: tag1, tag2):'
    show_input_prompt
    if ! IFS= read -r raw_tags; then
      raw_tags=''
    fi
    print_blank_line
    if [ -n "${raw_tags}" ]; then
      IFS=',' read -r -a split_tags <<<"${raw_tags}"
      local raw_tag
      for raw_tag in "${split_tags[@]}"; do
        local trimmed
        trimmed=$(trim_spaces "${raw_tag}")
        if [ -n "${trimmed}" ]; then
          tag_list+=("${trimmed}")
        fi
      done
    fi
  fi

  tag_count=${#tag_list[@]}
}

# コミット実行
do_commit()
{

  collect_tags

  if [ "${use_editor}" -eq 0 ]; then
    log_info 'コミットメッセージのプレビュー:'
    print_multiline_text "${commit_msg}"
    print_blank_line
  else
    log_info 'コミットメッセージはエディタで編集します。'
  fi

  if ! confirm_decision "${confirm_commit_prompt}" 1 'コミットを実行しますか？'; then
    log_warn 'コミットを中止しました。'
    safe_exit 0
  fi

  if prev_head=$(git rev-parse HEAD 2>/dev/null); then
    prev_head="${prev_head}"
  else
    prev_head=''
  fi

  log_info 'コミット中...'
  set -- git commit
  if [ "${gpg_sign}" -eq 1 ]; then
    set -- "$@" --gpg-sign
  fi
  if [ "${signoff}" -eq 1 ]; then
    set -- "$@" --signoff
  fi
  if [ "${use_template}" -eq 1 ]; then
    set -- "$@" -t "${template_path}" --verbose
  fi
  if [ "${use_editor}" -eq 0 ]; then
    set -- "$@" -m "${commit_msg}"
  fi

  if ! display_command_output '' "$@"; then
    local status=$?
    safe_exit "${status}"
  fi

  local new_hash
  new_hash=$(git rev-parse --short HEAD 2>/dev/null || echo '')
  if [ -n "${new_hash}" ]; then
    log_ok "コミットが正常に終了しました: ${new_hash}"
  else
    log_ok 'コミットが正常に終了しました。'
  fi

  if [ "${tag_count}" -gt 0 ]; then
    local commit_subject
    commit_subject=$(git log -1 --pretty=%s 2>/dev/null)
    local tag_name
    for tag_name in "${tag_list[@]}"; do
      local tag_message="${commit_subject}"
      if [ -z "${tag_message}" ]; then
        tag_message="easyacp によって作成されたタグ ${tag_name}"
      fi
      if ! git tag -m "${tag_message}" "${tag_name}"; then
        log_error "タグ '${tag_name}' の作成に失敗しました。"
        safe_exit 1
      fi
    done
  fi
}

# プッシュ前の差分表示
show_push_preview()
{

  local push_diff_target
  if [ -n "${prev_head}" ]; then
    push_diff_target="${prev_head}"
  else
    push_diff_target=$(git hash-object -t tree /dev/null)
  fi

  if ! collect_numstat_entries "${push_diff_target}" HEAD; then
    local status=$?
    safe_exit "${status}"
  fi

  if [ "${#NUMSTAT_ENTRIES[@]}" -gt 0 ]; then
    log_info '今回のコミットで変更されたファイル:'
    print_numbered_entries "${NUMSTAT_ENTRIES[@]}"
    print_blank_line
  else
    log_info '今回のコミットで変更されたファイルはありません。'
  fi

  if [ "${mode}" = 'full' ]; then
    log_info 'コミット差分の詳細:'
    if ! display_command_output --allow-status-one '' git diff "${push_diff_target}" HEAD; then
      local status=$?
      safe_exit "${status}"
    fi
  fi
}

# プッシュ直前の同期処理
pre_push_sync()
{

  if ! display_command_output '' git fetch origin --prune --tags; then
    log_error 'プッシュ前の git fetch origin --prune --tags に失敗しました。'
    safe_exit 1
  fi

  if ! display_command_output '' git pull --rebase --autostash --ff-only; then
    log_error 'プッシュ前の rebase/autostash 付き fast-forward pull に失敗しました。'
    while :; do
        print_blank_line
        log_question '続行方法を選択してください: [r]ebase / [m]erge / [a]bort:'
        show_input_prompt
        if ! read -r push_pull_choice; then
          push_pull_choice=''
        fi
        print_blank_line
        case "${push_pull_choice}" in
        [Rr])
          if display_command_output '' git pull --rebase --autostash; then
            break
          fi
          log_error 'rebase pull に失敗しました。'
          safe_exit 1
          ;;
        [Mm])
          if display_command_output '' git pull --autostash; then
            break
          fi
          log_error 'merge pull に失敗しました。'
          safe_exit 1
          ;;
        [Aa]|'')
          log_warn 'pull を中止しました。'
          safe_exit 1
          ;;
        *)
          log_warn 'r / m / a のいずれかを入力してください。'
          ;;
      esac
    done
  fi
}

# プッシュ処理
perform_push()
{

  log_info 'プッシュ前のプレビューを表示します...'
  show_push_preview

  if ! confirm_decision "${confirm_push_prompt}" 1 'このコミットをリモートへプッシュしますか？'; then
    log_warn 'プッシュを中止しました。'
    safe_exit 0
  fi

  log_info 'プッシュ前の同期処理を実行します...'
  pre_push_sync

  local push_cmd=(git push)
  if [ "${force_push}" -eq 1 ]; then
    push_cmd+=(--force-with-lease)
  fi

  log_info 'プッシュ中...'
  if ! display_command_output '' "${push_cmd[@]}"; then
    log_error 'git push に失敗しました。'
    safe_exit 1
  fi

  if ! display_command_output '' git push --tags; then
    log_error 'git push --tags に失敗しました。'
    safe_exit 1
  fi

  log_ok 'リモートが正常にプッシュされました。'

  if [ "${run_gc}" -eq 1 ]; then
    log_info 'リポジトリのメンテナンスを実行中 (git gc --auto)...'
    if ! display_command_output '' git gc --auto; then
      log_error 'git gc --auto に失敗しました。'
      safe_exit 1
    fi
    log_info 'リポジトリのメンテナンスを実行中 (git maintenance run --auto)...'
    if ! display_command_output '' git maintenance run --auto; then
      log_error 'git maintenance run --auto に失敗しました。'
      safe_exit 1
    fi
  fi
}

# 最後の後片付け
finalize_run()
{

  if [ "${trap_set}" -eq 1 ]; then
    trap - EXIT
  fi
  cleanup
}

# メイン処理の入り口
main()
{

  initialize_state
  advance_with_info 'EasyACPを開始します...'
  dedupe_alias_args "$@"
  if [ "${#DEDUPED_ARGS[@]}" -gt 0 ]; then
    parse_arguments "${DEDUPED_ARGS[@]}"
  else
    parse_arguments
  fi
  advance_with_info 'コミットメッセージを準備しています...'
  prepare_commit_message
  advance_with_info '未コミットの変更を一時退避します...'
  create_stash
  advance_with_info 'リモート同期処理を開始します...'
  do_checks
  advance_with_info 'リモート同期が完了しました...'
  advance_with_info 'ローカル変更を復元しています...'
  restore_stash_if_needed
  advance_with_info '変更内容の確認を開始します...'
  do_add
  advance_with_info 'ステージングが完了しました...'
  advance_with_info 'コミット処理を準備します...'
  do_commit
  advance_with_info 'コミット処理が完了しました...'
  advance_with_info 'プッシュ処理を準備します...'
  perform_push
  advance_with_info 'すべての処理が完了しました。'
  finalize_run
}

main "$@"
