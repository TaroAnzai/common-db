# common-db

VPS 上の複数 Docker アプリケーションが共有する MySQL 8.4 LTS 基盤です。アプリごとにデータベースとユーザーを分離し、1サービスずつ論理dumpで移行します。移行スクリプトはデータのコピーと検証までを担当し、アプリの設定変更、再起動、旧DBの停止・削除は一切行いません。

## アーキテクチャ

`common-mysql` はホストへ 3306 を公開しません。external bridge network `common-db-network` に参加したアプリだけが `common-mysql:3306` へ接続します。root は管理・backup・移行専用で、各アプリは自分のDBにだけ `ALL PRIVILEGES` を持つ専用ユーザーを使います。

```text
app A ─┐
app B ─┼─ common-db-network ─ common-mysql:3306 ─ ./data
app C ─┘                                      └─ ./backups
```

初回起動では `MYSQL_DATABASE`、`MYSQL_USER` を設定しないため、MySQL標準のsystem databaseだけが作られます。アプリDBは移行時に初めて作成されます。

## ディレクトリ

```text
docker-compose.yml       MySQL 8.4（external network、healthcheck、bind mount）
config/mysql.cnf         utf8mb4設定
scripts/migrate-db.sh    dump、作成、import、検証
scripts/verify-db.sh     独立実行できる移行前後比較
scripts/backup.sh        daily/weekly論理backupと世代管理
data/                    MySQLデータ（実データはGit対象外）
backups/{daily,weekly}/  完成済みbackup（Git対象外）
migrations/              移行成果物（Git対象外）
systemd/                 backup service/timerのひな型
Makefile                 静的検査
```

## 初回セットアップ

前提は Docker Engine、Docker Compose v2、bash、gzip、GNU coreutils です。リポジトリを想定パスへ置き、秘密ファイルと保存先を所有者だけが読めるようにします。

```bash
cd ~/common-db
cp .env.example .env
chmod 600 .env
chmod 700 data backups migrations
docker network create common-db-network
docker compose up -d
docker compose ps
docker inspect --format '{{.State.Health.Status}}' common-mysql
```

`.env` の `MYSQL_ROOT_PASSWORD` はパスワード生成器で作った長く一意な値へ置換してください。`.env`、data、backup、migration成果物は `.gitignore` 対象です。`docker network create` が「already exists」となる場合は再作成不要です。ネットワークの確認は `docker network inspect common-db-network` で行えます。

起動・停止・ログ確認:

```bash
docker compose up -d
docker compose logs -f mysql
docker compose stop
docker compose start
# 構成自体を停止する場合（bind mountのdataは消えない）
docker compose down
```

`docker compose down -v` や `data/` の削除は通常運用では実行しません。

## DB移行

### 事前確認

- 対象アプリの書き込みを止められる時間帯と手順を決める（厳密な時点整合性には移行中の書き込み停止を推奨）
- 移行元のbackupがありrestore可能であることを確認する
- 移行元serviceが起動中で、指定ユーザーがdump、view、trigger、routine、eventを読めることを確認する
- common-mysqlがhealthyで、空きディスクがdumpとimportに十分あることを確認する
- `--target-db` と `--target-user` が未使用であることを確認する
- DB名・ユーザー名は英数字とunderscoreのみ（安全なSQL識別子のための意図的な制限）

基本例:

```bash
cd ~/common-db
./scripts/migrate-db.sh \
  --compose ~/Task-progress/docker-compose.yml \
  --service db \
  --target-db task_progress \
  --target-user task_progress
```

Composeファイルを絶対パスへ正規化し、そのディレクトリをproject directoryとして `docker compose config` / `docker compose ps` を実行します。このため同じディレクトリの `.env`、`env_file`、`${VARIABLE}` はComposeの通常ルールで解決されます。接続値は解決済みコンテナ環境の `MYSQL_DATABASE`、`MYSQL_USER`、`MYSQL_PASSWORD` / `MYSQL_ROOT_PASSWORD` から取得します。取得不能な値は推測せず、DB名は通常入力、passwordは非表示入力で求めます。

全オプション:

| オプション | 内容 |
|---|---|
| `--compose FILE` | 必須。移行元Composeファイル |
| `--service NAME` | 必須。移行元MySQL service名 |
| `--target-db DB` | 必須。新規作成する移行先DB |
| `--source-db DB` | 移行元DB。省略時は `MYSQL_DATABASE`、なければ対話入力 |
| `--source-user USER` | 省略時は `MYSQL_USER`、なければroot |
| `--target-user USER` | 省略時はtarget DB名 |
| `--yes` | 内容確認だけ省略。password入力は省略しない |
| `-h`, `--help` | help表示 |

passwordをCLI引数で渡すオプションはありません。新規アプリユーザーpasswordは2回、非表示で入力します。passwordはmigration logへ出力しません。

### 処理と安全性

