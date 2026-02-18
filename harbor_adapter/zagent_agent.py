from __future__ import annotations

import json
import os
import shlex
from pathlib import Path

from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trial.paths import EnvironmentPaths


class ZagentHarborAgent(BaseAgent):
    """Minimal Harbor adapter for the local zagent binary.

    This adapter is intentionally simple:
    - Uploads a prebuilt local `zagent` binary into the sandbox.
    - Writes a minimal ZAI provider config under ~/.config/zagent.
    - Sends exactly one task instruction followed by `/quit`.
    - Stores raw agent logs in /logs/agent/zagent.txt.
    """

    def __init__(
        self,
        logs_dir: Path,
        model_name: str | None = None,
        zagent_binary_path: str = "zig-out/bin/zagent",
        provider_id: str = "zai",
        zagent_model_id: str = "glm-4.7",
        task_setup_script_path: str | None = None,
        extra_env: dict[str, str] | None = None,
        *args,
        **kwargs,
    ):
        super().__init__(logs_dir=logs_dir, model_name=model_name, *args, **kwargs)
        self._zagent_binary_path = Path(zagent_binary_path).expanduser().resolve()
        self._provider_id = provider_id
        self._zagent_model_id = zagent_model_id
        self._task_setup_script_path = (
            Path(task_setup_script_path).expanduser().resolve()
            if task_setup_script_path
            else None
        )
        self._extra_env = dict(extra_env or {})

    @staticmethod
    def name() -> str:
        return "zagent-harbor"

    def version(self) -> str | None:
        return "local"

    async def setup(self, environment: BaseEnvironment) -> None:
        if self._zagent_binary_path.exists():
            await environment.upload_file(
                source_path=self._zagent_binary_path,
                target_path="/usr/local/bin/zagent",
            )
            await environment.exec("chmod +x /usr/local/bin/zagent")
            return

        # Fallback mode for environments where file upload is unsupported
        # (for example podman-backed docker-compose without `compose cp`).
        result = await environment.exec("test -x /usr/local/bin/zagent")
        if result.return_code != 0:
            raise FileNotFoundError(
                f"zagent binary not found on host ({self._zagent_binary_path}) "
                "or in container (/usr/local/bin/zagent)"
            )

        if self._task_setup_script_path is not None:
            if not self._task_setup_script_path.exists():
                raise FileNotFoundError(f"task setup script not found: {self._task_setup_script_path}")
            await environment.upload_file(
                source_path=self._task_setup_script_path,
                target_path="/tmp/harbor_task_setup.sh",
            )
            await environment.exec("chmod +x /tmp/harbor_task_setup.sh && bash /tmp/harbor_task_setup.sh")

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        settings = {
            "providers": [
                {
                    "id": self._provider_id,
                    "env_vars": ["ZAI_API_KEY"],
                    "endpoint": "https://api.z.ai/api/coding/paas/v4/chat/completions",
                    "models_endpoint": "https://api.z.ai/api/coding/paas/v4/models",
                    "models": [self._zagent_model_id],
                    "referer": "https://z.ai/",
                    "title": "zagent",
                    "user_agent": "zagent/harbor",
                }
            ]
        }
        instruction_q = shlex.quote(instruction)
        settings_q = shlex.quote(json.dumps(settings))
        api_key_q = shlex.quote(os.environ.get("ZAI_API_KEY", ""))

        # Create zagent config in sandbox. We intentionally keep provider.env in sync
        # with runtime env so Harbor --agent-env can control credentials.
        prep_cmd = (
            f"printf %s {instruction_q} > /tmp/harbor_instruction.txt && "
            f"printf %s {settings_q} > /tmp/zagent_settings.json && "
            "mkdir -p ~/.config/zagent && "
            "cp /tmp/zagent_settings.json ~/.config/zagent/settings.json && "
            f"printf 'ZAI_API_KEY=%s\\n' {api_key_q} > ~/.config/zagent/provider.env"
        )
        await environment.exec(prep_cmd, env=self._extra_env)

        run_cmd = (
            "{ printf '/model %s/%s\\n' "
            + shlex.quote(self._provider_id)
            + " "
            + shlex.quote(self._zagent_model_id)
            + "; cat /tmp/harbor_instruction.txt; printf '\\n/quit\\n'; } "
            f"| /usr/local/bin/zagent > {EnvironmentPaths.agent_dir / 'zagent.txt'} 2>&1"
        )
        result = await environment.exec(
            command=run_cmd,
            env=self._extra_env,
        )

        context.metadata = {
            "agent_stdout_path": str(EnvironmentPaths.agent_dir / "zagent.txt"),
            "return_code": result.return_code,
            "provider_id": self._provider_id,
            "model_id": self._zagent_model_id,
        }

        if result.return_code != 0:
            # Preserve failure signal; Harbor will still run verifier.
            context.metadata["run_error"] = "zagent returned non-zero exit code"
