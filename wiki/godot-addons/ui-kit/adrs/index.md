# ADRs

**Status:** active

## Overview
Architectural decision records for UI Kit — why the router is an awaitable async stack-FSM, why controls self-register via `UiReg` as a construction byproduct, why `UiDriver` stays game-agnostic behind a `ui_nav_host`, and why the addon registers no autoloads.

## Contents
- [UiRouter is an async stack-FSM; navigation transitions are awaitable](decision-record:mql3d949-01tp-bz5j3)
- [Actionable controls self-register via UiReg as a byproduct of construction](decision-record:mql3e08u-01yw-pilmta)
- [UiDriver knows no game specifics; the game supplies a ui_nav_host](decision-record:mql3ekiw-022k-5w2vgf)
- [The addon registers no autoloads; the consuming project declares them](decision-record:mql3f6gt-0246-gvd39o)
