# Superseded Local Execution Design

This design was replaced on September 4, 2026 by
[2026-09-04-remote-only-gateway-design.md](2026-09-04-remote-only-gateway-design.md).

The current fork is reverse-only. Local-agent/forward entrypoints are disabled, every supported
Agent process runs on the remote server, and local project commands use the forced gateway.
