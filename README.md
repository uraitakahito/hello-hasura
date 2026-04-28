# hello-hasura

Hasura + PostgreSQL で最小のブログを動かす「Hello World」テンプレートです 🚀

## 🧱 構成

```
├── compose.base.yaml
├── compose.dev.yaml
├── compose.prod.yaml
├── .env.example
└── hasura/
    ├── config.yaml              # Hasura CLI 設定（ローカル開発で使用）
    ├── migrations/              # DDL とシードデータ
    │   └── blog/1776951599000_init/
    │       ├── up.sql
    │       └── down.sql
    └── metadata/                # テーブル追跡・リレーション・権限の定義
        ├── version.yaml
        └── databases/
            ├── databases.yaml
            └── blog/tables/
                ├── tables.yaml
                ├── app_users.yaml
                ├── app_posts.yaml
                └── app_comments.yaml
```

`users` / `posts` / `comments` の3テーブル構成:

```
users 1 ─── N posts 1 ─── N comments
           ↑                  │
           └──────────────────┘ (comments.user_id = users.id)
```

## ⚡ 起動

### 開発環境

```bash
cp .env.example .env
docker compose -f compose.base.yaml -f compose.dev.yaml up -d
```

- `cli-migrations-v3` イメージ + `./hasura/{metadata,migrations}` の bind mount で、ファイルを編集して `down && up -d` するだけで反映されます。
- Console / DEV_MODE / query-log すべて有効。PostgreSQL も `5432` でホスト公開。
- プロジェクト名は `hello-hasura-dev`、DB ボリュームは `hello-hasura-dev_db_data`。

起動後に確認:

```bash
curl http://localhost:8080/healthz
# => OK
```

ブラウザで **http://localhost:8080/console** を開き、`.env` の `HASURA_GRAPHQL_ADMIN_SECRET` を入力すると Hasura Console が開きます。

### 本番想定環境（Console / DEV_MODE / auto-apply すべて無効）

```bash
# 1. graphql-engine と postgres を起動（この時点では metadata は空）
docker compose -f compose.base.yaml -f compose.prod.yaml up -d

# 2. 明示的に migrate / metadata を適用する
docker compose -f compose.base.yaml -f compose.prod.yaml \
  --profile migrate run --rm migrator
```

- `graphql-engine` は **素の `hasura/graphql-engine:v2.48.16`**（cli-migrations なし）を使うため、コンテナ再起動で metadata が巻き戻ることはありません。
- bind mount は付かず、Console / DEV_MODE / query-log もすべて `false`。
- `migrator` サービスは `profiles: ["migrate"]` で隔離されており、通常の `up -d` には含まれません。`--profile migrate run --rm migrator` で one-shot 実行します。
- プロジェクト名は `hello-hasura-prod`、DB ボリュームは `hello-hasura-prod_db_data` で、dev とは完全に分離されます。

---

## 🧭 ステップバイステップ・チュートリアル

### ステップ 1: Console でテーブルを確認する

Console の上部メニューから **Data** → 左サイドの `blog` → `app` を開くと、[3つのテーブルがすでに tracked な状態](./hasura/metadata/databases/blog/tables/tables.yaml)で並んでいます。

### ステップ 2: 最初の GraphQL クエリ

Console の **API** タブを開くと GraphiQL が表示されます。右上の `REQUEST HEADERS` に admin secret が入っていることを確認して、以下のクエリを実行してみてください。

```graphql
query {
  users {
    id
    name
    email
  }
}
```

### ステップ 3: リレーションを活用する

次に、投稿とそのコメント、コメントの投稿者まで一気に取得します。

```graphql
query {
  users {
    name
    posts {
      title
      comments {
        body
        author { name }
      }
    }
  }
}
```

### ステップ 4: ロールを切り替えて権限を体験する

GraphiQL 右上の `REQUEST HEADERS` で `x-hasura-admin-secret` の行の `☑` を**外します**（admin secret を使わない状態）。

```graphql
query {
  posts {
    title
  }
}
```

を実行すると **2件しか返らない** はずです。`cccccccc-...` の投稿は `published=false`なので、デフォルトロール `anonymous` からは見えません。

次に、admin secret を有効に戻し、さらに以下の2行を追加します。

| Key | Value |
|-----|-------|
| `X-Hasura-Role` | `user` |
| `X-Hasura-User-Id` | `11111111-1111-1111-1111-111111111111` |

これは「私は Alice として振る舞いたい」という指定です。この状態でもう一度 `posts { title }` を実行すると、**Alice の下書きも含めた3件** が返ります。`X-Hasura-User-Id` を Bob（`22222222-...`）に変えると、Alice の下書きが消えて2件に戻ります。

設定は `metadata/databases/blog/tables/app_posts.yaml` の `select_permissions` セクションで行われています。

### ステップ 5: Mutation で投稿を追加してみる

