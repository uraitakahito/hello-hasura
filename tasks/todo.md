# compose.yaml の dev/prod 分離（案 3）実装計画

## ゴール

- **prod**: 「コンテナ再起動で metadata/migrations が勝手に巻き戻る」事故源を断つ。Console / DEV_MODE / query-log は無効。auto-apply なしの素の `graphql-engine` イメージを使う
- **dev**: 既存の「ファイル編集 → `docker compose down && up -d` で反映」フローをそのまま維持
- 起動コマンドは `-f` 重ね方式で明示的に切り替える（暗黙の override に頼らない）

## 構成方針

```
compose.base.yaml   ← postgres + graphql-engine の共通部分
compose.dev.yaml    ← cli-migrations-v3 イメージ + bind mount + dev フラグ + 5432 公開
compose.prod.yaml   ← 素の graphql-engine + 安全側フラグ + migrator サービス(profile=migrate)
```

旧 `compose.yaml` は削除（破壊的変更）。

---

## フェーズ 1: ベース定義（`compose.base.yaml`）

- [x] `postgres` サービスを完全定義
  - image / restart / POSTGRES_PASSWORD / volume / healthcheck
  - **ports は base に含めない**（dev でだけ公開する）
- [x] `graphql-engine` の共通部分のみを定義
  - `depends_on: postgres (service_healthy)`
  - `ports: 8080:8080`
  - `environment` の共通分:
    - `HASURA_GRAPHQL_DATABASE_URL`
    - `HASURA_GRAPHQL_METADATA_DATABASE_URL`
    - `HASURA_GRAPHQL_ADMIN_SECRET`
    - `HASURA_GRAPHQL_UNAUTHORIZED_ROLE: anonymous`
  - **image はここでは指定しない**（dev/prod 側で必ず上書きする方針を明示する）
- [x] `volumes: db_data` を定義

## フェーズ 2: 開発環境（`compose.dev.yaml`）

- [x] `postgres.ports = ["5432:5432"]`（ホスト公開）
- [x] `graphql-engine.image = hasura/graphql-engine:v2.48.16.cli-migrations-v3`
- [x] `graphql-engine.volumes`:
  - `./hasura/metadata:/hasura-metadata`
  - `./hasura/migrations:/hasura-migrations`
- [x] `graphql-engine.environment` 追加分:
  - `HASURA_GRAPHQL_ENABLE_CONSOLE: "true"`
  - `HASURA_GRAPHQL_DEV_MODE: "true"`
  - `HASURA_GRAPHQL_ENABLED_LOG_TYPES: startup,http-log,webhook-log,websocket-log,query-log`

## フェーズ 3: 本番環境（`compose.prod.yaml`）

### 3-1. `graphql-engine` を素のイメージに

- [x] `graphql-engine.image = hasura/graphql-engine:v2.48.16`（`.cli-migrations-v3` なし）
- [x] **bind mount を付けない**（`/hasura-metadata` `/hasura-migrations` を見せない＝auto-apply されない）
- [x] `environment` 追加分（安全側デフォルト）:
  - `HASURA_GRAPHQL_ENABLE_CONSOLE: "false"`
  - `HASURA_GRAPHQL_DEV_MODE: "false"`
  - `HASURA_GRAPHQL_ENABLED_LOG_TYPES: startup,http-log,webhook-log,websocket-log`（query-log を外す）

### 3-2. 明示的マイグレーション適用用 `migrator` サービス

- [x] `migrator` サービスを定義
  - `image: hasura/graphql-engine:v2.48.16.cli-migrations-v3`
  - `profiles: ["migrate"]`（通常 `up` には含まれない）
  - `restart: "no"`（one-shot）
  - `depends_on: graphql-engine (service_started)`
  - `volumes`: `./hasura/metadata:/hasura-metadata`、`./hasura/migrations:/hasura-migrations`
  - `environment`: 共通 DB URL / `HASURA_GRAPHQL_ADMIN_SECRET`
  - **`entrypoint` を上書き** して、起動時の auto-apply ではなく hasura CLI を直接叩く:
    ```
    hasura-cli migrate apply  --endpoint http://graphql-engine:8080 --admin-secret $$HASURA_GRAPHQL_ADMIN_SECRET --database-name blog --skip-update-check
    hasura-cli metadata apply --endpoint http://graphql-engine:8080 --admin-secret $$HASURA_GRAPHQL_ADMIN_SECRET --skip-update-check
    hasura-cli metadata reload --endpoint http://graphql-engine:8080 --admin-secret $$HASURA_GRAPHQL_ADMIN_SECRET --skip-update-check
    ```
  - 終了コードを CI に正しく伝播させる（`set -e` 相当）

### 3-3. dev/prod ボリューム干渉対策

- [x] `db_data` を dev/prod で共有しない方針を決める
  - 案 A: ボリューム名を別にする（`db_data_dev` / `db_data_prod`）
  - 案 B: そのまま共有し README で警告
  - **推奨は案 A**（学習用テンプレートとはいえ意図しないデータ混在は学習者を混乱させるため）

## フェーズ 4: 環境変数の整理

