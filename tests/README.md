# tests/ — verification scripts + (planned) contract conformance harness

Ported `verify-*` scripts from vps-baseline (restic wrap/forget-prune, backup mutex, granular DB
restore, restore step-b, configured-email) + `preview-console-palette.sh`. Run by hand during the
build; CI wiring is a later concern (HANDOVER §10.3).

Planned: a contract conformance harness that runs any adapter through `docs/architecture.md` §1
(see §5 there), with `generic-dir` as the fixture.
