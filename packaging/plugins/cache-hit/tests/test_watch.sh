#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cache-hit-test.XXXXXX")
trap 'cancel_timer; rm -rf "$TMP"' EXIT
export CODEX_SESSIONS_DIR="$TMP/sessions" HERDR_PLUGIN_STATE_DIR="$TMP/state" HODEX_SESSIONS_DIR="$TMP/unused"
export HERDR_PLUGIN_CONFIG_DIR="$TMP/config"
export HERDR_NO_TIMER=1
mkdir -p "$CODEX_SESSIONS_DIR/2026/09/06"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/codex.sh"; source "$ROOT/lib/pi.sh"; source "$ROOT/lib/claude.sh"; source "$ROOT/lib/cache.sh"
fail=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fail=1; }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else printf 'not ok - %s\n' "$3"; fail=1; fi; }
assert_cmd() { if eval "$1" >/dev/null 2>&1; then ok "$2"; else not_ok "$2"; fi; }
pid_is_live() {
  local stat
  stat=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ') || return 1
  [[ -n "$stat" && "$stat" != Z* ]]
}
sid=aaa111; roll="$CODEX_SESSIONS_DIR/2026/09/06/rollout-$sid.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111","cwd":"/same"}}' 'not json' '{"type":"token_usage_record","timestamp":"2026-09-06T10:00:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":500},"model":"m1","model_provider":"p1"}}' '{"type":"incomplete"}' >"$roll"
printf '%s\n' '{"type":"session_meta","payload":{"id":"wrong"}}' >"$TMP/rollout-bbb222.jsonl"
assert_eq "$(rollout_for_session "$sid")" "$roll" 'native ID selects exact rollout'
assert_eq "$(rollout_for_session bbb222 || true)" '' 'wrong rollout identity is rejected'

# UUIDv7 fast path test: historical session from May 2026 resolved without scanning
uuid7="019e0779-180e-7ec2-9d3c-e18de4536265"
mkdir -p "$CODEX_SESSIONS_DIR/2026/05/08"
roll7="$CODEX_SESSIONS_DIR/2026/05/08/rollout-$uuid7.jsonl"
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$uuid7\"}}" >"$roll7"
assert_eq "$(rollout_for_session "$uuid7")" "$roll7" 'UUIDv7 timestamp selects exact historical rollout'

assert_eq "$(latest_usage "$roll" "$sid")" $'2026-09-06T10:00:00Z\t1000\t500\tm1\tp1' 'malformed lines are ignored'

