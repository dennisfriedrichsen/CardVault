# CardVault transfer manifest schema v1

The authoritative portable record is `.cardvault/transfer-manifest.json`. It is UTF-8 JSON,
pretty-printed with sorted keys. Dates use ISO 8601. Unknown keys may be ignored; a reader must
reject a `schemaVersion` newer than it supports rather than guessing.

Top-level fields record the schema and app versions, transfer UUID and name, dates, durable state,
mode, source identity, destinations, file records, warnings, and errors. Paths in file records are
relative. Mount paths and security-scoped bookmark bytes are deliberately excluded.

Each file records its source and destination relative paths, media classification, size, relevant
timestamps, source SHA-256, and an independent copy/verification result for every destination UUID.
A file is verified only when the SHA-256 calculated by rereading a closed destination file equals
the source SHA-256. The `verifiedAt` date is present only after required verification succeeds.

Updates are written to a sibling temporary file, then replace the current manifest. The preceding
valid manifest is retained as `transfer-manifest.json.previous` for recovery from a damaged update.
