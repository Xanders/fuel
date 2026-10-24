# Fuel contributor guide

Read README.md, docs/ARCHITECTURE.md, docs/API.md and SECURITY.md before changing contracts. This is a single-maintainer, pre-production library; GitHub issues handle feature requests. CODEOWNERS identifies the maintainer.

Apply the portable [Ponytail method](.agents/skills/ponytail/SKILL.md) to coding work. Use TDD: a failing behavior test precedes implementation. Run the commands in CONTRIBUTING.md. Before first publication, independently review the entire initial tree; later review the exact changed candidate and connected contracts. Record material findings and their resolution.

Keep game rules separate from infrastructure. Active sessions are RAM-only, persistence is PostgreSQL-only, and this version runs on one backend instance. Do not introduce another database, cross-instance sessions or silent recovery promises. Never run tests against real user data.

Public files must be portable and contain no machine-specific paths, private consumer details or host-specific operations. Read AGENTS_LOCAL.md **if it exists**; it is optional and ignored. Do not copy its details into tracked files.

Start with the architecture/API contracts and the knowledge index. After substantial work, update those contracts and retain useful project-specific lessons without publishing private transcripts. Consumer integration instructions live in .agents/skills/fuel-integration/SKILL.md.
