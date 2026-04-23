CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    email      TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE posts (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title      TEXT NOT NULL,
    body       TEXT NOT NULL,
    published  BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_posts_user_id ON posts(user_id);

CREATE TABLE comments (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id    UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_comments_post_id ON comments(post_id);
CREATE INDEX idx_comments_user_id ON comments(user_id);

-- Fixed UUIDs so tutorial can reference X-Hasura-User-Id reliably.
INSERT INTO users (id, name, email) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Alice', 'alice@example.com'),
    ('22222222-2222-2222-2222-222222222222', 'Bob', 'bob@example.com');

INSERT INTO posts (id, user_id, title, body, published) VALUES
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     '11111111-1111-1111-1111-111111111111',
     'Hasura はじめの一歩',
     'Hasura は PostgreSQL にテーブルを作るだけで GraphQL API が自動生成されます。このテンプレートではブログの例でそれを体験します。',
     true),
    ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     '22222222-2222-2222-2222-222222222222',
     'リレーションでつなぐ',
     'REST なら3回 API を叩く必要があるデータも、GraphQL なら1つのクエリでネストして取得できます。これが Hasura の最大の武器です。',
     true),
    ('cccccccc-cccc-cccc-cccc-cccccccccccc',
     '11111111-1111-1111-1111-111111111111',
     '下書き中の投稿',
     'この投稿は published=false なので anonymous ロールには見えません。user ロール（かつ自分の投稿）からのみ見えます。',
     false);

INSERT INTO comments (post_id, user_id, body) VALUES
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '22222222-2222-2222-2222-222222222222', 'いい記事ですね！'),
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'ありがとう！'),
    ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '11111111-1111-1111-1111-111111111111', '同意です。GraphQL は便利です。'),
    ('cccccccc-cccc-cccc-cccc-cccccccccccc', '22222222-2222-2222-2222-222222222222', '下書きへのコメント（anonymous からは post と一緒に見えません）');
