# A signed-in Xcode session outranks the API key for signing auth

**Status:** accepted

## Metadata
- **Number:** ADR-20
- **Date:** 2026-08-28
- **Scope:** build_kit
- **Deciders:** Benjamin Jordan

## Context
Two ways exist to authenticate the export/upload stage: the Xcode login session, or `-authenticationKeyPath/-ID/-IssuerID` flags pointing at an App Store Connect API key. The obvious instinct — always pass the key when one is configured, because it is explicit and headless — is wrong. API keys are **role-scoped**, and a Developer-role key authenticates successfully but **cannot manage signing assets**: the build fails with "Cloud signing permission error". A logged-in Xcode session carries the human's full permissions. Forcing the key when a session exists only downgrades capability.

## Decision
start_build() reads the signed-in Xcode teams (defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier). The API-key flags are added ONLY when there are no teams and a key is fully configured; otherwise the session is used.

The choice is printed as the log's first line — `auth: ASC API key <id>` or `auth: Xcode session (teams: …)` — so a permission failure can be traced to the auth actually used.

The API key is still used unconditionally for everything else it is good at: the team-validation, app-record and TestFlight-status probes, and the bundle-id registration. Those are read/registration calls that any valid key can make.

## Consequences
An interactive machine gets the strongest available auth, and a headless one still works from the key alone.

A Developer-role key does not break interactive builds — it is simply not used for signing when a session exists.

The auth used for signing can differ from the auth used for the probes, which is why the log names it explicitly and why the 'role too low' classifier entry tells the user to read that line.

## Relations
_None._
