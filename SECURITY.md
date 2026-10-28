# Security Policy

## Reporting a vulnerability

Do not open a public issue for vulnerabilities that could expose Codex conversations, credentials, local files, or permit unsafe archive extraction.

Use the repository's **Security** tab and select **Report a vulnerability**. Include the affected version, reproduction steps, impact, and any suggested mitigation. Do not attach real Codex history archives or credentials.

## Sensitive data

Migration ZIP files contain complete conversation transcripts and may contain local project paths or optional generated artifacts. They are not encrypted. Treat them as sensitive backups and do not commit them to Git.

The tool intentionally excludes Codex authentication files, sandbox secrets, OAuth locks, and `config.toml` from exported archives.

## Optional context compression

Offline preview does not transmit data. Explicitly requested semantic compression sends readable selected history to the configured Responses API service and may incur charges. Credentials are read only from the explicitly named environment variable, never from Codex auth files; they are not accepted as command-line values. Known credential patterns are redacted on a best-effort basis, not a guarantee that all sensitive content is removed. History and backups remain sensitive.

The companion preserves original bytes and creates an exact backup before adding a context checkpoint. It refuses unsupported history formats, live Codex processes and detected concurrent modifications. Close clients before replacing files from a backup.
