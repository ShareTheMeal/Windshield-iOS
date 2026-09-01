# Security Policy

Windshield is a development-only inspector, but the traffic it captures can
contain credentials, personal data, and private application details.

## Supported versions

Security fixes are made against the latest released version. Please confirm an
issue still exists there before reporting it.

## Report a vulnerability

Use [GitHub's private vulnerability reporting](https://github.com/ShareTheMeal/Windshield-iOS/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

Never attach real captured traffic, credentials, access tokens, personal data,
or private service URLs. Use synthetic requests and responses in reproductions.
A useful report includes the Windshield version, affected API, expected impact,
and the smallest synthetic example that demonstrates the problem.

Relevant reports include:

- Windshield code or capture behavior appearing in a Release build
- Sensitive headers bypassing configured redaction
- Captured data leaving the process or being persisted unexpectedly
- Unsafe payload rendering or unbounded memory use
- Interception changing request, response, authentication, or cancellation behavior

## Use Windshield safely

Windshield redacts common credential and cookie headers by default. URLs, query
parameters, request bodies, response bodies, and app-specific headers can still
contain sensitive data. Configure additional redaction, ignored requests, or
metadata-only capture for the application being inspected, and never enable
Windshield in production.