スクリプトはコマンド、common-mysqlの起動・health、Compose/service、移行元接続とDBを確認し、移行前情報を記録します。その後gzip圧縮dumpを作成して `gzip -t` で検査し、移行先DB・`user@'%'` の不存在を再確認済みの状態でDBとユーザーを新規作成し、そのDBだけへ権限を付与します。import後に検証し、接続先を表示します。

成果物は次のようになります。

```text
migrations/20260928_170000_task_progress/
├── dump.sql.gz
├── source-summary.txt
├── target-summary.txt
├── verification.tsv
├── verification.txt
└── migration.log
```

dumpは `--single-transaction --quick` でInnoDBの整合したsnapshotをストリーミングし、メモリ使用を抑えます。`--hex-blob`、`--default-character-set=utf8mb4`、trigger/routine/eventを含め、`--no-tablespaces` で不要な高権限を避け、`--set-gtid-purged=OFF` で共有先のGTID状態を持ち込みません。データディレクトリの物理コピーは行いません。MyISAM等の非トランザクションテーブルは `--single-transaction` だけでは一貫性を保証できないため、書き込み停止が必要です。

対象DBが存在する場合は次のように停止し、DROP・DELETE・上書きは行いません。target userだけが既存の場合も停止します。

```text
ERROR: Database 'task_progress' already exists.
Migration aborted.
No existing database was modified.
```

DB/ユーザー作成後、import完了前に失敗した場合は、「実行前に不存在を確認し、この実行で作成フラグを立てたDB/ユーザー」だけを自動削除します。import完了後の検証失敗では調査用に移行先を保持し、旧DBは変更しません。

### 検証と再実行・rollback

検証は移行元・先のbase table数、各base tableの厳密な `COUNT(*)`、view数、routine種別数、trigger数、event数を比較します。一致すると `Migration verification: PASSED`、差があれば `FAILED` と差分を表示します。厳密な行数比較は大規模DBで時間とI/Oを使うため低負荷時間帯に実行してください。単独実行もできます。

```bash
./scripts/verify-db.sh \
  --compose ~/Task-progress/docker-compose.yml --service db \
  --source-db task_progress --target-db task_progress
```

再実行で既存DBを上書きするモードはありません。失敗成果物を保全し、原因を調べてください。検証失敗後に作り直す場合は、対象が今回作ったDB/ユーザーだと人間が確認し、common-mysqlへrootで接続して明示的に `DROP DATABASE` / `DROP USER` してから再実行します。このリポジトリは曖昧な自動rollbackを提供しません。すでにアプリを切り替えた後はdropせず、接続を旧DBへ戻してから調査します。

### アプリ側の手動切り替え

1. `migrate-db.sh` を実行する。
2. `Migration verification: PASSED` と成果物を確認する。
3. 表示されたhost、port、DB、userを控える（passwordは入力時のもの）。
4. 対象アプリケーションを停止し、移行元への書き込みがないことを確認する。
5. 対象アプリのComposeをexternal `common-db-network` に参加させる。
6. `DATABASE_URL` 等を `common-mysql:3306/<database>` と専用ユーザーへ変更する。
7. アプリを起動する。
8. 読み書き、migration状態、ログを確認する。アプリのmigrationは必要性を確認して人間が実行する。
9. 数日間運用する。
10. 問題がなければ旧MySQLを停止する（まだ削除しない）。
11. さらに問題がないこととbackup/restoreを確認後、別作業として旧コンテナ・データを整理する。

本スクリプトは上記のアプリ設定変更、restart、旧DBの停止・drop・削除、アプリmigrationを実行しません。切り替え直前まで旧DBに更新が続く場合、最初のdump以後の差分は反映されません。短いメンテナンス時間を設けて、書き込み停止後に最終移行する運用にしてください。

## バックアップ

`backup.sh` はsystem database（`mysql`、`information_schema`、`performance_schema`、`sys`）を除く全DBを、DBごとの `.sql.gz` とmanifestにします。一時ディレクトリ `.timestamp.part` を完成品として数えず、全dumpの成功・gzip検査後だけ `YYYYMMDD_HHMMSS` へatomic renameします。新規backup成功後にdailyは最新7スナップショット、weeklyは最新4スナップショットを残します。

日曜日は成功したdaily一式をweeklyへコピーします。独立dumpをしないため追加のDB負荷がなく、その日のdailyとweeklyは同一内容です。weeklyコピーが完了してからweekly retentionを行います。手動実行:

```bash
./scripts/backup.sh                 # 日曜のみweeklyも作成
./scripts/backup.sh --daily-only    # dailyだけ
./scripts/backup.sh --force-weekly  # 曜日に関係なくweeklyも作成
tail -f backups/backup.log
```

### systemd timer（推奨）

cronより実行結果・履歴を `systemctl` / journalで確認しやすく、停止中の実行を `Persistent=true` で補えるためsystemd timerを採用しています。ひな型は `~/common-db` 前提で、毎日03:15（最大10分のランダム遅延）です。ユーザーunitとして配置します。