# Codex CLI token_count uses per-request counts, not cumulative session totals.
modern_roll="$CODEX_SESSIONS_DIR/2026/09/06/rollout-modern.jsonl"
cat >"$modern_roll" <<'JSONL'
{"type":"session_meta","payload":{"id":"modern","model_provider":"custom-provider"}}
{"type":"turn_context","payload":{"model":"gpt-current"}}
{"type":"event_msg","timestamp":"2026-09-06T10:03:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":90000},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400}}}}
{"type":"event_msg","timestamp":"2026-09-06T10:04:00Z","payload":{"type":"token_count","info":null,"rate_limits":{}}}
not json
{"type":"event_msg","payload":
JSONL
assert_eq "$(latest_usage "$modern_roll" modern)" $'2026-09-06T10:03:00Z\t1000\t400\tgpt-current\tcustom-provider' 'Codex token_count reads last usage and ignores quota-only and partial rows'
assert_eq "$(codex_usage modern | cut -f1-10)" $'codex\tmodern\t2026-09-06T10:03:00Z\t1000\t400\t0\t0\t0\tgpt-current\tcustom-provider' 'Codex adapter preserves model/provider column alignment'
printf '%s\n' '{"type":"token_usage_record","timestamp":"2026-09-06T10:05:00Z","payload":{"session_id":"modern","usage":{"input_tokens":2000,"cached_input_tokens":1600}}}' >>"$modern_roll"
assert_eq "$(latest_usage "$modern_roll" modern)" $'2026-09-06T10:05:00Z\t2000\t1600\tgpt-current\tcustom-provider' 'newer token_usage_record wins and inherits rollout metadata'
printf '%s\n' '{"type":"turn_context","payload":{"model":"next-model"}}' >>"$modern_roll"
assert_eq "$(latest_usage "$modern_roll" modern | cut -f4)" gpt-current 'later turn context does not relabel previous usage'
printf '%s\n' '{"type":"event_msg","timestamp":"2026-09-06T10:06:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3000,"cached_input_tokens":0}}}}' >>"$modern_roll"
assert_eq "$(latest_usage "$modern_roll" modern)" $'2026-09-06T10:06:00Z\t3000\t0\tnext-model\tcustom-provider' 'newer token_count wins including a real zero-cache request'
printf '%s\n' '{"type":"token_usage_record","timestamp":"2026-09-06T10:07:00Z","payload":{"session_id":"other","usage":{"input_tokens":4000,"cached_input_tokens":3500}}}' '{"type":"event_msg","timestamp":"2026-09-06T10:08:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":4000,"cached_input_tokens":-1}}}}' '{"type":"event_msg","timestamp":"2026-09-06T10:09:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000,"cached_input_tokens":3500}}}}' >>"$modern_roll"
assert_eq "$(latest_usage "$modern_roll" modern | cut -f1-3)" $'2026-09-06T10:06:00Z\t3000\t0' 'foreign session, invalid counts, and cumulative-only rows are ignored'
bare_roll="$TMP/bare-codex.jsonl"
printf '%s\n' '{"type":"token_usage_record","timestamp":"2026-09-06T10:00:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":500}}}' >"$bare_roll"
assert_eq "$(latest_usage "$bare_roll" bare)" $'2026-09-06T10:00:00Z\t1000\t500\tcodex\topenai' 'missing model/provider use nonempty defaults before TSV parsing'
assert_eq "$(CODEX_HOME="$TMP/custom-home" env -u CODEX_SESSIONS_DIR -u HODEX_SESSIONS_DIR bash -c 'source "$1/lib/core.sh"; printf "%s" "$SESSIONS_DIR"' _ "$ROOT")" "$TMP/custom-home/sessions" 'Codex home overrides the default session directory'

if python3 - "$ROOT" "$TMP" <<'PY'
import json, os, pathlib, runpy, sys, time
module = runpy.run_path(str(pathlib.Path(sys.argv[1]) / 'lib/codex_session.py'))
resolve = module['resolve_session']
sessions = pathlib.Path(sys.argv[2]) / 'resolver-sessions'
sessions.mkdir()
started = time.time()
process = {'foreground_processes': [{'name': 'codex', 'argv': ['codex'], 'pid': os.getpid()}]}
def fixture(sid, created, **extra):
    payload = {'id': sid, 'cwd': '/same', 'timestamp': created, 'originator': 'codex-tui', 'source': 'vscode', **extra}
    path = sessions / f'rollout-{sid}.jsonl'
    path.write_text(json.dumps({'type': 'session_meta', 'payload': payload}) + '\n')
    return path
fresh = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(started))
old = '2026-01-01T00:00:00Z'
fixture('root', fresh)
fixture('child', fresh, parent_thread_id='root', source={'subagent': {}}, thread_source='subagent')
assert resolve(sessions, '/same', 'p1', process, [], started) == 'root'
print('ok - missing native ID resolves a fresh root and excludes subagents')
fixture('collision', fresh)
assert resolve(sessions, '/same', 'p1', process, [], started) is None
print('ok - simultaneous same-directory roots are ambiguous')
resume = {'foreground_processes': [{'name': 'codex', 'argv': ['codex', 'resume', 'root', '--yolo']}]}
assert resolve(sessions, '/same', 'p1', resume, [{'agent': 'codex', 'pane_id': 'p2', 'cwd': '/same'}], started) == 'root'
print('ok - explicit resume ID disambiguates same-directory panes')
resume['foreground_processes'][0]['argv'].insert(1, '--no-daemon')
assert resolve(sessions, '/same', 'p1', resume, [{'agent': 'codex', 'pane_id': 'p2', 'cwd': '/same'}], started) == 'root'
print('ok - explicit resume ID survives the no-daemon global flag')
fixture('root', old)
fixture('collision', old)
claimed = [{'agent': 'codex', 'pane_id': 'p2', 'cwd': '/other', 'agent_session': {'kind': 'id', 'value': 'collision'}}]
assert resolve(sessions, '/same', 'p1', process, claimed, started) == 'root'
print('ok - unique active cwd fallback excludes sessions assigned to other panes')
assert resolve(sessions, '/same', 'p1', process, [], started) is None
print('ok - multiple active roots refuse a newest-file guess')
assert resolve(sessions, '/same', 'p1', process, claimed + [{'agent': 'codex', 'pane_id': 'p3', 'cwd': '/same'}], started) is None
print('ok - cwd fallback refuses multiple live panes in the same directory')
assert resolve(sessions, '/same', 'p1', {'foreground_processes': []}, claimed, started) is None
print('ok - missing Codex foreground process cannot select a historical session')
assert resolve(sessions, '/same', 'p1', process, claimed, None) is None
print('ok - missing process launch time cannot select a historical session')
fixture('root', fresh)
resumed = fixture('collision', old)
with resumed.open('a') as handle:
    handle.write(json.dumps({'type': 'token_usage_record', 'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(started + 1)), 'payload': {'usage': {'input_tokens': 1000, 'cached_input_tokens': 400}}}) + '\n')
assert resolve(sessions, '/same', 'p1', process, [], started) == 'collision'
print('ok - interactive resume selects the used root instead of an empty bootstrap thread')
other = fixture('other-active', old)
for path, total_in, total_out in [(resumed, 98901000, 241030), (other, 41000, 1800)]:
    with path.open('a') as handle:
        handle.write(json.dumps({'type': 'token_usage_record', 'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(started + 1)), 'payload': {'usage': {'input_tokens': 1000, 'cached_input_tokens': 400}, 'thread_token_usage': {'input_tokens': total_in, 'output_tokens': total_out}}}) + '\n')
title_panes = [{'pane_id': 'p1', 'agent': 'codex', 'cwd': '/same', 'terminal_title_stripped': 'Working | Context 78% used | 98.9M in | 241K out | GPT-current'}]
assert resolve(sessions, '/same', 'p1', process, title_panes, started) == 'collision'
print('ok - pane title totals disambiguate multiple active root rollouts')
with other.open('a') as handle:
    handle.write(json.dumps({'type': 'event_msg', 'timestamp': fresh, 'payload': {'type': 'token_count', 'info': {'total_token_usage': {'input_tokens': 98902000, 'output_tokens': 241000}}}}) + '\n')
assert resolve(sessions, '/same', 'p1', process, title_panes, started) is None
print('ok - indistinguishable rounded title totals remain ambiguous')
assert abs(module['process_started'](os.getpid()) - started) < 5
print('ok - process start time is read from the local process table')
PY
then :; else not_ok 'Codex missing-session resolver fixtures'; fi

assert_eq "$(fmt_tokens 0)" 0 'zero formatting'; assert_eq "$(fmt_tokens 10000)" 10.0k 'thousands formatting'; assert_eq "$(fmt_tokens 2000000)" 2.0M 'millions formatting'
init_state; report_pane() { :; }; clear_pane() { :; }
update_pane paneA "$sid"; d1=$(jq -r .active.deadline "$(state_path paneA)"); update_pane paneA "$sid"; d2=$(jq -r .active.deadline "$(state_path paneA)")
assert_eq "$d1" "$d2" 'cached records do not extend deadline'
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
printf '%s\n' '{"codex":{"enabled":false}}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
assert_eq "$(config_bool codex enabled true)" false 'per-agent enabled setting is read'
rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.json"
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:01:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":0},"model":"m1","model_provider":"p1"}}' >"$roll"
update_pane paneA "$sid"; assert_cmd "jq -e '.active == null' \"$(state_path paneA)\"" 'cold transition sets active null'
assert_cmd "jq -e '.\"p1:m1\" | length == 1' \"$OBSERVATIONS_FILE\"" 'cold transition records observation in shared observations.json'

# Switch to m2/p2 at 10:02:00Z (hit_at = 10:02:00Z, deadline = 10:32:00Z, ttl = 1800)
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:02:00Z","payload":{"usage":{"input_tokens":1,"cached_input_tokens":1},"model":"m2","model_provider":"p2"}}' >"$roll"
update_pane paneA "$sid"; assert_cmd "jq -e '.active.model == \"m2\" and .active.provider == \"p2\"' \"$(state_path paneA)\"" 'model/provider are isolated'

# Surprise hit past deadline: prompt at 10:47:00Z (45 min = 2700s > 1800s deadline) with cache read hits
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:47:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":800},"model":"m2","model_provider":"p2"}}' >"$roll"
update_pane paneA "$sid"
assert_cmd "jq -e '.\"p2:m2\" | (length == 1 and .[0] == 2700)' \"$OBSERVATIONS_FILE\"" 'surprise hit past deadline records survival observation'

# Cross-pane sharing: paneB with same model/provider reads from shared observations
record_observation p2 m2 3300
learned=$(get_learned_ttl p2 m2 1800)
assert_eq "$learned" 3000 'shared observations compute learned TTL across panes'

# Prefix shift guardrail: cold drop within 20s does not add to observations
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:47:20Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":0},"model":"m2","model_provider":"p2"}}' >"$roll"
update_pane paneA "$sid"
assert_cmd "jq -e '.\"p2:m2\" | length == 2' \"$OBSERVATIONS_FILE\"" 'prefix shift under 60s is ignored by observation guardrail'

printf '%s\n' corrupt >"$(state_path paneB)"; update_pane paneB "$sid"; assert_cmd "jq -e . \"$(state_path paneB)\"" 'corrupt state is rebuilt'

# Pi and Claude adapter fixtures exercise native session paths and independent
# read/write counters without involving either CLI's status command.
pi_root="$HOME/.pi"; claude_root="$TMP/claude"; export CLAUDE_CONFIG_DIR="$claude_root"
mkdir -p "$claude_root/projects/-same"
pi_file="$TMP/pi-session.jsonl"
printf '%s\n' '{"type":"message","timestamp":1788690000000,"message":{"role":"assistant","model":"pi-test","provider":"test-provider","usage":{"input":1000,"cacheRead":400,"cacheWrite":25}}}' 'partial' '{"type":"message","timestamp":1788690060000,"message":{"role":"assistant","model":"pi-test","provider":"test-provider","usage":{"input":1200,"cacheRead":800,"cacheWrite":50}}}' >"$pi_file"
assert_eq "$(pi_usage "$pi_file" | cut -f1-10)" $'pi\t'$pi_file$'\t2026-09-06T10:21:00Z\t1200\t800\t50\t0\t0\tpi-test\ttest-provider' 'Pi adapter maps latest usage and ignores malformed lines'
assert_eq "$(pi_usage "$TMP/missing.jsonl" || true)" '' 'missing Pi session is unavailable'
claude_file="$claude_root/projects/-same/claude-1.jsonl"
printf '%s\n' '{"sessionId":"claude-1","timestamp":"2026-09-06T10:02:00Z","message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":400,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":25}},"model":"claude-sonnet"}}' >"$claude_file"
assert_eq "$(claude_usage claude-1 /same | cut -f1-10)" $'claude\tclaude-1\t2026-09-06T10:02:00Z\t1000\t400\t75\t50\t25\tclaude-sonnet\tanthropic' 'Claude transcript maps cache lifetime creation counters'
now=$(date +%s)
update_pane panePi pi "$pi_file" /same; assert_cmd "jq -e '.active.agent == \"pi\" and .active.session_id == \"'$pi_file'\" and .active.read == 800' \"$(state_path panePi)\"" 'Pi state is isolated by agent and session path'
update_pane paneClaude claude claude-1 /same; assert_cmd "jq -e '.active.agent == \"claude\" and .active.provider == \"anthropic\"' \"$(state_path paneClaude)\"" 'Claude state is isolated by agent and provider'
mkdir "$STATE_DIR/watcher.lock"; printf '%s\n' 999999 >"$STATE_DIR/watcher.lock/pid"; assert_cmd 'acquire_lock' 'stale lock is recoverable'; cleanup
if command -v python3 >/dev/null 2>&1; then
  py=$(python3 - "$roll" <<'PY'
import json,sys
last=''
for line in open(sys.argv[1]):
 try: o=json.loads(line)
 except json.JSONDecodeError: continue
 if o.get('type')=='token_usage_record':
  u=o.get('payload',{}).get('usage',{})
  if isinstance(u.get('input_tokens'),int) and isinstance(u.get('cached_input_tokens'),int): last='\t'.join([o.get('timestamp',''),str(u['input_tokens']),str(u['cached_input_tokens']),o.get('payload',{}).get('model',''),o.get('payload',{}).get('model_provider','')])
print(last)
PY
); assert_eq "$py" "$(latest_usage "$roll" "$sid")" 'Bash and Python fixture outputs agree'; fi

fake="$TMP/fake-herdr"; reports="$TMP/watcher-reports"; panes="$TMP/panes.json"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'if [[ "$1 $2" == "pane list" ]]; then cat "$FAKE_PANES"; elif [[ "$1 $2" == "pane process-info" ]]; then cat "${FAKE_PROCESS_INFO:-/dev/null}"; else printf "%s\n" "$*" >>"$FAKE_REPORTS"; fi' >"$fake"; chmod +x "$fake"
printf '%s\n' '{"result":{"panes":[{"pane_id":"p1","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"aaa111"}},{"pane_id":"p2","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"bbb222"}},{"pane_id":"p5","agent":"pi","cwd":"/same","agent_session":{"kind":"path","value":"/missing/pi.jsonl"}}]}}' >"$panes"
FAKE_PANES="$panes" FAKE_REPORTS="$reports" HERDR_BIN_PATH="$fake" WATCH_ONCE=1 bash "$ROOT/watch.sh"
assert_cmd "grep -q 'p1.*cache=' \"$reports\"" 'watcher reports native session pane'
assert_cmd "grep -q 'p1.*cache_status=' \"$reports\"" 'watcher reports granular cache_status'
assert_cmd "grep -q 'p1.*clear-token cache_pct' \"$reports\"" 'cold watcher clears formatted cache percentage'
assert_cmd "grep -q 'p1.*clear-token cache_pct_num' \"$reports\"" 'cold watcher clears numeric cache percentage'
assert_cmd "grep -q 'p1.*cache_tokens=' \"$reports\"" 'watcher reports granular cache_tokens'
assert_cmd "grep -q 'p1.*clear-token cache_deadline' \"$reports\"" 'watcher clears cache_deadline on cold pane'
assert_cmd "grep -q 'p1.*clear-token cache_remaining_secs' \"$reports\"" 'watcher clears cache_remaining_secs on cold pane'
assert_cmd "grep -q 'p2.*clear-token cache' \"$reports\"" 'missing rollout clears second pane'
assert_cmd "grep -q 'p2.*clear-token cache_deadline' \"$reports\"" 'missing rollout clears cache_deadline'
assert_cmd "grep -q 'p2.*clear-token cache_pct_num' \"$reports\"" 'missing rollout clears numeric percentage'
assert_cmd "grep -q 'p5.*clear-token cache' \"$reports\"" 'missing Pi usage clears cache'
assert_cmd "grep -q 'p5.*clear-token cache_deadline' \"$reports\"" 'missing Pi usage clears cache_deadline'
FAKE_REPORTS="$reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" bash -c \
  'source "$1/lib/core.sh"; report_pane paneNumeric codex "~12:00 80% ⇣800" 15000 "~12:00" "80%" "⇣800" hot "80% ⇣800" 2000000000 240 80' _ "$ROOT"
assert_cmd "grep -q 'paneNumeric.*cache_pct=80%' \"$reports\" && grep -q 'paneNumeric.*cache_remaining_secs=240' \"$reports\" && grep -q 'paneNumeric.*cache_pct_num=80' \"$reports\"" 'hot watcher reports formatted and numeric cache metadata'
printf '%s\n' '{"result":{"panes":[{"pane_id":"p1","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"aaa111"}}]}}' >"$panes"
FAKE_PANES="$panes" FAKE_REPORTS="$reports" HERDR_BIN_PATH="$fake" WATCH_ONCE=1 bash "$ROOT/watch.sh"
assert_cmd "grep -q 'p2.*clear-token cache' \"$reports\"" 'closed pane is cleared'

# A missing native session ID must survive empty TSV fields and keep polling
# before the first token_count arrives, rather than waiting for a focus event.
recovery_process="$TMP/recovery-process.json"
recovery_reports="$TMP/recovery-reports"
recovery_wakes="$TMP/recovery-wakes"
recovery_roll="$CODEX_SESSIONS_DIR/2026/09/06/rollout-recovery.jsonl"
printf '%s\n' '{"result":{"process_info":{"foreground_processes":[{"name":"codex","argv":["codex","resume","recovery"],"pid":1}]}}}' >"$recovery_process"
printf '%s\n' '{"result":{"panes":[{"pane_id":"pRecovery","agent":"codex","cwd":"/same","agent_session":null}]}}' >"$panes"
printf '%s\n' '{"type":"session_meta","payload":{"id":"recovery","model_provider":"openai"}}' >"$recovery_roll"
FAKE_PANES="$panes" FAKE_PROCESS_INFO="$recovery_process" FAKE_REPORTS="$recovery_reports" FAKE_WAKE_FILE="$recovery_wakes" HERDR_BIN_PATH="$fake" HERDR_NO_TIMER='' bash -c \
  'source "$1/watch.sh"; schedule_wake() { printf "%s\n" "$1" >"$FAKE_WAKE_FILE"; }; cancel_timer() { printf "cancel\n" >"$FAKE_WAKE_FILE"; }; watch_main' _ "$ROOT"
assert_eq "$(cat "$recovery_wakes")" 15 'Codex pane with no usage schedules a 15-second refresh'
recovery_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "{\"type\":\"event_msg\",\"timestamp\":\"$recovery_ts\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":400}}}}" >>"$recovery_roll"
FAKE_PANES="$panes" FAKE_PROCESS_INFO="$recovery_process" FAKE_REPORTS="$recovery_reports" HERDR_BIN_PATH="$fake" bash "$ROOT/watch.sh"
assert_cmd "grep -q 'pRecovery.*cache_pct=40%' \"$recovery_reports\"" 'missing native ID publishes first token_count cache hit'
assert_cmd "jq -e '.active.session_id == \"recovery\" and .active.read == 400' \"$(state_path pRecovery)\"" 'missing native ID watcher keeps counters attached to the resolved session'
printf '%s\n' '{"result":{"panes":[]}}' >"$panes"
FAKE_PANES="$panes" FAKE_REPORTS="$recovery_reports" FAKE_WAKE_FILE="$recovery_wakes" HERDR_BIN_PATH="$fake" HERDR_NO_TIMER='' bash -c \
  'source "$1/watch.sh"; schedule_wake() { printf "%s\n" "$1" >"$FAKE_WAKE_FILE"; }; cancel_timer() { printf "cancel\n" >"$FAKE_WAKE_FILE"; }; watch_main' _ "$ROOT"
assert_eq "$(cat "$recovery_wakes")" cancel 'closing all Codex panes cancels cold refreshes'

# Configurable symbols and expiring threshold tests
init_state
now=$(date +%s)
last_reported=""
last_deadline=""
last_pct=""
last_remaining=""
last_pct_num=""
report_pane() { last_reported="$3"; last_pct="${6:-}"; last_deadline="${10:-}"; last_remaining="${11:-}"; last_pct_num="${12:-}"; }
sig="codex|s1|m|p|1000|800|0|0|0"
codex_usage() { printf 'codex\ts1\t%s\t1000\t800\t0\t0\t0\tm\tp\t/same\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

# Active Pi pane survives transient missing record until deadline
clear_pane() { last_reported="CLEARED"; last_deadline=""; }
pi_fixture="$TMP/pi-survive.jsonl"
printf '%s\n' '{"type":"message","timestamp":1788690000000,"message":{"role":"assistant","model":"m","provider":"p","usage":{"input":500,"cacheRead":0,"cacheWrite":0}}}' >"$pi_fixture"
jq -n --arg sig "pi|$pi_fixture|m|p|1000|800|0|0|0" --arg path "$pi_fixture" --argjson now "$now" '{active:{agent:"pi",session_id:$path,model:"m",provider:"p",signature:$sig,hit_at:($now-60),deadline:($now+240),input:1000,read:800,write:0,write5m:0,write1h:0},observations:[]}' >"$(state_path paneSurvive)"
update_pane paneSurvive pi "$pi_fixture"
assert_cmd '[[ "$(jq -r .active.read "$(state_path paneSurvive)")" == "800" && "$last_reported" == *"800"* ]]' 'Pi pane preserves token counters on transient missing record'

# Replacement session in same pane clears old session retained tokens
now_expired=$((now + 300))
now=$now_expired update_pane paneSurvive pi "$TMP/missing-pi.jsonl"
assert_cmd '[[ "$last_reported" != *"800"* ]]' 'replacement Pi session without cache clears stale tokens'
assert_cmd '[[ "$(jq -r ".last_known" "$(state_path paneSurvive)")" == "null" ]]' 'replacement Pi session clears old last_known state'

# Percentage-enabled agents also suppress percentages while cold.
codex_usage() { printf 'codex\tsess-cold\t%s\t1000\t0\t0\t0\t0\tm\tp\t/same\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
jq -n --argjson now "$now" '{active:{agent:"codex",session_id:"sess-cold",model:"m",provider:"p",signature:"old",hit_at:($now-60),deadline:($now-1),input:1000,read:800,write:0,write5m:0,write1h:0},observations:[]}' >"$(state_path paneColdCodex)"
now=$now update_pane paneColdCodex codex sess-cold
assert_eq "$last_reported" "- ⇣800" 'Codex cold cache suppresses percentage and keeps retained token count'
assert_eq "$last_pct" "" 'Codex cold formatter clears formatted percentage'
assert_eq "$last_pct_num" "" 'Codex cold formatter clears numeric percentage'
assert_eq "$last_remaining" "" 'Codex cold formatter clears remaining seconds'
codex_usage() { printf 'codex\ts1\t%s\t1000\t800\t0\t0\t0\tm\tp\t/same\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

# 1. Hot state: deadline 10 minutes ahead (> 300s)
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:$now,deadline:($now+600)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_eq "$last_deadline" "$((now+600))" 'active pane passes deadline to report_pane'
if (( last_remaining >= 599 && last_remaining <= 600 )); then ok 'active pane passes remaining seconds to report_pane'; else not_ok 'active pane passes remaining seconds to report_pane'; fi
assert_eq "$last_pct_num" "80" 'active pane passes numeric percentage to report_pane'
assert_cmd "[[ \"$last_reported\" == '+'* ]]" 'hot cache uses the plain plus symbol by default'
assert_cmd "[[ \"$last_reported\" =~ \+[~][0-9]{2}:[0-9]{2} ]]" 'hot cache clock remains normal-weight before threshold (>5m)'

# 2. Expiring state: deadline 4 minutes ahead (<= 300s)
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:($now-1560),deadline:($now+240)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == '!'* ]]" 'expiring cache under 5m displays the plain exclamation symbol by default'
assert_cmd "[[ \"$last_reported\" =~ ![~][0-9]{2}:[0-9]{2} ]]" 'expiring cache clock remains normal-weight under threshold (<=5m)'

# 3. Custom config override: custom hot, expiring symbols, and custom bold threshold
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
printf '%s\n' '{"hot_symbol":"🔥","expiring_symbol":"⚡","expiring_threshold_seconds":60,"bold_time":true,"bold_threshold_seconds":60}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'🔥'* ]]" 'custom hot symbol and threshold are respected'
assert_cmd "[[ \"$last_reported\" =~ [0-9]{2}:[0-9]{2} ]]" 'clock stays non-bold when above custom bold threshold'
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:($now-1770),deadline:($now+30)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'⚡'* ]]" 'custom expiring symbol is respected'
assert_cmd "[[ \"$last_reported\" =~ (𝟬|𝟭|𝟮|𝟯|𝟰|𝟱|𝟲|𝟳|𝟴|𝟵) ]]" 'clock becomes bold when under custom bold threshold'

# 4. Arbitrary user text/emoji/empty symbols
printf '%s\n' '{"hot_symbol":"[HOT]","expiring_symbol":"","cold_symbol":"🧊"}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:$now,deadline:($now+600)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'[HOT]'* ]]" 'arbitrary text or emoji symbols are allowed'
rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.json"

# TTL ceiling guardrail tests
# 1. Observations exceeding ceiling (e.g. 44005s from multi-hour idle) are rejected
record_observation pCeil mCeil 44005 3600
assert_cmd "! jq -e 'has(\"pCeil:mCeil\")' \"$OBSERVATIONS_FILE\"" 'observations exceeding ceiling are rejected by record_observation'

# 2. Corrupted or legacy observations exceeding ceiling in observations.json are filtered by get_learned_ttl
jq '.["pCeil:mCeil"] = [44005, 3000, 3200]' "$OBSERVATIONS_FILE" >"$OBSERVATIONS_FILE.tmp" && mv "$OBSERVATIONS_FILE.tmp" "$OBSERVATIONS_FILE"
learned_clamped=$(get_learned_ttl pCeil mCeil 1800 3600)
assert_eq "$learned_clamped" 3100 'get_learned_ttl filters out legacy observations exceeding ceiling'

# 3. Session isolation: surprise hit does NOT record across different session IDs in the same pane
roll_s2="$CODEX_SESSIONS_DIR/2026/09/06/rollout-s2.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"id":"s2"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T15:00:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":800},"model":"mIso","model_provider":"pIso"}}' >"$roll_s2"
jq -n --arg sig "codex|s1|mIso|pIso|1000|800|0|0|0" '{active:{agent:"codex",session_id:"s1",model:"mIso",provider:"pIso",signature:$sig,hit_at:1788690000,deadline:1788691800},observations:[]}' >"$(state_path paneIso)"
update_pane paneIso codex s2
assert_cmd "! jq -e 'has(\"pIso:mIso\")' \"$OBSERVATIONS_FILE\"" 'different session ID does not record surprise hit across sessions'

