"""Harbor adapter for the BEAM-host Living Dictionary release.

Installs a self-contained linux mix release (built by
bench/release/Dockerfile.release, published as a GitHub release asset)
into the task container, then drives it through LdHost.CLI.main_from_env.

    PYTHONPATH=. harbor run -d terminal-bench@2.0 \
      -a bench.harbor_ld_beam:LivingDictBeam -m xai/grok-4.6 -l 1

Provider configuration and API credentials flow in via Harbor `--agent-env`;
they are never printed here. For OAuth-backed OpenAI runs, point
`LIVINGDICT_PLANNER_ENDPOINT` at a short-lived host-side Responses bridge so
Codex credentials remain outside the task container.
The wrapped command ALWAYS exits 0 — the release's honest exit code lands
in /logs/agent/exit_status instead, so Harbor's verifier (not
NonZeroAgentExitCodeError) decides the reward.

v2 additions for the warm-across-tasks driver (bench/tb_warm.sh):
  - dict_seed_b64: a base64'd `tar -cz` of a dictionary `words/` tree,
    extracted into /logs/agent/dict before the host starts. It rides
    inside the agent command string (shlex-quoted), never via --ae.
  - LD_DICTIONARY=/logs/agent/dict is always exported, so the trial's
    grown dictionary lands under /logs/agent and Harbor collects it.
  - allow_model_checks: exports LD_ALLOW_MODEL_CHECKS=1 (default on).
"""

from __future__ import annotations

import shlex

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

AGENT_DIR = "/installed-agent/ld_host"


class LivingDictBeam(BaseInstalledAgent):
    """Run the packaged BEAM Living Dictionary host in a Harbor environment."""

    SUPPORTS_ATIF = False

    def __init__(
        self,
        *args,
        release_tag: str = "beam-v0.1.1",
        release_url_template: str = (
            "https://github.com/pyrex41/living_dict/releases/download/"
            "{tag}/ld_host-0.1.0-linux-{arch}.tar.gz"
        ),
        max_episodes: int = 8,
        agent_timeout_sec: int = 3600,
        allow_model_checks: bool = True,
        dict_seed_b64: str | None = None,
        **kwargs,
    ):
        super().__init__(*args, **kwargs)
        self._release_tag = release_tag
        self._release_url_template = release_url_template
        self._max_episodes = int(max_episodes)
        self._agent_timeout_sec = int(agent_timeout_sec)
        self._allow_model_checks = bool(allow_model_checks)
        self._dict_seed_b64 = dict_seed_b64

    @staticmethod
    def name() -> str:
        return "livingdict-beam"

    def get_version_command(self) -> str:
        return f"{AGENT_DIR}/bin/ld_host version"

    async def install(self, environment: BaseEnvironment) -> None:
        await self.ensure_system_dependencies(
            environment, ("curl", "ca_certificates", "tar")
        )
        # ERTS needs libssl3 at runtime; apt-only guard keeps other
        # package managers from tripping over the Debian package name.
        await self.exec_as_root(
            environment,
            command=(
                "if command -v apt-get >/dev/null 2>&1; then "
                "apt-get update && "
                "DEBIAN_FRONTEND=noninteractive apt-get install -y libssl3; "
                "fi"
            ),
            timeout_sec=600,
        )
        url = self._release_url_template.replace("{tag}", self._release_tag)
        quoted_template = shlex.quote(url)  # still contains the literal {arch}
        await self.exec_as_root(
            environment,
            command=(
                "set -eu; "
                "case \"$(uname -m)\" in "
                "aarch64|arm64) arch=aarch64 ;; "
                "x86_64|amd64) arch=x86_64 ;; "
                "*) echo \"unsupported arch: $(uname -m)\" >&2; exit 1 ;; "
                "esac; "
                f"url=$(printf %s {quoted_template} | sed \"s/{{arch}}/$arch/\"); "
                f"rm -rf {AGENT_DIR}; mkdir -p {AGENT_DIR}; "
                f"curl -fsSL \"$url\" | tar -xz -C {AGENT_DIR}; "
                f"chmod -R a+rX {AGENT_DIR}"
            ),
            timeout_sec=600,
        )
        # Critic-boot probe: the release must resolve its bundled shen-erl
        # artifact. A raise here is correct — install failures are infra.
        await self.exec_as_root(
            environment,
            command=(
                f"{AGENT_DIR}/bin/ld_host eval "
                "'Application.ensure_all_started(:ld_host); "
                "IO.puts(LdHost.Critic.engine())' | grep -qx beam"
            ),
            timeout_sec=300,
        )

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        goal = shlex.quote(instruction)
        seed_setup = ""
        if self._dict_seed_b64:
            seed = shlex.quote(self._dict_seed_b64)
            seed_setup = (
                "mkdir -p /logs/agent/dict; "
                f"printf '%s' {seed} | base64 -d | tar -xz -C /logs/agent/dict; "
            )
        model_checks = (
            "export LD_ALLOW_MODEL_CHECKS=1; " if self._allow_model_checks else ""
        )
        await self.exec_as_agent(
            environment,
            command=(
                "mkdir -p /logs/agent/run /logs/agent/dict; "
                f"{seed_setup}"
                "export LD_DICTIONARY=/logs/agent/dict; "
                f"{model_checks}"
                f"printf %s {goal} > /logs/agent/goal.txt; "
                "export LD_GOAL_FILE=/logs/agent/goal.txt "
                "LD_CWD=\"$(pwd)\" LD_RUN_DIR=/logs/agent/run "
                f"LD_MAX_EPISODES={self._max_episodes} "
                "RELEASE_TMP=/tmp ELIXIR_ERL_OPTIONS=+fnu; "
                f"{AGENT_DIR}/bin/ld_host eval 'LdHost.CLI.main_from_env()' "
                "> /logs/agent/ld_host.stdout.log "
                "2> /logs/agent/ld_host.stderr.log; "
                "echo $? > /logs/agent/exit_status; "
                "exit 0"
            ),
            timeout_sec=self._agent_timeout_sec,
        )
