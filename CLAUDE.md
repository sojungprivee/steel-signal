# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Layout

- `PRD.md`: requirements, currently v0.5. It is the source of truth. Cite feature IDs (`FR-xx`) in code comments and tests. When the PRD changes, bump its version and add a row to its change-log table.
- `PROMPTS.md`: the staged build plan. Stages 1–4 are done. `steelsignal/REVIEW.md` is the review report: every finding (H1–H7, M1–M10, L1–L12) is fixed except part of L2, and each fix has a regression test in `tests/test_review_fixes.py` or `tests/test_medium_low_fixes.py`. Consult it before changing related code.
- `steelsignal/`: the Python project. All commands below run from this folder.

## Commands (PowerShell, from `steelsignal/`)

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Dev [-NoSchedule]   # venv + editable install (+ Task Scheduler jobs)
.\.venv\Scripts\python.exe -m pytest                                          # all tests incl. E2E (~1 min)
.\.venv\Scripts\python.exe -m pytest tests\e2e                                # Playwright E2E only (first: python -m playwright install chromium)
.\.venv\Scripts\python.exe -m pytest tests\test_link.py::test_alert_boundary_inclusive
.\.venv\Scripts\steelsignal.exe run-daily --date 2026-11-03                    # full pipeline on input/
.\.venv\Scripts\python.exe scripts\make_fixtures.py                            # regenerate synthetic fixtures
```

Web tests must send the same-origin headers: `TestClient(app, base_url=BASE_URL, headers=SAME_ORIGIN)` from `conftest.py`. Otherwise the Host/Origin guard returns 400/403. Each test runs in a tmp "home" containing a Korean path with a space. `conftest.py` copies `config/` and `tests/fixtures/input/` there, unsets API keys, and sets `STEELSIGNAL_NO_TOAST=1` and `STEELSIGNAL_NO_SCHEDULE=1`, so tests never touch real Windows tasks. The `analyzed` fixture gives a DB that has been ingested and analyzed with the sample data for 2026-11-03.

## Architecture

The `--home` folder (default: the current folder or `STEELSIGNAL_HOME`) holds `config/*.yaml`, `input/`, `output/`, `data/steelsignal.db` and `backup/`. `config.load_config(home)` returns a frozen `AppConfig`. Pydantic models validate all three YAML files and cross-check them. `save_config_file` validates a file before writing it and keeps a `.bak`.

`run-daily` (`cli.py`) runs these steps in order:
1. `ingest_all`: articles, prices, indicators. Each kind's failures go to the `failures` table per date and stage.
2. `run_pipeline`: the stages in `pipeline/`, in this order:
   - `clean`: trafilatura re-reads the HTML; noise-line regexes; NFKC; PDF reflow.
   - `dedup`: char 3-gram cosine. `cluster_id` is the representative article's id.
   - `relevance`: keyword score.
   - `extract`: runs only on cluster representatives at or above the relevance threshold. It drops any driver whose evidence sentence isn't in `clean_text`, and falls back to rule-based for each article if the provider fails.
   - `classify`: deterministic strength = number of sources + whether the text has numbers.
   - `link`: price and FX changes and price–driver links. Writes the `daily_analysis` JSON.
   - `summarize`
3. `render_report`: writes a new version each call, MD → HTML → PDF.
4. Then `ops/maintenance` (latest copy, backup, pruning) and `ops/notify`.

Things that break easily:
- **Stages talk only through the DB.** Each stage reads what the previous stage stored. `daily_analysis.content_json` is the contract between `link`/`summarize` and the report. A stage that raises is recorded and the next stage still runs.
- **LLM providers** (`llm/`): `get_provider` returns `ClaudeProvider` only when `llm.provider: claude` and a key is present; otherwise it returns `RuleBasedProvider`.
  - `ClaudeProvider` uses `client.beta.messages.parse(output_format=PydanticModel, fallbacks="default")`. Do not send `temperature`; current models reject it.
  - It records cost in `llm_usage` and raises `LLMUnavailable` when it hits the daily cost cap, gets a refusal, or hits max_tokens.
  - Prompts live in `llm/prompts/*_v1.md` and are versioned.
  - Tests inject a fake `client`; there are no network calls.
- **Runs are serialized across processes**: `ops/runner.run_daily` holds the `data/run.lock` OS lock. A second run returns status `busy` (the CLI exits with code 3). SQLite uses WAL with `busy_timeout` 30 s.
- **Untrusted text**: article text is untrusted. `markdown_to_html` disables raw HTML, so never pass article-derived strings through `|safe` or f-string HTML without `html.escape`. Logs pass through `logging_setup.mask_secrets`.
- **Reviewed drivers** (`reviewed_by_user=1`, set by `Database.save_feedback`) survive re-extraction, and `extract` never recreates a driver with the same evidence sentence.

## Domain rules (tested — keep them)

- Items are 철광석, 원료탄 and 스크랩 only. Scrap's representative spec is 국내 중량A; JP H2 and US HMS are reference specs. Reference specs are only displayed, with a KRW conversion and spread. They never alert and never take part in alignment. JPY→KRW = USDKRW ÷ USDJPY.
- **Alert**: fires when the representative spec's change vs the previous trading day is **≥** `alert_threshold_pct` (2.0). Compare after `round(pct, 4)` so float error doesn't flip the boundary. A stale price (older than the previous weekday) never alerts.
- **Alignment**: one of aligned / contrary / insufficient, or `None` when the move is flat (|move| < `flat_pct`). Candidate drivers come from articles published D-3..D0 whose item matches or is `common`.
  - `aligned` requires an item-specific driver pointing the same way as the price.
  - If every item-specific driver points the opposite way, the result is `contrary`.
  - If there are only `common` drivers, the result is `insufficient`.
  - Price files are applied in mtime order, so the newest upload wins.
- **No causal wording**: "때문에", "로 인해" and similar must not appear in generated text. Use `summarize.has_causal` to check. Every driver carries a verbatim evidence sentence and its source.
- Fixtures are synthetic. Never put real subscription articles in the repo.

## Environment

Personal Windows PC, PowerShell 5.1, no admin rights.
- Use `pathlib` everywhere.
- Text inputs may be UTF-8 or CP949.
- `install.ps1` must be saved as UTF-8 **with BOM**, otherwise PowerShell 5.1 garbles the Korean.
- The CLI sets `errors="replace"` on stdout for cp949 consoles.
- PDF uses `C:/Windows/Fonts/malgun.ttf`, registered with reportlab in `report/render.py`.

## Web UI (`web/`, Stage 3)

`steelsignal ui` serves `web/app.py:create_app(home)` on 127.0.0.1:8765 using FastAPI, Jinja2 and HTMX. Run it with `--no-browser` to skip opening a browser.
- **Request handling**: config is reloaded on every request, and each request opens its own DB connection. A middleware rejects non-GET requests whose `Origin`/`Referer` is not localhost.
- **Module split**:
  - `web/services.py` holds the view helpers: timeline, upload staging, review, settings.
  - `ruamel.yaml` round-trips YAML so comments survive, then the result passes through `save_config_file`.
  - `web/runs.py` (`RunManager`) runs `ops/runner.run_daily` in a background thread, one run at a time. Use `create_app(home, sync_runs=True)` in tests.
- **Uploads**:
  - Article files: names are sanitized, and the 30MB limit is enforced.
  - Metadata edits are written to `meta.csv` with `override=1`, which beats the file's internal metadata in `merge_metadata`.
  - Price files are staged in `data/staging/` and validated before the user commits them.
  - `/source` serves only files under `input/`.
- **Conventions**:
  - All text in Korean. Up is red and down is blue, always paired with ▲/▼ and a +/- sign.
  - Static assets are local: htmx 2.0.4, Chart.js 4.4.7 and Pretendard (OFL). Use no CDN.
  - Every key element has a `data-testid` for Playwright.
  - The UI calls backend functions only and never reimplements their logic.
- **Tests**: `tests/test_web.py` uses `fastapi.testclient`. Screenshots live in `docs/screenshots/`.
