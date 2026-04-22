## OCR Benchmarks

This folder is the local fixture and run-output area for receipt OCR workflow comparisons.

Standalone code now lives outside the app folders:

- `OCRCore/`: reusable OCR + phase-analysis library
- `OCRBench/`: macOS command-line runner
- `OCRBenchmarks/`: fixtures and run outputs

Layout:

- `Fixtures/<case-id>/expected.json`
- `Fixtures/<case-id>/baseline.current.json`
- `Fixtures/<case-id>/transcript.txt`
- `Runs/<timestamp>/<variant-id>/<case-id>.json`
- `Runs/<timestamp>/<variant-id>/summary.json`
- `Runs/<timestamp>/suite-summary.json`

CLI usage:

```bash
export GEMINI_API_KEY=...
swift run ocrbench list
swift run ocrbench bootstrap
swift run ocrbench run
```

Suggested workflow:

1. Run `swift run ocrbench bootstrap`.
2. Review each generated `expected.json` and correct OCR / phase 1 / phase 2 mistakes by hand.
3. Add workflow variants under `OCRCore/` and give each a unique `variantID`.
4. Run `swift run ocrbench run` to score variants against the reviewed expectations.

The benchmark score weights merchant, total, breakdown fields, ordered items, and ordered line items. Timing summaries are written separately so faster variants can be compared when accuracy is close.
