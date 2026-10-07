ALTER TABLE push_tokens
    ADD COLUMN session_token_hash BYTEA,
    ADD COLUMN platform TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios', 'android'));

CREATE INDEX push_tokens_session_token_hash_idx ON push_tokens (session_token_hash)
    WHERE session_token_hash IS NOT NULL;
