CREATE TABLE IF NOT EXISTS actor_snapshot (
    object_id   TEXT PRIMARY KEY,
    last_seq    INTEGER NOT NULL CHECK(last_seq >= 0),
    snapshot    BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS actor_wal (
    object_id   TEXT NOT NULL,
    seq         INTEGER NOT NULL CHECK(seq >= 0),
    message_id  BLOB NOT NULL CHECK(length(message_id) = 16),
    mutation    BLOB NOT NULL,
    PRIMARY KEY (object_id, seq),
    UNIQUE (object_id, message_id)
);

CREATE TABLE IF NOT EXISTS actor_seen_message (
    object_id   TEXT NOT NULL,
    message_id  BLOB NOT NULL CHECK(length(message_id) = 16),
    seq         INTEGER NOT NULL CHECK(seq >= 0),
    reply       BLOB,
    PRIMARY KEY (object_id, message_id)
);
