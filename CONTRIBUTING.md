# Contributing

Thanks for improving Wavify. Keep changes small, tested, and aligned with the pure Ruby core.

## Setup

```bash
bundle install
```

Native OGG Vorbis dependencies are required for the current full test suite because `ogg-ruby` and `vorbis` build native extensions.

## Checks

Run the focused specs while developing, then the full suite before committing:

```bash
bundle exec rspec
bundle exec rake spec:coverage COVERAGE_MINIMUM=90
bundle exec rake docs:examples
YARD_MINIMUM=85 bundle exec rake docs:check
bundle exec rake release:check
```

## Fixtures

Audio fixtures are generated from `spec/fixtures/yaml/wav_fixtures.yml`:

```bash
bundle exec rake spec:create_fixtures
```

Keep generated fixtures small. Prefer procedural examples over large binary files.

## Design Notes

- Preserve immutable public APIs unless a method explicitly ends in `!`.
- Prefer streaming APIs for large-file workflows.
- Keep codec behavior strict and explicit when metadata is missing or ambiguous.
- Do not add mandatory FFmpeg, SoX, MP3, AAC, or M4A support to core.
- Keep CHANGELOG updates separate when requested by maintainers.
