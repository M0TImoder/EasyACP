#!/usr/bin/env bash

# 既定のトグルとワークフロー用フラグ
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

# 端末のカラー対応を判定

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

# 情報表示用ヘルパー
info() {
  printf '%b%s%b\n' "${CYAN}${BOLD}" "$1" "$RESET"
}

# 成功メッセージ用ヘルパー
success() {
  printf '%b%s%b\n' "${GREEN}${BOLD}" "$1" "$RESET"
}

# 警告メッセージ用ヘルパー
warn() {
  printf '%b%s%b\n' "${YELLOW}${BOLD}" "$1" "$RESET" >&2
}

# エラーメッセージ用ヘルパー
error() {
  printf '%b%s%b\n' "${RED}${BOLD}" "$1" "$RESET" >&2
}

# ヘルプメッセージ出力
print_usage() {
  cat <<'USAGE'
使い方: git easyacp [オプション] "commit message"
利用可能なオプション:
  -fd | -fulldiff     ファイル名ではなく差分全文を表示
  -rebase             rebase/autostash付きで pull を試行
  -p                  git add -p でインタラクティブにステージ
  -s                  git commit --gpg-sign を付与
  -so | --signoff     git commit --signoff を付与
  -t                  コミットテンプレートを使用 (-t ~/.gitmessage --verbose)
  -v | -vim           エディタでコミットメッセージを編集
  -f                  push に --force-with-lease を付与
  -gc                 push 後に git gc --auto と git maintenance run --auto を実行
  -h | -help | --help このメッセージを表示して終了
USAGE
}

# 一時的な stash を戻して削除
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

# 終了時の共通処理
safe_exit() {
  local status=$1
  if [ $trap_set -eq 1 ]; then
    trap - EXIT
  fi
  cleanup
  exit $status
}

# 前後の空白を削除
trim_spaces() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

# 対話的なYes/No確認
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
        warn 'y か n で入力してください。'
        ;;
    esac
  done
}

# 設定値による確認プロンプトの制御
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

# エイリアスから渡される引数の重複を除去
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

# エイリアス経由の重複呼び出しに対応
dedupe_alias_args "$@"
# 重複除去後の引数を再設定
if [ ${#DEDUPED_ARGS[@]} -gt 0 ]; then
  set -- "${DEDUPED_ARGS[@]}"
else
  set --
fi

# コマンドラインオプションの解析
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
      warn "不明なオプション '$1' です。"
      print_usage >&2
      safe_exit 1
      ;;
    *)
      break
      ;;
  esac
done

# コミットメッセージ引数の有無を記録
if [ $# -gt 0 ]; then
  message_provided=1
fi

# コミットメッセージの組み立てまたはエディタへの引き継ぎ
if [ "$use_editor" -eq 1 ]; then
  if [ "$message_provided" -eq 1 ]; then
    warn '-v/-vim が指定されたため、渡されたコミットメッセージは破棄されエディタが起動します。'
  fi
  commit_msg=''
else
  if [ $# -eq 0 ]; then
    print_usage >&2
    safe_exit 1
  fi
  commit_msg="$@"
fi

# 作業ツリーの変更をstashへ退避
stash_output=$(git stash push -k -u -m easyacp-auto 2>&1)
# stashに失敗した場合は中断
stash_status=$?
if [ $stash_status -ne 0 ]; then
  error "$stash_output"
  safe_exit $stash_status
fi

# 一時stashの管理
if ! printf '%s' "$stash_output" | grep -q 'No local changes to save'; then
  stash_created=1
  trap cleanup EXIT
  trap_set=1
fi

# リモート参照を同期
if ! git fetch --all --prune --tags; then
  error 'git fetch --all --prune --tags に失敗しました。'
  safe_exit 1
fi

# upstream ブランチの設定を検証
if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  error 'upstream の追跡ブランチが設定されていません。git branch --set-upstream-to などで設定してから再実行してください。'
  safe_exit 1
fi

divergence_output=$(git rev-list --left-right --count @{u}...HEAD 2>/dev/null)
if [ $? -ne 0 ]; then
  error 'upstream との差分を取得できませんでした。'
  safe_exit 1
fi

# 差分件数を分解
IFS=$'\t' read -r upstream_only local_only <<EOF
$divergence_output
EOF

# 差分件数を表示
info "upstream のみのコミット数: ${upstream_only:-0}"
info "ローカルのみのコミット数: ${local_only:-0}"

if [ "$do_rebase" -eq 1 ]; then
  if ! git pull --rebase --autostash --ff-only; then
    error 'rebase/autostash 付きの fast-forward pull に失敗しました。'
# pull 時の対応を選択
    while :; do
      printf '%b続行方法を選択してください: [r]ebase / [m]erge / [a]bort:%b ' "${BLUE}${BOLD}" "$RESET"
      read -r pull_choice
      case "$pull_choice" in
        [Rr])
          if git pull --rebase --autostash; then
            break
          else
            error 'rebase pull に失敗しました。'
            safe_exit 1
          fi
          ;;
        [Mm])
          if git pull --autostash; then
            break
          else
            error 'merge pull に失敗しました。'
            safe_exit 1
          fi
          ;;
        [Aa]|'')
          warn 'pull を中止しました。'
          safe_exit 1
          ;;
        *)
          warn 'r / m / a のいずれかを入力してください。'
          ;;
      esac
    done
  fi
