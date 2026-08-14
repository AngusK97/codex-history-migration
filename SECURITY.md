# Security Policy

## Reporting a vulnerability

Do not open a public issue for vulnerabilities that could expose Codex conversations, credentials, local files, or permit unsafe archive extraction.

Use the repository's **Security** tab and select **Report a vulnerability**. Include the affected version, reproduction steps, impact, and any suggested mitigation. Do not attach real Codex history archives or credentials.

## Sensitive data

Migration ZIP files contain complete conversation transcripts and may contain local project paths or optional generated artifacts. They are not encrypted. Treat them as sensitive backups and do not commit them to Git.

The tool intentionally excludes Codex authentication files, sandbox secrets, OAuth locks, and `config.toml` from exported archives.