- [x] `.env.example` を確認し、不足があれば追記（migrator も同じ admin secret を使うので追加項目は基本ない想定）
- [x] dev/prod でフラグを変えたい場合に備えて `.env` 自体は1ファイルのまま、フラグの切替は compose ファイル側で持つ方針とする

## フェーズ 5: 旧ファイル撤去

- [x] `compose.yaml` を削除

## フェーズ 6: ドキュメント更新（`README.md`）

- [x] 「⚡ 起動」セクションを以下に書き換え:
  - dev: `docker compose -f compose.base.yaml -f compose.dev.yaml up -d`
  - prod: `docker compose -f compose.base.yaml -f compose.prod.yaml up -d`
  - prod のマイグレーション適用:
    ```
    docker compose -f compose.base.yaml -f compose.prod.yaml \
      --profile migrate run --rm migrator
    ```
- [x] 「⚠️ 注意」セクションに以下を追記:
  - prod では Console / DEV_MODE / query-log / auto-apply が無効
  - prod で metadata を反映するには明示的に `migrator` プロファイルを起動する必要がある
  - 起動だけでは metadata 空のまま動くので、初回は必ず migrate を回すこと
- [x] 「🧱 構成」のツリーを新ファイル群に合わせて更新

## フェーズ 7: 動作検証

- [x] **dev** 起動後、既存チュートリアル（ステップ 1〜5）が従来どおり動く
- [x] **prod** 初回起動直後は metadata が空、Console にもアクセス不可（403）であることを確認
- [x] **prod** で `--profile migrate run --rm migrator` を実行 → 現状の metadata/migrations が適用されることを確認
- [x] **prod** の `graphql-engine` を `down && up -d` しても metadata が **巻き戻らない** ことを確認（auto-apply 無効の最終証明）
- [x] dev → prod、prod → dev の切替時に DB ボリュームが分離されていれば衝突しない（フェーズ 3-3 で別名化した場合）

---

## 設計上の留意点 / リスク

1. **`migrator` の entrypoint 上書き検証**: cli-migrations-v3 イメージの中の `hasura-cli` バイナリの実パスが `/bin/hasura-cli` か `/usr/local/bin/hasura` か要確認（イメージレイヤを `docker run --rm -it --entrypoint sh` で確認する）。標準 entrypoint は `/bin/docker-entrypoint.sh` で、そのまま起動すると graphql-engine も起動してしまうため、必ず entrypoint を上書きすること
2. **`--database-name blog`**: `metadata/databases/databases.yaml` の name と一致させる必要がある。値変更が起きた場合の同期ポイント
3. **`migrator` から `graphql-engine` への待機**: `service_started` だけだと graphql-engine が起動完了する前に migrate が走る可能性がある。必要なら migrator 側でリトライ付きの待機ロジック（`until curl -f http://graphql-engine:8080/healthz; do sleep 1; done`）を entrypoint に挟む
4. **`HASURA_GRAPHQL_ADMIN_SECRET` の prod 運用**: `.env` でファイル管理するのは学習用に留め、本物の本番では Secrets Manager / SSM / Vault などに置く前提。README にひとこと注意書きを残す
5. **prod イメージ変更による副作用**: 素の `graphql-engine` には `hasura-cli` バイナリが含まれない。デバッグ時に CLI を使いたい場合は `migrator` コンテナを `run --rm` で立ち上げて使う運用を推奨する旨ドキュメント化

---

## 実装中に判明した重要事項（記録）

- **hasura-cli は `config.yaml` を含む project ディレクトリで実行する必要がある**。当初 `cd /hasura-migrations` してから直接 `hasura-cli` を呼ぶ素朴な実装にしたが `validating current directory failed: cannot find [config.yaml]` で失敗した。
- 公式 cli-migrations-v3 の `/bin/docker-entrypoint.sh` を `docker run --rm --entrypoint cat ...` で覗いたところ、**`/tmp/hasura-project/` を作って `metadata/` `migrations/` をコピーし、その場で `config.yaml` を生成してから `hasura-cli` を呼ぶ** 方式だった。これに合わせて修正。
- `--all-databases` フラグで `--database-name` 個別指定を回避できるため、設計留意点 2（databases.yaml との同期点）が消えた。
- bind mount は `:ro` を付けて読み取り専用にした（migrator が誤って `./hasura/` を汚すのを防止）。

## 検証結果サマリ

| 項目 | 結果 |
|---|---|
| dev: チュートリアルの代表クエリ（admin / anonymous / Alice）が従来どおり動く | ✅ |
| prod: 起動直後は `/console` が 404、テーブルも未追跡 | ✅ |
| prod: `--profile migrate run --rm migrator` で metadata 一貫適用（`Metadata is consistent`） | ✅ |
| prod: 適用後 admin で 3 件、anonymous で 2 件取得 | ✅ |
| prod: エラーレスポンスに `extensions.internal` が出ない（DEV_MODE=false の証明） | ✅ |
| prod: `graphql-engine` を `restart` しても metadata が巻き戻らず 3 件のまま | ✅ |
| dev/prod ボリュームが `hello-hasura-dev_db_data` / `hello-hasura-prod_db_data` で分離されている | ✅ |
