# ADR-7: ADR-7: Self-update extracts only the addon subtree, never prunes, and rolls back on failure

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** editor_tool_kit
- **Deciders:** Benjamin Jordan

## Context
An in-editor self-update rewrites files on the user's disk while the plugin is running. A naive extract could prune unrelated files, leave a half-written tree, or collapse two archive entries onto one target — any of which corrupts the consumer's project. A find()-based mapping bug of exactly this data-loss class was caught by an adversarial review before ship.

## Decision
The reload runner extracts ONLY the archive's addons/editor_tool_kit/ subtree via an anchored-prefix mapping (accepting the path directly or under one branch-archive wrapper segment, rejecting deeper-nested copies and duplicate targets), writes each file atomically (.tmp + rename) with rollback, and on any failure leaves the plugin DISABLED rather than re-enable a mixed old+new tree (the FAILED_MIXED guard). It overwrites and adds but never prunes.

## Consequences
A failed update never leaves a running, half-installed plugin — it fails closed.

A file removed upstream lingers in the consumer until deleted by hand; never-prune is a deliberate safety bias.

The runner is parented outside the plugin so it survives set_plugin_enabled(false) during the swap.

## Relations
_None._