# 4. Timezone override in fmt_clock
clock_epoch=1788858000 # 2026-09-08 09:00:00 UTC
HERDR_PLUGIN_TIMEZONE="UTC" assert_eq "$(HERDR_PLUGIN_TIMEZONE="UTC" fmt_clock "$clock_epoch")" "09:00" 'fmt_clock formats in UTC with HERDR_PLUGIN_TIMEZONE'
HERDR_PLUGIN_TIMEZONE="Europe/Berlin" assert_eq "$(HERDR_PLUGIN_TIMEZONE="Europe/Berlin" fmt_clock "$clock_epoch")" "11:00" 'fmt_clock formats in CEST (+2) with HERDR_PLUGIN_TIMEZONE'
printf '%s\n' '{"timezone":"UTC"}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
assert_eq "$(fmt_clock "$clock_epoch")" "09:00" 'fmt_clock respects timezone from config.json'
assert_eq "$(to_bold_digits "09:00")" "𝟬𝟵:𝟬𝟬" 'to_bold_digits converts ascii numbers to mathematical sans-serif bold glyphs'
rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.json"
# 5. Timer scheduling and cancellation
schedule_wake 100
assert_cmd "[[ -s \"$TIMER_PID_FILE\" ]]" 'schedule_wake records timer PID'
tpid=$(cat "$TIMER_PID_FILE")
assert_cmd "pid_is_live \"$tpid\"" 'scheduled timer process is running'
schedule_wake 100
replacement_tpid=$(cat "$TIMER_PID_FILE")
assert_cmd "[[ \"$tpid\" != \"$replacement_tpid\" ]] && ! pid_is_live \"$tpid\" && pid_is_live \"$replacement_tpid\"" 'rescheduling retains at most one live timer'
cancel_timer
assert_cmd "[[ ! -f \"$TIMER_PID_FILE\" ]]" 'cancel_timer removes PID file'
assert_cmd "! pid_is_live \"$replacement_tpid\"" 'cancel_timer stops the scheduled process'
# 6. Declarative view sort mode cycling and persistence
source "$ROOT/lib/view.sh"
last_rpc_method=""
last_rpc_params=""
herdr_view_rpc() { last_rpc_method="$1"; last_rpc_params="$2"; }

