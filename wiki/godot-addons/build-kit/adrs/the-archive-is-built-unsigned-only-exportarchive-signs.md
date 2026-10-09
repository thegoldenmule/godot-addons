# The archive is built unsigned; only -exportArchive signs

**Status:** accepted

## Metadata
- **Number:** ADR-19
- **Date:** 2026-08-28
- **Scope:** build_kit
- **Deciders:** Benjamin Jordan

## Context
The archive stage originally signed with automatic signing and a development identity, the way an Xcode build does. That requires a **development provisioning profile**, and Apple refuses to mint one for a team with **no registered devices** — exactly the situation of someone whose first goal is a TestFlight build rather than a direct install. The result was a hard block at the very start of the pipeline, for a signature nothing downstream consumes: `-exportArchive` re-signs the payload with a distribution identity regardless.

## Decision
The archive stage passes CODE_SIGNING_ALLOWED=NO. The .xcarchive it produces is unsigned.

All signing happens in the export stage: xcodebuild -exportArchive with method app-store-connect, signingStyle automatic and -allowProvisioningUpdates, signing with a distribution certificate through cloud signing (the Xcode session, or an App Manager API key).

## Consequences
A device-less team can build and ship to TestFlight — distribution profiles need no registered devices.

One less place for signing to fail, and one less signing configuration to keep consistent with the other.

The archive alone is not installable on a device; it is an intermediate. Direct on-device installs (the paired-device preflight row) are outside what this pipeline produces.

Signing problems now surface in the last stage rather than the third, so the classifier's signing signatures are matched against the export log.

## Relations
_None._
