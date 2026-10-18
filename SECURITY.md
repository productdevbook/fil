# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub Security Advisories:
<https://github.com/productdevbook/fil/security/advisories/new>

Do not open a public issue for security problems. Include the Fil version, macOS version, steps to reproduce, and the impact. You can expect an acknowledgement within a few days. Please allow time for a fix before public disclosure.

## Scope

In scope: the engine libraries (ScanCore, CleanCore, MapCore) and the `fil` CLI.

Severity guide:

- Critical: anything that could delete, overwrite, or move user data unexpectedly. This includes cleaning rules that match outside their intended paths, symlink or path-traversal escapes, race conditions between scan and clean, and any permanent deletion (Fil must only move items to the Trash).
- High: privilege escalation, or reading data the user did not choose to scan.
- Medium and lower: crashes, incorrect sizes, or information leaks in output (for example, paths exposed despite `--private`).

Out of scope: the proprietary Fil desktop app (report those to the author directly), and issues requiring an already-compromised machine.

## Supported versions

Only the latest release and the `main` branch receive fixes.