rm -f "$SORT_STATE_FILE"
assert_eq "$(get_sort_mode)" "native" 'default sort mode is native'
set_sort_mode "expiry"
assert_eq "$(get_sort_mode)" "expiry" 'set_sort_mode updates sort_mode.json'
assert_eq "$last_rpc_method" "agent.view.set" 'set_sort_mode expiry issues agent.view.set'
if [[ "$last_rpc_params" == *'"label": "expiry"'* ]]; then ok 'set_sort_mode expiry passes expiry label'; else not_ok 'set_sort_mode expiry passes expiry label'; fi

# Toggle tests: expiry <-> native
toggle_sort_mode >/dev/null
assert_eq "$(get_sort_mode)" "native" 'toggle from expiry yields native'
assert_eq "$last_rpc_method" "agent.view.clear" 'native mode clears agent view'

toggle_sort_mode >/dev/null
assert_eq "$(get_sort_mode)" "expiry" 'toggle from native yields expiry'
assert_eq "$last_rpc_method" "agent.view.set" 'expiry mode issues agent.view.set'
if [[ "$last_rpc_params" == *'"label": "expiry"'* ]]; then ok 'expiry mode passes expiry label'; else not_ok 'expiry mode passes expiry label'; fi

# 7. Provider-specific helper tests are covered by the Pi and Claude
# fixtures above; no external provider helper is required.
# Reset fixture overrides before end-to-end watcher checks.
unset -f codex_usage

