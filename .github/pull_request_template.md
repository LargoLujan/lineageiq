## Summary

<!-- What does this change do, and why? Keep it to a few sentences. -->

## Linked issue

Closes #

## How it was tested

<!-- Commands you ran and what you checked by hand, for example with the demo data. -->

- [ ] `python -m compileall -q backend/scripts fabric_notebooks tests`
- [ ] `python -m pytest tests/python/ -q`
- [ ] `node --check` on the changed `.js` files (if any)
- [ ] Manual check: <!-- for example, opened the explorer with LINEAGE_DEMO_MODE=1 and the demo data -->

## Checklist

- [ ] CI passes and the tests cover the changed behaviour
- [ ] README, `docs/` or code comments are updated where behaviour, configuration or commands changed
- [ ] `routes.py` is updated if routes in `handler.py` changed
- [ ] No secrets, no `.env`, no generated output and no real tenant data (examples use Contoso or placeholders)
