"""Harbor adapter for running Living Dictionary inside a task container.

Use with Harbor's import-path agent support:

    PYTHONPATH=. harbor run -d terminal-bench@2.1 \
      -a bench.harbor_livingdict:LivingDictionary \
      -m xai/grok-4.6 -l 1

The adapter installs the pinned Living Dictionary checkout in the container,
then runs its normal headless CLI against Harbor's task workspace. Harbor's
verifier, not Living Dictionary's optional claims, determines the reward.
"""

from __future__ import annotations

import shlex

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.agent.name import AgentName


class LivingDictionary(BaseInstalledAgent):
    """Run the Living Dictionary headless agent in a Harbor environment."""

    SUPPORTS_ATIF = False

    def __init__(
        self,
        *args,
        max_turns: int = 16,
        repo_url: str = "https://github.com/pyrex41/living_dict.git",
        repo_ref: str = "main",
        **kwargs,
    ):
        super().__init__(*args, **kwargs)
        self._max_turns = int(max_turns)
        self._repo_url = repo_url
        self._repo_ref = repo_ref

    @staticmethod
    def name() -> str:
        return "livingdict"

    def get_version_command(self) -> str:
        return "python3 /tmp/living_dict/bin/livingdict --help >/dev/null && git -C /tmp/living_dict rev-parse --short HEAD"

    async def install(self, environment: BaseEnvironment) -> None:
        repo = shlex.quote(self._repo_url)
        ref = shlex.quote(self._repo_ref)
        await self.exec_as_agent(
            environment,
            command=(
                "set -eu; "
                "rm -rf /tmp/living_dict; "
                f"git clone --depth 1 --branch {ref} {repo} /tmp/living_dict; "
                "python3 -m compileall -q /tmp/living_dict/harness/src "
                "/tmp/living_dict/client"
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
        await self.exec_as_agent(
            environment,
            command=(
                "set -o pipefail; "
                "workspace=\"$(pwd)\"; "
                "mkdir -p /logs/agent; "
                "python3 /tmp/living_dict/bin/livingdict "
                f"-p {goal} --cwd \"$workspace\" "
                f"--max-turns {self._max_turns} "
                "> /logs/agent/livingdict.stdout.json "
                "2> /logs/agent/livingdict.stderr.log"
            ),
            timeout_sec=3600,
        )


# Harbor also accepts the class under the conventional installed-agent name.
Livingdict = LivingDictionary
