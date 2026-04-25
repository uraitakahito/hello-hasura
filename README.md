# hello-hasura

Hasura + PostgreSQL で最小のブログを動かす「Hello World」テンプレートです 🚀

## 🧱 構成

```
├── docker-compose.yml
├── .env.example
└── hasura/
    ├── config.yaml              # Hasura CLI 設定（ローカル開発で使用）
    ├── migrations/              # DDL とシードデータ（起動時に自動適用）
    │   └── blog/1776951599000_init/
    │       ├── up.sql
    │       └── down.sql
    └── metadata/                # テーブル追跡・リレーション・権限の定義
        ├── version.yaml
        └── databases/
            ├── databases.yaml
            └── blog/tables/
                ├── tables.yaml
                ├── public_users.yaml
                ├── public_posts.yaml
                └── public_comments.yaml
```

`users` / `posts` / `comments` の3テーブル構成:

```
users 1 ─── N posts 1 ─── N comments
           ↑                  │
           └──────────────────┘ (comments.user_id = users.id)
```

## ⚡ 起動

```bash
cp .env.example .env
docker compose up -d
```

起動後に以下を確認してください。

```bash
curl http://localhost:8080/healthz
# => OK
```

ブラウザで **http://localhost:8080/console** を開き、`.env` の `HASURA_GRAPHQL_ADMIN_SECRET` を入力すると Hasura Console が開きます。

---

## 🧭 ステップバイステップ・チュートリアル

### ステップ 1: Console でテーブルを確認する

Console の上部メニューから **Data** → 左サイドの `blog` → `public` を開くと、3つのテーブル `users` / `posts` / `comments` がすでに tracked な状態で並んでいます。

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

**これが Hasura の核心です**。

- REST API なら `GET /users` → 各 user の `GET /users/:id/posts` → 各 post の `GET /posts/:id/comments` → 各 comment の `GET /users/:id` と、4階層で N+1 クエリが発生します。
- Hasura では JOIN をメタデータとして定義しておけば、上のクエリが裏側で効率的な SQL に変換されて1往復で返ります。

`metadata/databases/blog/tables/public_posts.yaml` の `object_relationships` / `array_relationships` セクションを覗いてみると、`author` や `comments` というリレーション名がどう定義されているかが分かります。

### ステップ 4: ロールを切り替えて権限を体験する

GraphiQL 右上の `REQUEST HEADERS` で `x-hasura-admin-secret` の行の `☑` を**外します**（admin secret を使わない状態）。

```graphql
query {
  posts {
    title
  }
}
```

を実行すると **2件しか返らない** はずです。`cccccccc-...` の投稿は `published=false`（下書き）なので、デフォルトロール `anonymous` からは見えません。

次に、admin secret を有効に戻し、さらに以下の2行を追加します。

| Key | Value |
|-----|-------|
| `X-Hasura-Role` | `user` |
| `X-Hasura-User-Id` | `11111111-1111-1111-1111-111111111111` |

これは「私は Alice として振る舞いたい」という指定です。この状態でもう一度 `posts { title }` を実行すると、**Alice の下書きも含めた3件** が返ります。`X-Hasura-User-Id` を Bob（`22222222-...`）に変えると、Alice の下書きが消えて2件に戻ります。

これが `anonymous` / `user` ロールによる行レベル権限の効果です。設定は `metadata/databases/blog/tables/public_posts.yaml` の `select_permissions` セクションで行われています。

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

`user_id` を指定していないのに返り値には Alice の ID が入っているはずです。これは `public_posts.yaml` の `insert_permissions.set` で `user_id: x-hasura-user-id` を強制しているためです。**自分の ID 以外の user_id で投稿することはできません**。

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

このテンプレートではファイルに書いた migrations / metadata が起動時に自動適用されるので、**`migrations/` や `metadata/` のファイルを手で編集してから `docker compose down && docker compose up -d` する** だけでも変更を試せます。

---

## 🔌 curl で試す（Console を使わない場合）

```bash
# anonymous で published のみ
curl -s http://localhost:8080/v1/graphql \
  -H 'content-type: application/json' \
  -d '{"query":"{ posts { title } }"}' | jq

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

```bash
# コンテナを停止（データは残る）
docker compose down

# ボリュームごと消す（シードからやり直したいとき）
docker compose down -v
```

---

## ⚠️ 注意

- **admin secret はテンプレート用のダミー値です**。本番やチーム共有環境では必ず強力な値に変えてください。
- 本テンプレートはロール切り替えを `X-Hasura-Admin-Secret` + `X-Hasura-Role` + `X-Hasura-User-Id` ヘッダ方式で示しています。これは admin secret を知っている呼び出し元（学習環境）でのみ有効な方法です。実アプリでは JWT / Webhook 認証を使い、`X-Hasura-User-Id` はトークンのクレームから導出させてください。参考: [Hasura Authentication](https://hasura.io/docs/2.0/auth/authentication/index/)
- シードデータの UUID は固定（`1111...` / `2222...` / `aaaa...`）です。`X-Hasura-User-Id` にそのまま貼り付けて挙動を試せます。

## 📚 参考リンク

- [Hasura v2 Docker Quickstart](https://hasura.io/docs/2.0/getting-started/docker-simple/)
- [Permissions docs](https://hasura.io/docs/2.0/auth/authorization/permissions/)
- [cli-migrations v3 image](https://github.com/hasura/graphql-engine/blob/master/packaging/cli-migrations/v3/README.md)
