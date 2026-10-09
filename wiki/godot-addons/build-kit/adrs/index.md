# ADRs

**Status:** active

## Overview
Decisions behind the addon: Build Kit drives `xcodebuild` itself rather than using Godot's built-in `.ipa` export, every command runs detached, the archive is unsigned so a device-less team can ship, an Xcode session outranks an API key for signing, credentials stay out of the committed config, failures become guidance, and a key is validated against the preset's team before anything it says is believed.

## Contents
- [Build Kit drives xcodebuild itself; Godot's built-in .ipa export is never used](decision-record:mtd8gc4n-000t-274e3e)
- [Every external command runs detached, logged to a file with an exit-code sentinel](decision-record:mtd8gf5x-000v-glhhyr)
- [The archive is built unsigned; only -exportArchive signs](decision-record:mtd8ghzv-000x-7k87e1)
- [A signed-in Xcode session outranks the API key for signing auth](decision-record:mtd8gkzh-000z-1lpprt)
- [ASC credentials live in the repo .env, never in the committed config](decision-record:mtd8gnwl-0011-eil0gd)
- [Known failures are classified into plain-language guidance, never a raw log](decision-record:mtd8gqwl-0013-4mrn14)
- [The API key is validated against the preset's team before any probe it makes is trusted](decision-record:mtd8gtzb-0015-y5ug72)
