# Wavify project overview
- Purpose: Pure Ruby audio processing gem with immutable, chainable audio transforms and codec support.
- Tech stack: Ruby (>=3.1), Bundler, RSpec, Rake, RuboCop, YARD/RBS (`sig/`).
- Current codec status of interest: OGG Vorbis supports container/header parsing and metadata; audio decode is under implementation with preflight scaffolding.
- Structure: `lib/` implementation, `spec/` tests, `examples/`, `benchmarks/`, `bin/`, `tools/`, `sig/`.
