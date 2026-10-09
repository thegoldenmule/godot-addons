# build_kit

**Status:** active

## Overview
**build_kit** — one-button device builds from inside the Godot editor, starting with **iOS → TestFlight**. A preflight checklist diagnoses the whole Apple toolchain / App Store Connect chain and tells you how to repair each broken link (repairing several itself); a cancellable staged pipeline then runs Godot's headless export → `Info.plist` patch → `xcodebuild archive` → `xcodebuild -exportArchive` straight to TestFlight. Failures are classified into plain-language guidance rather than raw logs. Game-agnostic; configured per project via `res://build_kit.config.json` plus a gitignored `.env`. Built on `editor_tool_kit` and managed by its self-update dock. macOS-only in practice.

## Contents
- [Architecture](toc:mtd8fa5j-0003-69q2yc)
- [Usage](toc:mtd8fd0p-0005-d4eopt)
- [ADRs](toc:mtd8ffsa-0007-sopa7q)
