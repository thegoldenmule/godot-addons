@tool
class_name SnapKitErrors
extends RefCounted

## Snapser error normalization (v0.2).
##
## Every SnapKitTransport result (and so every client / service result) carries:
##   error      the KIT error code: "" on success; a named code below when the
##              Snapser api_error_code is known; else "http_<status>" or a
##              transport code ("offline", "timeout", "network", "no_session").
##   snap_code  the raw Snapser api_error_code (int; 0 when absent).
## Games compare against these constants instead of digging into `json`:
##   var r := await Snapser.quests_claim(q)
##   if r.error == SnapKitErrors.QUEST_NOT_CLAIMABLE: ...   # 15014
##
## Codes are the ones observed on live dev snapends (2026-10-08) plus the
## documented ones the kit relies on.

# ---- Snapser api_error_code values -------------------------------------------
const SNAP_SESSION_TOKEN_MISSING := 10      # no Token / api-key header
const SNAP_SESSION_NOT_FOUND := 12          # stale / unknown session (HTTP 401)
const SNAP_API_KEY_NOT_FOUND := 16
const SNAP_ANON_LOGIN_DISABLED := 1030
const SNAP_EVENT_NOT_FOUND := 2000          # analytics event not declared
const SNAP_INVALID_PROPERTY_VALUE := 2003   # e.g. "true" for a number column
const SNAP_STAT_KEY_NOT_FOUND := 4000       # statistic key not declared
const SNAP_STORAGE_KEY_NOT_FOUND := 5000
const SNAP_STORAGE_TYPE_MISMATCH := 5001    # e.g. /cas/ route on a JSON blob
const SNAP_STORAGE_ALREADY_EXISTS := 5006
const SNAP_CAS_MISMATCH := 5007
const SNAP_BOARD_NOT_FOUND := 9000
const SNAP_BOARD_USER_NOT_FOUND := 9004     # user has no score on the board
const SNAP_PROFILE_NOT_FOUND := 14011
const SNAP_QUEST_NOT_CLAIMABLE := 15014     # e.g. reward-less quest, already completed
const SNAP_APP_CONFIG_NOT_FOUND := 16001

# ---- Kit error codes ---------------------------------------------------------
## Name not declared on the snapend (client-side check, or server 2000 / 4000).
const UNDECLARED := "undeclared"
const QUEST_NOT_CLAIMABLE := "quest_not_claimable"
const CAS_CONFLICT := "cas_conflict"
const ALREADY_EXISTS := "already_exists"
const NOT_FOUND := "not_found"
const INVALID_PROPERTY_VALUE := "invalid_property_value"
const ANON_LOGIN_DISABLED := "anon_login_disabled"

## Known Snapser codes -> kit error code. Anything else stays "http_<status>".
const KIT_ERROR_BY_SNAP_CODE := {
	SNAP_EVENT_NOT_FOUND: UNDECLARED,
	SNAP_STAT_KEY_NOT_FOUND: UNDECLARED,
	SNAP_QUEST_NOT_CLAIMABLE: QUEST_NOT_CLAIMABLE,
	SNAP_CAS_MISMATCH: CAS_CONFLICT,
	SNAP_STORAGE_ALREADY_EXISTS: ALREADY_EXISTS,
	SNAP_INVALID_PROPERTY_VALUE: INVALID_PROPERTY_VALUE,
	SNAP_ANON_LOGIN_DISABLED: ANON_LOGIN_DISABLED,
	SNAP_STORAGE_KEY_NOT_FOUND: NOT_FOUND,
	SNAP_BOARD_NOT_FOUND: NOT_FOUND,
	SNAP_PROFILE_NOT_FOUND: NOT_FOUND,
	SNAP_APP_CONFIG_NOT_FOUND: NOT_FOUND,
}


## The api_error_code in a Snapser error body ("api_error_code", or the older
## "error_code" / grpc "code" spellings); 0 when absent.
static func snap_code(json: Variant) -> int:
	if not (json is Dictionary):
		return 0
	for k in ["api_error_code", "error_code", "code"]:
		var v := SnapKitJson.get_int(json, k, 0)
		if v != 0:
			return v
	return 0


## Kit error code for a failed HTTP response.
static func kit_error(code: int, status: int) -> String:
	return str(KIT_ERROR_BY_SNAP_CODE.get(code, "http_%d" % status))
