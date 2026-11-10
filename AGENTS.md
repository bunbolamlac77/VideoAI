# AIVideo Agent Operating Guidelines

See [GEMINI.md](GEMINI.md) for full project rules, architecture constraints, and tool integration.

## Key Directives for Agents:
1. **100% Local**: Never attempt to connect to Cloud AI APIs or external inference services.
2. **Swift Core Authority**: Do not modify SQLite database directly from Python or shell scripts.
3. **Evidence Requirement**: Every script proposal, cut decision, and fact claim must link to source hash and timecode.
4. **Planning Files**: Keep `task_plan.md`, `findings.md`, and `progress.md` updated during multi-step work.
5. **Quality Gates**: Respect Gates G0 through G5 (steps S00 to S26) defined in `11-CODING-WORKFLOW-AND-CHECKLIST.md`.