else
  # 既定では通常の fast-forward pull
  if ! git pull --ff-only; then
    error 'fast-forward pull に失敗しました。'
    safe_exit 1
  fi
fi

if [ "$stash_created" -eq 1 ] && [ "$stash_applied" -eq 0 ]; then
  if git stash apply "$stash_ref" >/dev/null 2>&1; then
    stash_applied=1
  else
    error 'stash に退避した変更を戻せませんでした。'
    safe_exit 1
  fi
fi

if ! git status -sb; then
  error 'git status -sb が失敗しました。'
  safe_exit 1
fi

# 未ステージの差分を検出
git diff --quiet
diff_status=$?
if [ $diff_status -ne 0 ] && [ $diff_status -ne 1 ]; then
  safe_exit $diff_status
fi

# ステージ済みの差分を検出
git diff --cached --quiet
cached_status=$?
if [ $cached_status -ne 0 ] && [ $cached_status -ne 1 ]; then
  safe_exit $cached_status
fi

# 変更が無ければ早期終了
if [ $diff_status -eq 0 ] && [ $cached_status -eq 0 ]; then
  success 'コミットする変更はありません。'
  safe_exit 0
fi

# 未ステージの変更を表示
if [ "$mode" = 'full' ]; then
  if [ $diff_status -eq 1 ]; then
    info '作業ツリーの変更:'
    git diff
  else
    info '未ステージの変更はありません。'
  fi
else
  if [ $diff_status -eq 1 ]; then
    info '未ステージの変更があるファイル:'
    git diff --name-only
  else
    info '未ステージのファイルはありません。'
  fi
fi

# ステージング前に確認
if ! confirm_decision "$confirm_stage_prompt" 1 'ステージングを実行して続行しますか？'; then
  warn '処理を中止しました。'
  safe_exit 0
fi

# 選択した方法でステージング
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

# ステージ済みの差分概要を表示
if [ "$mode" = 'full' ]; then
  info 'ステージ済みの変更:'
  git diff --cached
else
  info 'ステージ済みのファイル一覧:'
  git diff --cached --name-only
fi

# コミット前にステージ内容を確認
if ! confirm_decision "$confirm_post_stage_prompt" 1 'このステージ内容で続行しますか？'; then
  warn 'ステージング後の処理を中止しました。'
  safe_exit 0
fi

# タグ入力用の配列を初期化
tag_list=()

if confirm_decision "$confirm_tag_prompt" 1 'プッシュ前にタグを追加しますか？'; then
  printf '%bカンマ区切りでタグ名を入力してください (例: tag1, tag2):%b ' "${BLUE}${BOLD}" "$RESET"
  IFS= read -r raw_tags
  if [ -n "$raw_tags" ]; then
    # カンマで区切られたタグを分解
    IFS=',' read -r -a split_tags <<<"$raw_tags"
    for raw_tag in "${split_tags[@]}"; do
      # 各タグの前後の空白を除去
      trimmed=$(trim_spaces "$raw_tag")
      if [ -n "$trimmed" ]; then
        tag_list+=("$trimmed")
      fi
    done
  fi
