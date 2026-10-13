import json
import os
import runpy
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "helpers/mash-design-pi-sync"
SYNC = runpy.run_path(str(HELPER))


class DesignPiSyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / ".mash"
        self.agent = self.root / "pi/agent"
        self.stack = self.root / "local/share/mash/design"
        self.agent.mkdir(parents=True)
        self.stack.mkdir(parents=True)
        (self.root / "setup").mkdir()
        (self.stack / "docker-compose.yaml").write_text("services: {}\n")
        (self.stack / "penpot.env").write_text("PENPOT_VERSION=2.16.2\nOPEN_DESIGN_RUN_MODEL=\n")

    def configure(self):
        (self.agent / "settings.json").write_text(json.dumps({"defaultProvider": "omniroute", "defaultModel": "route-model", "packages": ["npm:pi-ask-user"]}))
        (self.agent / "auth.json").write_text(json.dumps({"omniroute": {"type": "api_key", "key": "fake-private-key"}, "anthropic": {"type": "api_key", "key": "do-not-copy"}}))
        (self.agent / "models.json").write_text(json.dumps({"providers": {"omniroute": {"baseUrl": "https://example.invalid/v1", "api": "openai-responses", "models": [{"id": "route-model"}]}}}))

    def test_only_selected_api_key_and_model_are_projected(self):
        self.configure()
        provider, model, files = SYNC["selection"](self.root)
        self.assertEqual((provider, model), ("omniroute", "route-model"))
        self.assertEqual(files["settings.json"], {"defaultProvider": "omniroute", "defaultModel": "route-model", "defaultThinkingLevel": "medium"})
        self.assertEqual(list(files["auth.json"]), ["omniroute"])
        self.assertNotIn("do-not-copy", json.dumps(files))
        self.assertEqual(files["models.json"]["providers"]["omniroute"]["api"], "openai-responses")

    def test_writes_agent_and_model_without_a_key_in_env(self):
        self.configure()
        SYNC["write_env"](self.stack / "penpot.env", "omniroute", "route-model")
        text = (self.stack / "penpot.env").read_text()
        self.assertIn("PENPOT_VERSION=2.16.2", text)
        self.assertIn("OPEN_DESIGN_RUN_AGENT=pi", text)
        self.assertIn("OPEN_DESIGN_RUN_MODEL=omniroute/route-model", text)
        self.assertIn("MASH_DESIGN_PI_READY=1", text)
        self.assertNotIn("fake-private-key", text)
        self.assertEqual((self.stack / "penpot.env").stat().st_mode & 0o777, 0o600)

    def test_sync_calls_docker_without_keys_in_arguments(self):
        self.configure()
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir()
        docker = bin_dir / "docker"
        docker.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$TEST_DOCKER_LOG\"\ncase \"$*\" in *--list-models*) printf 'provider model\\nomniroute route-model\\n';; esac\n")
        docker.chmod(0o755)
        log = Path(self.tmp.name) / "docker.log"
        old_path, old_log = os.environ.get("PATH", ""), os.environ.get("TEST_DOCKER_LOG")
        os.environ["PATH"] = f"{bin_dir}:{old_path}"
        os.environ["TEST_DOCKER_LOG"] = str(log)
        try:
            SYNC["sync"](self.root, self.stack, "test-design")
        finally:
            os.environ["PATH"] = old_path
            if old_log is None:
                os.environ.pop("TEST_DOCKER_LOG", None)
            else:
                os.environ["TEST_DOCKER_LOG"] = old_log
        calls = log.read_text()
        self.assertIn(" cp ", calls)
        self.assertIn("open-design pi --list-models omniroute/route-model", calls)
        self.assertNotIn("fake-private-key", calls)
        self.assertEqual(len(list((self.root / "setup").iterdir())), 0)

    def test_staged_patch_changes_only_the_copy(self):
        source = Path(self.tmp.name) / "source"
        (source / "scripts").mkdir(parents=True)
        (source / "scripts/od_daemon.py").write_text(
            'RUN_SETTING_ENV_KEYS = ("OPEN_DESIGN_RUN_AGENT", "OPEN_DESIGN_RUN_MODEL")\n'
            'if "pi" in path and anthropic_or_openai:\n    out.append("pi")\n'
        )
        (self.stack / "bin").mkdir()
        (self.stack / "bin/mds").write_text(
            '  if [ "${MASH_DESIGN_NONINTERACTIVE:-}" = "1" ] || [ ! -t 0 ]; then\n'
            '  if [ -n "${PENPOT_SETUP_PASSWORD:-}" ]; then\n'
            '    set_env_value PENPOT_LOCAL_PASSWORD "$PENPOT_SETUP_PASSWORD"\n'
            '  fi\n'
            '    out="$(compose exec -T penpot-backend python3 manage.py create-profile \\\n'
            '      -n "$PENPOT_SETUP_FULLNAME" \\\n'
            '      -e "$PENPOT_SETUP_EMAIL" \\\n'
            '      -p "$PENPOT_SETUP_PASSWORD" \\\n'
            '      --skip-tutorial --skip-walkthrough 2>&1)"\n'
            '  python3 - "$body" "$email" "$password" <<\'PY\'\n'
            'import json, sys\nfrom pathlib import Path\n'
            'Path(sys.argv[1]).write_text(json.dumps({"email": sys.argv[2], "password": sys.argv[3]}), encoding="utf-8")\n'
            'PY\n'
            '  local dest="${HOME}/.cursor/mcp.json"\n'
            '  mkdir -p "${HOME}/.cursor"\n'
            '        "PENPOT_LOGIN_PASSWORD": env.get("PENPOT_LOCAL_PASSWORD", ""),\n'
            '  print_info "Updated penpot-local in ~/.cursor/mcp.json"\n'
            'maybe_link_bin() {\n  local dest="${HOME}/.local/bin"\n'
            'cmd_start() {\n  require_compose_file\n  require_env\n  require_strong_secret\n'
            "  ! env_value_empty OPENAI_API_KEY && return 0\n  return 1\n"
            "  if ! wait_open_design; then\n    return 0\n  fi\n  print_step \"Applying agent credentials to harnesses...\"\n"
            "  local unlocked=0\n  if ! env_value_empty CURSOR_API_KEY; then\n"
        )
        (self.stack / "docker-compose.yaml").write_text(
            "      HOME: /home/open-design\n      OD_BIND_HOST: 0.0.0.0\n"
        )
        (self.stack / "docker/opendesign").mkdir(parents=True)
        (self.stack / "docker/opendesign/Dockerfile").write_text("ARG PI_VERSION=0.87.1\n")
        patch = runpy.run_path(str(HELPER.parents[1] / "patch-design-pi.py"))
        patch["main"](self.stack, source)
        patched_mds = (self.stack / "bin/mds").read_text()
        self.assertIn("mash-design-pi-sync", patched_mds)
        self.assertIn('PENPOT_SETUP_PASSWORD="$(env_value PENPOT_LOCAL_PASSWORD)"', patched_mds)
        self.assertNotIn('python3 - "$body" "$email" "$password"', patched_mds)
        self.assertNotIn('-p "$PENPOT_SETUP_PASSWORD"', patched_mds)
        self.assertIn('dest="${PI_CODING_AGENT_DIR:-${MASH_DATA_DIR}/pi/agent}/mcp.json"', patched_mds)
        self.assertNotIn('"PENPOT_LOGIN_PASSWORD":', patched_mds)
        self.assertIn('cmd_setup --skip-auth', patched_mds)
        self.assertIn("PI_CODING_AGENT_DIR", (self.stack / "docker-compose.yaml").read_text())
        self.assertIn("MASH_DESIGN_PI_READY", (self.stack / "lib/od_daemon.py").read_text())
        self.assertIn("ARG PI_VERSION=1.1.0", (self.stack / "docker/opendesign/Dockerfile").read_text())
        self.assertNotIn("MASH_DESIGN_PI_READY", (source / "scripts/od_daemon.py").read_text())

    def test_rejects_missing_or_non_api_key_auth(self):
        self.configure()
        data = json.loads((self.agent / "auth.json").read_text())
        data["omniroute"] = {"type": "oauth", "token": "fake"}
        (self.agent / "auth.json").write_text(json.dumps(data))
        self.assertIsNone(SYNC["selection"](self.root))
        (self.agent / "auth.json").unlink()
        self.assertIsNone(SYNC["selection"](self.root))


if __name__ == "__main__":
    unittest.main()