`user` ヘッダを Alice のままにして、以下の mutation を実行します。

```graphql
mutation {
  insert_posts_one(object: {
    title: "新しい記事",
    body: "Mutation で追加しました",
    published: true
  }) {
    id
    user_id
    title
  }
}
```

`insert_posts_one` のような mutation 名は GraphQL の予約語ではなく、Hasura がテーブル定義から自動生成する **field** です。Hasura Console の **API** タブ右側の `< Docs` ボタンを開くと `mutation_root` の field 一覧がそのまま確認できます。**Data** タブで `Untrack` を押すと、対応する field がスキーマから消えて呼び出せなくなる挙動も体験できます。

`user_id` を指定していないのに返り値には Alice の ID が入っているはずです。これは `app_posts.yaml` の `insert_permissions.set` で `user_id: x-hasura-user-id` を強制しているためです。**自分の ID 以外の user_id で投稿することはできません**。

他人の投稿を書き換えようとすると以下のようにエラーになります。

```graphql
mutation {
  update_posts_by_pk(
    pk_columns: { id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" }
    _set: { title: "乗っ取り" }
  ) { id title }
}
```

返り値が `null` になります（Bob の投稿は Alice には filter に弾かれて更新対象ゼロ件）。

### ステップ 6（発展）: スキーマを変えてみる

Hasura Console から新しいカラムを追加したり、テーブルを作ったりもできます。ただし、その変更を **ファイルとして永続化** するには Hasura CLI（`hasura`）を別途インストールして `hasura console` 経由で開く必要があります。詳しくは [Hasura のドキュメント](https://hasura.io/docs/2.0/hasura-cli/overview/) を参照してください。

開発環境（`compose.dev.yaml`）では `cli-migrations-v3` イメージ + bind mount により migrations / metadata が起動時に自動適用されるので、**ファイルを手で編集してから `docker compose -f compose.base.yaml -f compose.dev.yaml down && docker compose -f compose.base.yaml -f compose.dev.yaml up -d` する** だけで変更を試せます。

本番想定（`compose.prod.yaml`）では auto-apply は無効です。再起動では何も変わらず、`--profile migrate run --rm migrator` を明示的に実行したときだけマイグレーション/メタデータが適用されます（[⚡ 起動](#-起動) 参照）。

---

## 🔌 curl で試す（Console を使わない場合）

```bash
# anonymous で published のみ
curl -s http://localhost:8080/v1/graphql -H 'content-type: application/json' -d '{"query":"{ posts { title } }"}' | jq

# user(Alice) で draft も含む
curl -s http://localhost:8080/v1/graphql \
  -H 'content-type: application/json' \
  -H 'x-hasura-admin-secret: myadminsecretkey' \
  -H 'X-Hasura-Role: user' \
  -H 'X-Hasura-User-Id: 11111111-1111-1111-1111-111111111111' \
  -d '{"query":"{ posts { title published } }"}' | jq
```

---

## 🧹 停止と掃除

開発環境:

```bash
# コンテナを停止（データは残る）
docker compose -f compose.base.yaml -f compose.dev.yaml down

# ボリュームごと消す（シードからやり直したいとき）
docker compose -f compose.base.yaml -f compose.dev.yaml down -v
```

本番想定環境:

```bash
docker compose -f compose.base.yaml -f compose.prod.yaml down
docker compose -f compose.base.yaml -f compose.prod.yaml down -v
```

dev と prod は別プロジェクト（`hello-hasura-dev` / `hello-hasura-prod`）として動くので、ボリュームも別実体です。一方を `down -v` してももう一方には影響しません。

---

## ⚠️ 注意

- 本テンプレートはロール切り替えを `X-Hasura-Admin-Secret` + `X-Hasura-Role` + `X-Hasura-User-Id` ヘッダ方式で示しています。これは admin secret を知っている呼び出し元（学習環境）でのみ有効な方法です。実アプリでは JWT / Webhook 認証を使い、`X-Hasura-User-Id` はトークンのクレームから導出させてください。参考: [Hasura Authentication](https://hasura.io/docs/2.0/auth/authentication/index/)
- `compose.prod.yaml` は「本番**想定**」のサンプルです。学習用に `.env` で admin secret を扱っていますが、実運用では Secrets Manager / SSM / Vault などの仕組みに置き換えてください。
- `compose.prod.yaml` の `graphql-engine` には `hasura-cli` が同梱されていません。CLI を使いたい場合は `--profile migrate run --rm --entrypoint sh migrator` で `migrator` コンテナを立ち上げて使ってください。

## 📚 参考リンク

- [Hasura v2 Docker Quickstart](https://hasura.io/docs/2.0/getting-started/docker-simple/)
- [Permissions docs](https://hasura.io/docs/2.0/auth/authorization/permissions/)
- [cli-migrations v3 image](https://github.com/hasura/graphql-engine/blob/master/packaging/cli-migrations/v3/README.md)
