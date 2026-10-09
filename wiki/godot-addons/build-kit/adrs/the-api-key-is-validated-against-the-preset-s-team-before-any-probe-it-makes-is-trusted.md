# The API key is validated against the preset's team before any probe it makes is trusted

**Status:** accepted

## Metadata
- **Number:** ADR-23
- **Date:** 2026-08-28
- **Scope:** build_kit
- **Deciders:** Benjamin Jordan

## Context
App Store Connect API keys are **team-scoped**, and anyone with more than one Apple team (a personal one and a studio one, say) can easily mint a key on the wrong one — the team picker sits quietly at the top right of the API-keys page. Such a key is not rejected: it authenticates, and it answers every query **truthfully about the wrong team**. Asking it whether the app record exists for a bundle id returns a confident "no" — which preflight would render as "create the app", sending the user to create a duplicate record on the wrong team. A wrong answer that looks right is worse than an error.

## Decision
The asc_key preflight check is a two-phase async chain. Phase one runs asc_helper.py team-info and compares the key's team against the preset's app_store_team_id. Only a match advances to phase two, the check-app probe.

The API has no whoami, so team-info infers the team from the key's own assets: a certificate's subject OU (authoritative), falling back to a bundle id's seedId.

On a mismatch the asc_key row fails with both team labels resolved to 'Name (ID)' and the exact remedy (switch the team picker, mint a new App Manager key, drop it), and the app_record row is set to 'blocked — wrong-team API key (fix the row above)'. Its probe never runs, so no wrong-team answer is ever displayed.

An empty team_id means the team simply owns no assets yet — not a mismatch. The row goes ok, labelled 'team unverified', and the chain continues.

## Consequences
Preflight either shows a verified answer or says why it cannot — it never shows a confident wrong one.

The key check costs two sequential network round trips instead of one, both detached with a 60 s timeout that degrades to 'check timed out — Refresh to retry'.

The same reasoning shapes the rest of the row's states: a rejected key (401 / NOT_AUTHORIZED) is reported as invalid-or-revoked with the mint-a-new-one path, and any other API error leaves the app-record row explicitly 'skipped (key not validated)' rather than silently green.

## Relations
_None._
