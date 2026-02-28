# Style and completion guidance
- Ruby codebase uses frozen string literal comments and idiomatic snake_case naming.
- Prefer small incremental changes with tests (RSpec) and keep public behavior stable unless task says otherwise.
- For codec work, add focused fixtures/spec regressions for parsing and decode preflight behavior.
- Task completion checks: run relevant specs first (target file), then broader `bundle exec rspec` if changes touch shared paths; ensure git worktree is clean except intended changes.
