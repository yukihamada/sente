# Security Policy

## Supported versions

The latest release of `te` and Sente.app. Please update (`te update`) before reporting.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Email: mail@yukihamada.jp

Please include:

- What you observed, and what you expected instead
- The version (`te --version`, and the Sente.app version from the menu)
- Steps to reproduce

We will acknowledge within 3 business days and keep you updated until it is resolved.

## What we verify

- **Release binaries** are published with a `SHA256SUMS.txt`, and the installer aborts on mismatch.
  Set `TE_REQUIRE_CHECKSUM=1` to make the check mandatory rather than best-effort.
- **Sente.app / Koe.app** are checked with Gatekeeper before being copied to `/Applications`.
- **Credentials** are written to `~/.config/teai/credentials` with mode `600`, and the config
  directory is forced to mode `700`.
- **BYOK keys** are passed to the helper through the environment (not the process argument list),
  serialized with a proper JSON encoder, and unset immediately after use. Provider names are
  checked against an allowlist first.
- **Configuration fetched at runtime** is parsed as data only. It is never sourced or evaluated.
- **No `sh -c`, backtick, or unquoted remote execution** is used to run anything fetched from the network.

## Scope notes

- `te` is a launcher shell script that talks to `teai.io` and `koe.live`. Run `te privacy` to see
  exactly what this build sends and where — that output is generated from the implementation itself.
- Optional features that are **off by default**: voice audio retention (`te privacy stt-log on`),
  PII scrubbing (`te privacy scrub on`), and the local browser-automation server (`TE_NO_PLAYWRIGHT=1`
  disables it).
- This repository does **not** include the server side (teai.io / koe.live). Vulnerabilities in those
  services should also be reported to the address above.
