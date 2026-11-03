# Repository Publication Cleanup

This repository should be published as source code plus templates, not as a dump
of environment evidence. `.gitignore` already excludes everything listed below by
pattern -- this doc exists so a `git status`/`git log` review before a push has a
checklist to compare against, not because any of it needs committing by hand.

## Commit

- Application/source under `backend/` and `frontend/`, except generated
  `frontend/**/data/*.json` and `**/standalone.html`.
- Container, CI, and test config.
- Public operating docs (`docs/00_*.md` through `docs/09_*.md`, and any other doc
  not called out below).
- Template files such as `.env.example` and `*.example.csv`/`*.example.json`.

## Do Not Commit

- `.env`, credentials, tokens, certificates, PATs, or SQL passwords.
- `analysis/`, `runs/`, `data/`, `_fabric_exports/`, `.tmp/`.
- `frontend/**/data/*.json` and `frontend/**/standalone.html` (regenerate locally
  with `backend/scripts/generate_demo_data.py` for a safe synthetic example, or by
  scanning your own real tenant -- never commit either as tracked evidence).
- `index/*.csv`, `index/*.md`, generated `graph/*.csv`, and `diagrams/*.mmd`.
- `docs/conversations/`, `docs/00_work_log.md`, `docs/probe_*.md`, `docs/investigations/`
  (one-off scripts tied to real environment/business data), and any numbered doc
  `.gitignore` calls out by name as a generated tenant-scan report -- see the
  comments there for why each one specifically is excluded.

## If Files Were Already Tracked

```bash
git rm -r --cached analysis runs data _fabric_exports .tmp docs/conversations
git rm -r --cached frontend/semantic-lineage/data
git rm --cached frontend/semantic-lineage/standalone.html
git rm --cached docs/00_work_log.md docs/probe_*.md
git rm --cached index/*.csv index/*.md graph/*.csv diagrams/*.mmd config/*.csv
```

Then review `git status` before committing, and cross-check the filename list in
`.gitignore`'s own "generated tenant-scan report" section -- it's the authoritative,
kept-current list of which specific numbered docs to never track.

## Rebuild Local Evidence

Use the read-only discovery scripts locally after loading credentials through
environment variables or interactive Azure/Fabric login. Never write secrets into
repository files. For a safe example with zero setup, use
`backend/scripts/generate_demo_data.py` instead (synthetic "Contoso" tenant, safe
to publish -- see that script's own docstring).
