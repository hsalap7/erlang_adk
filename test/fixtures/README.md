# TLS test fixtures

`mcp_test_key.pem`, `mcp_test_cert.pem`, and `mcp_test_ca.pem` form a public,
localhost-only test identity used by deterministic MCP and Phoenix release
checks. The private key is intentionally committed test data; it is not a
deployment credential and must never be trusted outside local tests.

The CA private key is not present in this repository.
