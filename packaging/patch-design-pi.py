#!/usr/bin/env python3
"""Patch only the staged design stack for Mash Pi and local Penpot setup."""

import sys
from pathlib import Path


def replace(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"expected one Mash integration hook in {path}")
    path.write_text(text.replace(old, new))


def main(stack: Path, source: Path) -> None:
    helper = source / "scripts/od_daemon.py"
    if not helper.is_file():
        raise SystemExit("the pinned design stack has no od_daemon.py")
    target = stack / "lib/od_daemon.py"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(helper.read_bytes())
    mds = stack / "bin/mds"
    # First-launch wizard stores the local account in penpot.env. Reuse it
    # without putting the password in the wizard's child-process environment.
    replace(
        mds,
        '  if [ "${MASH_DESIGN_NONINTERACTIVE:-}" = "1" ] || [ ! -t 0 ]; then',
        '  if [ -n "${MASH_DATA_DIR:-}" ] && ! env_value_empty PENPOT_LOCAL_EMAIL '
        '&& ! env_value_empty PENPOT_LOCAL_PASSWORD; then\n'
        '    PENPOT_SETUP_EMAIL="$(env_value PENPOT_LOCAL_EMAIL)"\n'
        '    PENPOT_SETUP_PASSWORD="$(env_value PENPOT_LOCAL_PASSWORD)"\n'
        '    PENPOT_SETUP_FULLNAME="${PENPOT_SETUP_EMAIL%%@*}"\n'
        '    return 0\n'
        '  fi\n'
        '  if [ "${MASH_DESIGN_NONINTERACTIVE:-}" = "1" ] || [ ! -t 0 ]; then',
    )
    # Keep the saved password out of host process arguments. Penpot's own
    # manage.py still receives it inside its local backend container.
    replace(
        mds,
        '  if [ -n "${PENPOT_SETUP_PASSWORD:-}" ]; then\n'
        '    set_env_value PENPOT_LOCAL_PASSWORD "$PENPOT_SETUP_PASSWORD"\n'
        '  fi',
        '  if [ -n "${PENPOT_SETUP_PASSWORD:-}" ] && '\
        '    [ "$(env_value PENPOT_LOCAL_PASSWORD)" != "$PENPOT_SETUP_PASSWORD" ]; then\n'
        '    set_env_value PENPOT_LOCAL_PASSWORD "$PENPOT_SETUP_PASSWORD"\n'
        '  fi',
    )
    replace(
        mds,
        '    out="$(compose exec -T penpot-backend python3 manage.py create-profile \\\n'
        '      -n "$PENPOT_SETUP_FULLNAME" \\\n'
        '      -e "$PENPOT_SETUP_EMAIL" \\\n'
        '      -p "$PENPOT_SETUP_PASSWORD" \\\n'
        '      --skip-tutorial --skip-walkthrough 2>&1)"',
        '    out="$(printf \'%s\\n\' "$PENPOT_SETUP_PASSWORD" | compose exec -T penpot-backend sh -c '\
        '\'IFS= read -r password; exec python3 manage.py create-profile '\
        '-n "$1" -e "$2" -p "$password" --skip-tutorial --skip-walkthrough\' '\
        'sh "$PENPOT_SETUP_FULLNAME" "$PENPOT_SETUP_EMAIL" 2>&1)"',
    )
    replace(
        mds,
        '  python3 - "$body" "$email" "$password" <<\'PY\'\n'
        'import json, sys\nfrom pathlib import Path\n'
        'Path(sys.argv[1]).write_text(json.dumps({"email": sys.argv[2], "password": sys.argv[3]}), encoding="utf-8")\n'
        'PY',
        '  printf \'%s\' "$password" | python3 -c '\
        '\'import json,sys; from pathlib import Path; '\
        'Path(sys.argv[1]).write_text(json.dumps({"email": sys.argv[2], "password": sys.stdin.read()}), encoding="utf-8")\' '\
        '"$body" "$email"',
    )
    # The toolkit's standalone installer configures Cursor in the real home.
    # Mash already ships its own penpot-local Pi MCP; never write ~/.cursor.
    replace(
        mds,
        '  local dest="${HOME}/.cursor/mcp.json"',
        '  local dest="${HOME}/.cursor/mcp.json"\n'
        '  if [ -n "${MASH_DATA_DIR:-}" ]; then\n'
        '    dest="${PI_CODING_AGENT_DIR:-${MASH_DATA_DIR}/pi/agent}/mcp.json"\n'
        '  fi',
    )
    replace(mds, '  mkdir -p "${HOME}/.cursor"', '  mkdir -p "$(dirname "$dest")"')
    replace(mds, '        "PENPOT_LOGIN_PASSWORD": env.get("PENPOT_LOCAL_PASSWORD", ""),\n', '')
    replace(
        mds,
        '  print_info "Updated penpot-local in ~/.cursor/mcp.json"',
        '  if [ -n "${MASH_DATA_DIR:-}" ]; then chmod 600 "$dest"; fi\n'
        '  print_info "Updated penpot-local in $dest"',
    )
    replace(
        mds,
        'maybe_link_bin() {\n  local dest="${HOME}/.local/bin"',
        'maybe_link_bin() {\n  [ -z "${MASH_DATA_DIR:-}" ] || return 0\n'
        '  local dest="${HOME}/.local/bin"',
    )
    # An owner who starts Docker without restarting Mash can run `mds start`;
    # setup then consumes the credentials the wizard already saved.
    replace(
        mds,
        'cmd_start() {\n  require_compose_file\n  require_env\n  require_strong_secret',
        'cmd_start() {\n  require_compose_file\n  require_env\n'
        '  if [ -n "${MASH_DATA_DIR:-}" ] && ! env_value_empty PENPOT_LOCAL_EMAIL '
        '&& ! env_value_empty PENPOT_LOCAL_PASSWORD && env_value_empty PENPOT_ACCESS_TOKEN; then\n'
        '    cmd_setup --skip-auth\n'
        '  fi\n'
        '  require_strong_secret',
    )
    replace(
        mds,
        "  ! env_value_empty OPENAI_API_KEY && return 0\n  return 1",
        '  ! env_value_empty OPENAI_API_KEY && return 0\n'
        '  [ -x "${HOME}/.mash/bin/mash-design-pi-sync" ] && '
        '"${HOME}/.mash/bin/mash-design-pi-sync" --configured && return 0\n'
        '  return 1',
    )
    replace(
        mds,
        "  if ! wait_open_design; then\n    return 0\n  fi\n  print_step \"Applying agent credentials to harnesses...\"",
        '  if ! wait_open_design; then\n'
        '    if [ -x "${HOME}/.mash/bin/mash-design-pi-sync" ] && '
        '"${HOME}/.mash/bin/mash-design-pi-sync" --configured; then\n'
        '      print_error "OpenDesign is not ready; Mash Pi was not configured"\n'
        '      return 1\n'
        '    fi\n'
        '    return 0\n'
        '  fi\n'
        '  print_step "Applying agent credentials to harnesses..."',
    )
    replace(
        mds,
        "  local unlocked=0\n  if ! env_value_empty CURSOR_API_KEY; then",
        '  local unlocked=0\n'
        '  local pi_sync="${HOME}/.mash/bin/mash-design-pi-sync"\n'
        '  if [ -x "$pi_sync" ] && "$pi_sync" --configured; then\n'
        '    "$pi_sync" "$STACK" "$PROJECT_NAME" || return 1\n'
        '    unlocked=1\n'
        '  fi\n'
        '  if ! env_value_empty CURSOR_API_KEY; then',
    )
    replace(
        target,
        'RUN_SETTING_ENV_KEYS = ("OPEN_DESIGN_RUN_AGENT", "OPEN_DESIGN_RUN_MODEL")',
        'RUN_SETTING_ENV_KEYS = ("OPEN_DESIGN_RUN_AGENT", "OPEN_DESIGN_RUN_MODEL", "MASH_DESIGN_PI_READY")',
    )
    replace(
        target,
        'if "pi" in path and anthropic_or_openai:',
        'if "pi" in path and (anthropic_or_openai or environ.get("MASH_DESIGN_PI_READY") == "1"):',
    )
    replace(
        stack / "docker-compose.yaml",
        "      HOME: /home/open-design\n      OD_BIND_HOST:",
        "      HOME: /home/open-design\n      PI_CODING_AGENT_DIR: /home/open-design/.mash-pi-agent\n      OD_BIND_HOST:",
    )
    # The design container must understand the same built-in model catalog as
    # Mash's host Pi; otherwise a wizard-selected model may not exist there.
    replace(stack / "docker/opendesign/Dockerfile", "ARG PI_VERSION=0.87.1", "ARG PI_VERSION=1.1.0")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: patch-design-pi.py STAGED_STACK PINNED_SOURCE")
    main(Path(sys.argv[1]), Path(sys.argv[2]))
