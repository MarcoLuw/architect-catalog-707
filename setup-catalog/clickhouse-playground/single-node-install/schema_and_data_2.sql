CREATE TABLE demo_events (
    event_date Date,
    user_id UInt64,
    event_type String,
    payload String,       -- bulky column
    metadata String,      -- bulky column
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- Insert ~1M+ rows with fat payload/metadata columns
INSERT INTO demo_events
SELECT
    today() - rand() % 365,
    rand() % 1000000,
    ['click','view','purchase','signup'][rand() % 4 + 1],
    randomPrintableASCII(500),
    randomPrintableASCII(500),
    round(randCanonical() * 1000, 2)
FROM numbers(1000000);