# Contributing

Use TDD for behavior: write an observable failing test, implement the smallest complete change, then refactor with passing checks. Preserve trust-boundary validation and error handling.

Run `docker compose -p fuel-test run --rm test` for Crystal/PostgreSQL integration tests, and `crystal tool format --check src spec examples` in the same toolchain. Use a disposable database; never point the suite at real player data.

Before publishing a change, obtain independent review of the exact candidate, fix material findings, and run the relevant final suite. The initial code import requires review of the complete tree. Maintain portable documentation, MIT-compatible dependency/provenance records and the deliberate storage/session limits.

Use GitHub issues for feature requests. Contact the owner in CODEOWNERS when an integration lacks a shared feature. Keep changes small and include the actual behavior checked and any remaining limits.
