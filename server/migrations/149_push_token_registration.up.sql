ALTER TABLE push_tokens
    ADD COLUMN session_token_hash BYTEA,
    ADD COLUMN platform TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios', 'android'));