```bash
mkdir -p ~/.config/systemd/user
cp systemd/common-db-backup.service systemd/common-db-backup.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now common-db-backup.timer
systemctl --user list-timers common-db-backup.timer
systemctl --user status common-db-backup.service
journalctl --user -u common-db-backup.service
```

ログアウト後もuser timerを動かすにはVPS管理者が `sudo loginctl enable-linger "$USER"` を一度設定します。配置先が `~/common-db` でなければserviceの `WorkingDirectory` と `ExecStart` を修正してください。ファイルbackupログは `backups/backup.log`、migrationログは各migrationディレクトリにあります。

### restore

上書き事故を避けるため、まず別名の空DBと専用ユーザーを人間が作り、gzipを検査してrestoreします。次は概念例です。passwordをコマンドラインへ書かず、MySQL clientの対話promptを使います。

```bash
gzip -t backups/daily/20260928_031500/task_progress.sql.gz
docker exec -it common-mysql mysql -uroot -p
# MySQL内で CREATE DATABASE task_progress_restore CHARACTER SET utf8mb4 ...;

read -r -s -p 'Common MySQL root password: ' MYSQL_RESTORE_PASSWORD; echo
{
  printf '%s\n' "$MYSQL_RESTORE_PASSWORD"
  gzip -dc backups/daily/20260928_031500/task_progress.sql.gz
} | docker exec -i common-mysql sh -c \
  'IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec mysql -uroot task_progress_restore'
unset MYSQL_RESTORE_PASSWORD
```

passwordはpipelineの先頭行として渡し、コンテナ内でのみ `MYSQL_PWD` に設定するためargvへ現れません。shell historyへ実値を入力しないでください。restore先が本当に空であること、manifestのSHA-256、テーブル・行数、アプリ互換性を確認してから切り替えます。

## MySQL 8.0 → 8.4の注意

- 8.4で廃止・変更された認証plugin、予約語、SQL mode、照合順序をステージングで確認する。
- アプリのdriver/ORMがMySQL 8.4と `caching_sha2_password` に対応することを確認する。
- dump時の警告、viewのDEFINER、routine/event権限を確認する。存在しないDEFINERはimport後の実行時エラーになり得る。
- `utf8mb4_0900_ai_ci` への照合順序変更が比較・sort・unique制約へ与える影響を確認する。dump内に明示された既存table照合順序はそのまま復元される。
- 8.0を8.4のdata directoryへ直接コピーしない。必ずこの論理移行を使う。

## セキュリティ

- `.env` はmode 600、`data/`、`backups/`、`migrations/` はmode 700を推奨します。成果物は個人情報を含む前提で暗号化されたVPSディスクとoff-site backupも検討してください。
- 3306はpublishしていません。firewall開放も不要です。
- rootをアプリへ渡さず、専用ユーザーには対象DBの `db.*` だけをgrantします。
- passwordをCLI、ログ、Gitへ書きません。shellのxtrace（`set -x`）を有効にして実行しないでください。
- Docker daemonへアクセスできるユーザーは実質root相当で、コンテナ環境の秘密も読めます。VPSのDocker groupを限定してください。
- backupとmigration成果物を外部へ転送する場合は暗号化し、保持・削除方針を別途定めてください。

## 静的検査

```bash
make check
```

`docker compose config`、全scriptの `bash -n`、`shellcheck -x` を実行します。ShellCheckがない場合は明示的なエラーで停止します。Debian/Ubuntuなら `sudo apt install shellcheck` 後に再実行してください。Compose検査では実passwordの代わりに検査専用値を環境変数で渡します。

## トラブルシューティング

- `network common-db-network ... could not be found`: `docker network create common-db-network` を実行する。
- common-mysqlが`unhealthy`: `docker compose logs mysql`、data所有権、空き容量、`.env`を確認する。初回初期化は時間がかかる。
- source serviceが見つからない: `docker compose -f /path/to/docker-compose.yml config --services` と `... ps` を確認する。別project name指定で起動した特殊構成では同じproject指定が必要になるため、標準のCompose起動方法へ合わせる。
- access denied: 移行元の解決済み環境値とユーザー権限を確認する。値を推測して繰り返さない。
- dump失敗: disk容量、権限、非対応option、routine/viewの権限をmigration logで確認する。移行元は変更されない。
- target already exists: 自動上書きはしない。前述の再実行手順で所有関係を確認する。
- verification FAILED: `verification.txt` とTSVを比較し、アプリを切り替えない。移行中の書き込みも典型原因。
- backup失敗: systemd status、journal、`backups/backup.log`を確認する。失敗した`.part`は完成世代に数えず、古い成功backupも削除しない。
- 容量不足: `du -sh data backups migrations` で確認する。dataを手動削除せず、不要と確認した古いmigration成果物を保全方針に従って整理する。