fi
# 整形済みタグの件数
tag_count=${#tag_list[@]}

# コミットメッセージの確認
if [ "$use_editor" -eq 0 ]; then
  info 'コミットメッセージのプレビュー:'
  printf '%s\n' "$commit_msg"
else
  info 'コミットメッセージはエディタで編集します。'
fi

# コミット実行の確認
if ! confirm_decision "$confirm_commit_prompt" 1 'コミットを実行しますか？'; then
  warn 'コミットを中止しました。'
  safe_exit 0
fi

# 差分表示のために直前の HEAD を控える
prev_head=$(git rev-parse HEAD 2>/dev/null)
if [ $? -ne 0 ]; then
  prev_head=''
fi

# git commit コマンドを構築
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

# タグを自動メッセージ付きで作成
if [ $tag_count -gt 0 ]; then
  # 最新コミットサマリをタグメッセージとして利用
  commit_subject=$(git log -1 --pretty=%s 2>/dev/null)
  for tag_name in "${tag_list[@]}"; do
    tag_message="$commit_subject"
    if [ -z "$tag_message" ]; then
      tag_message="easyacp によって作成されたタグ $tag_name"
    fi
    if ! git tag -m "$tag_message" "$tag_name"; then
      error "タグ '$tag_name' の作成に失敗しました。"
      safe_exit 1
    fi
  done
fi

# プッシュ前の差分比較対象を決定
if [ -n "$prev_head" ]; then
  push_diff_target="$prev_head"
else
  push_diff_target=$(git hash-object -t tree /dev/null)
fi

# プッシュ前にコミット差分を表示
if [ "$mode" = 'full' ]; then
  info '直前の HEAD との差分:'
  git diff --cached "$push_diff_target"
else
  info '今回のコミットで変更されたファイル:'
  git diff --cached --name-only "$push_diff_target"
fi

# プッシュ前の最終確認
if ! confirm_decision "$confirm_push_prompt" 1 'このコミットをリモートへプッシュしますか？'; then
  warn 'プッシュを中止しました。'
  safe_exit 0
fi

# プッシュ前に origin を同期
if ! git fetch origin --prune --tags; then
  error 'プッシュ前の git fetch origin --prune --tags に失敗しました。'
  safe_exit 1
fi

# ローカルブランチが最新か確認
if ! git pull --rebase --autostash --ff-only; then
  error 'プッシュ前の rebase/autostash 付き fast-forward pull に失敗しました。'
# プッシュ前の同期方法を選択
  while :; do
    printf '%b続行方法を選択してください: [r]ebase / [m]erge / [a]bort:%b ' "${BLUE}${BOLD}" "$RESET"
    read -r push_pull_choice
    case "$push_pull_choice" in
      [Rr])
        if git pull --rebase --autostash; then
          break
        else
          error 'rebase pull に失敗しました。'
          safe_exit 1
        fi
        ;;
      [Mm])
        if git pull --autostash; then
          break
        else
          error 'merge pull に失敗しました。'
          safe_exit 1
        fi
        ;;
      [Aa]|'')
        warn 'pull を中止しました。'
        safe_exit 1
        ;;
      *)
        warn 'r / m / a のいずれかを入力してください。'
        ;;
    esac
  done
fi

# push コマンドを組み立て
push_cmd=(git push)
# -f 指定時は --force-with-lease を追加
if [ $force_push -eq 1 ]; then
  push_cmd+=(--force-with-lease)
fi
# push 実行と失敗時の処理
if ! "${push_cmd[@]}"; then
  error 'git push に失敗しました。'
  safe_exit 1
fi

# コミット後にタグを同期
if ! git push --tags; then
  error 'git push --tags に失敗しました。'
  safe_exit 1
fi

# オプションのメンテナンス実行
if [ $run_gc -eq 1 ]; then
  info 'リポジトリのメンテナンスを実行中 (git gc --auto)...'
  if ! git gc --auto; then
    error 'git gc --auto に失敗しました。'
    safe_exit 1
  fi
  info 'リポジトリのメンテナンスを実行中 (git maintenance run --auto)...'
  if ! git maintenance run --auto; then
    error 'git maintenance run --auto に失敗しました。'
    safe_exit 1
  fi
fi

# trap を解除して stash を整理
if [ $trap_set -eq 1 ]; then
  trap - EXIT
fi
cleanup
# 最終メッセージ
success '一連の処理が完了しました。'