# 8. Stale cache regression: session A -> session B in same focused pane
init_state
now=$(date +%s)
last_reported="" last_deadline=""
report_pane() { last_reported="$3"; last_deadline="${10:-}"; }
clear_pane() { last_reported="CLEARED"; last_deadline=""; }

# Session A has hot cache state in paneRestart
sig_a="codex|sess-A|m1|p1|1000|800|0|0|0"
jq -n --arg sig "$sig_a" --argjson now "$now" \
  '{active:{agent:"codex",session_id:"sess-A",model:"m1",provider:"p1",signature:$sig,hit_at:($now-60),deadline:($now+240),input:1000,read:800,write:0,write5m:0,write1h:0},observations:[]}' \
  >"$(state_path paneRestart)"

# Session B starts — same pane, same agent, different session_id, no usage yet
codex_usage() { return 1; }
update_pane paneRestart codex sess-B
assert_cmd '[[ "$(jq -r ".active" "$(state_path paneRestart)")" == "null" ]]' \
  'stale cache: session A state cleared when session B has no usage'

# Session B produces its first usage
codex_usage() { printf 'codex\tsess-B\t%s\t500\t300\t0\t0\t0\tm2\tp2\t/same\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
update_pane paneRestart codex sess-B
assert_cmd '[[ "$(jq -r ".active.session_id" "$(state_path paneRestart)")" == "sess-B" ]]' \
  'stale cache: session B metrics appear after first usage'
assert_cmd '[[ "$(jq -r ".active.read" "$(state_path paneRestart)")" == "300" ]]' \
  'stale cache: session B counters are correct'
unset -f codex_usage
source "$ROOT/lib/codex.sh"

# 9. Same-pane restart is covered by the focused state tests above.

# 10. No downloaded helper is required in this fork.

# 11. Auto-adaptive display-agent and mobile layout detection
da_reports="$TMP/display-agent-reports"
da_config_dir="$TMP/da-config"
mkdir -p "$da_config_dir"

# Default auto mode on desktop (width > 64) clears display agent
rm -f "$da_reports"
FAKE_REPORTS="$da_reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" HERDR_CURRENT_WIDTH=120 bash -c \
  'source "$1/lib/core.sh"; report_pane pDesktop codex "❄ ⇣500" 15000' _ "$ROOT"
assert_cmd "grep -q 'pDesktop.*--clear-display-agent' \"$da_reports\"" 'auto mode on desktop clears display-agent'
assert_cmd "! grep -q 'pDesktop.*--display-agent' \"$da_reports\"" 'auto mode on desktop does not inject display-agent'

# Default auto mode on mobile width (<= 64) injects display agent
rm -f "$da_reports"
FAKE_REPORTS="$da_reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" HERDR_CURRENT_WIDTH=50 bash -c \
  'source "$1/lib/core.sh"; report_pane pMobile codex "❄ ⇣500" 15000' _ "$ROOT"
assert_cmd "grep -q 'pMobile.*--display-agent codex \[❄ ⇣500\]' \"$da_reports\"" 'auto mode on mobile width injects display-agent'

# Termux environment injects display agent regardless of width
rm -f "$da_reports"
FAKE_REPORTS="$da_reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" HERDR_CURRENT_WIDTH=120 TERMUX_VERSION="0.118.0" bash -c \
  'source "$1/lib/core.sh"; report_pane pTermux codex "❄ ⇣500" 15000' _ "$ROOT"
assert_cmd "grep -q 'pTermux.*--display-agent codex \[❄ ⇣500\]' \"$da_reports\"" 'auto mode under Termux injects display-agent'

# Config override: display_agent = "never" forces clear on mobile
rm -f "$da_reports"
printf '{"display_agent":"never"}\n' >"$da_config_dir/config.json"
FAKE_REPORTS="$da_reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" HERDR_PLUGIN_CONFIG_DIR="$da_config_dir" HERDR_CURRENT_WIDTH=50 bash -c \
  'source "$1/lib/core.sh"; report_pane pNever codex "❄ ⇣500" 15000' _ "$ROOT"
assert_cmd "grep -q 'pNever.*--clear-display-agent' \"$da_reports\"" 'display_agent=never suppresses display-agent on mobile'

# Config override: display_agent = "always" forces injection on desktop
rm -f "$da_reports"
printf '{"display_agent":"always"}\n' >"$da_config_dir/config.json"
FAKE_REPORTS="$da_reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" HERDR_PLUGIN_CONFIG_DIR="$da_config_dir" HERDR_CURRENT_WIDTH=120 bash -c \
  'source "$1/lib/core.sh"; report_pane pAlways codex "❄ ⇣500" 15000' _ "$ROOT"
assert_cmd "grep -q 'pAlways.*--display-agent codex \[❄ ⇣500\]' \"$da_reports\"" 'display_agent=always injects display-agent on desktop'

# Snapshot layout tests are covered by Herdr integration smoke tests.

# Trailing rerun flag on lock contention
rerun_lock_dir="$STATE_DIR/watcher.lock"
rm -rf "$rerun_lock_dir"
mkdir -p "$rerun_lock_dir"
printf '%s\n' "$$" >"$rerun_lock_dir/pid"
assert_cmd "! acquire_lock" 'acquire_lock returns 1 when lock is held by live process'
assert_cmd "[[ -f \"$rerun_lock_dir/rerun\" ]]" 'contended acquire_lock touches rerun flag'
rm -rf "$rerun_lock_dir"

exit "$fail"
