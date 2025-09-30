# EasyACP  

EasyACP は、日常的な Git コミット作業を対話的にアシストするためのシェルスクリプトです。コミット前後の確認・差分確認・タグ付け・プッシュまでを 1 コマンドでまとめて実行でき、作業途中の変更を安全に扱うためのガードも備えています。

## 主な機能

- 変更内容のプレビューや `git add -p` によるステージングを対話的に実行
- コミットテンプレート、GPG署名、`--signoff` などのオプションに対応
- プッシュ前に `git fetch --all --prune --tags` を実行し、ローカルとupstreamの差分を可視化
- プッシュ後に `git gc --auto` や `git maintenance run --auto` を任意で実行
- **引数なしで実行した場合は、未コミット変更を一時退避しながらupstreamをfast-forwardする更新専用モードを提供**

## 前提条件

- Bash 4以降
- Git 2.x系
- コマンドラインから `git` が利用できること
- リポジトリの現在ブランチにupstreamの追跡設定があること

## 導入方法

1. このリポジトリをクローンします。
   ```bash
   git clone https://github.com/<your-account>/EasyACP.git
   ```
2. スクリプトに実行権限が付与されていることを確認します。
   ```bash
   chmod +x /path/to/EasyACP/bin/easyacp.sh
   ```
3. 任意のリポジトリで `git easyacp` として使えるよう、Git エイリアスを設定します。
   ```bash
   git config --global alias.easyacp '!/path/to/EasyACP/bin/easyacp.sh'
   ```
   - システムワイドに導入したい場合は `--global` の代わりに `--system` を使用してください。
   - 複数のマシンで共有する場合は、パスが異なる点に注意してください。

## 使い方

### コミット〜プッシュまでを実行する

```bash
git easyacp "feat: add awesome thing"
```

実行すると以下のフローを順に処理します。

1. 変更をstashに退避
2. upstreamを`git fetch --all --prune --tags`で同期
3. upstreamとローカルのコミット数を表示
4. stashを戻して差分を確認・ステージング
5. コミットメッセージを確認・編集
6. プッシュ前のプレビューと確認
7. `git push`（必要に応じてタグや `--force-with-lease`、`--signoff` などを付与）
8. オプションで `git gc --auto` や `git maintenance run --auto`

各ステップでは確認プロンプトが表示されるため、処理を途中で中断することも可能です。

### リポジトリを最新状態に更新する（コミットなし）

引数なしで実行すると、コミットやプッシュを伴わずに upstream との同期だけを行います。

```bash
git easyacp
```

1. 未コミットの変更をstashに退避
2. `git fetch --all --prune --tags` による同期
3. upstreamのfast-forward反映（必要に応じて `git pull --ff-only` 相当を実行）
4. stashを復元
5. 「リポジトリは最新の状態です。」と表示して終了

### 主なオプション

| オプション | 説明 |
| --- | --- |
| `-fd`, `-fulldiff` | ステージング前の差分を全文表示 |
| `-rebase` | `git pull --rebase --autostash --ff-only` を試行 |
| `-p` | `git add -p` でインタラクティブにステージング |
| `-s` | `git commit --gpg-sign` を付与 |
| `-so`, `--signoff` | `git commit --signoff` を付与 |
| `-t` | `~/.gitmessage`（既定）などのテンプレートを使用 |
| `-v`, `-vim` | エディタでコミットメッセージを編集 |
| `-f` | `git push --force-with-lease` を付与 |
| `-gc` | プッシュ後に `git gc --auto` と `git maintenance run --auto` を実行 |
| `-l`, `-log`, `--l`, `--log` | Git コマンドの標準出力をそのまま表示 |
| `-h`, `-help`, `--help` | ヘルプを表示して終了 |

上記以外の引数はコミットメッセージとして扱われます。複数行のメッセージは `\n\n` で区切られます。

## トラブルシューティング

- **`upstream の追跡ブランチが設定されていません` と表示される**
  - `git branch --set-upstream-to origin/main` などでupstreamを設定してください。
- **GPG 署名が失敗する**
  - `gpg-agent` の設定や `gpg --list-secret-keys` の確認を行い、Gitの `user.signingkey` 設定を見直してください。

## 開発者向けメモ

- コードはBashスクリプト1本 (`bin/easyacp.sh`) のみです。
- lintや自動テストは用意していないため、変更後は手動で `bash bin/easyacp.sh -h` などを実行して動作確認してください。

## なんでGoやPythonにしないの？

それは本当にそうです。でも既にシェルへ移植した後なので、もう気力がないです...  

まあ、私のシェルのお勉強になったので時間の無駄ではなかったです。  
授業以外で使うことはないと思ってましたので、思う存分堪能できて私は満足です。  

## ライセンス

[MIT License](LICENSE)を参照してください。
