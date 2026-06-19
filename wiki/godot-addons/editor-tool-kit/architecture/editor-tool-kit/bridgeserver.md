# BridgeServer

**Status:** current

## Kind
component

## Summary
**Optional** localhost HTTP base: a `TCPServer` poll loop + `Content-Length` request framing + async dispatch + a headless skip. A subclass overrides `_resolve_port()` and `_route(method, path, query, body) -> {code, payload}` to expose the tool to an MCP shim or a CLI.

## Purpose
Some tools want to be driven from outside the editor (an MCP server, a CLI). Generalizing one tool's HTTP bridge into a base lets any tool opt in with just a route table, while tools that don't need it pay nothing.

## Design notes
_No design notes._

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `BridgeServer` in `addons/editor_tool_kit/bridge_server.gd`

## Data model
_None._

## Usage
`class_name FooBridge extends BridgeServer`; override `_resolve_port()` and `_route(...)`. Declare it in the plugin's `_config()` under `bridge` so `EditorToolPlugin` constructs and injects the service into it. The route table can `await` service coroutines. It is **opt-in per tool** and a **no-op under headless** (`DisplayServer.get_name() == "headless"`), so verifiers and CLI runs never bind a port.

## Invariants & constraints
- Bridge / HTTP access is opt-in per tool and a no-op under headless, so verifiers and CLI runs never bind a port.

## Synced commit
501411d
