# Security Policy

## Supported Versions

This project has not yet reached a `1.0.0` release. Until then, only the
latest published version receives security fixes.

| Version   | Supported |
| --------- | --------- |
| `0.x` (latest) | ✅ |
| `< latest`     | ❌ |

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Report privately instead, using one of:

- GitHub's [private vulnerability reporting](https://github.com/zeeplabs/zeep-nuntis-react-native/security/advisories/new) for this repository (preferred).
- Email: **opensource@zeeptecnologia.com.br**

Include, as applicable:

- A description of the vulnerability and its impact.
- Steps to reproduce (a minimal repro project or code snippet helps a lot).
- The library version, React Native version, and platform(s) affected.

You should expect an initial response within **5 business days**. We'll work
with you to confirm the issue, prepare a fix, and coordinate disclosure timing
before any public write-up. Credit is given in the release notes unless you
ask to stay anonymous.

## Scope

This policy covers the `react-native-nuntis` package itself (JS facade, Kotlin
module, Swift module, Expo config plugin) and its `example/` app's dependency
tree only insofar as it affects the library's published output. Vulnerabilities
in the Nuntis backend itself should be reported against the
[zeep-nuntis](https://github.com/zeeplabs/zeep-nuntis) repository instead.
