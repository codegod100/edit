# Harbor Quickstart for `zagent` (ZAI-first)

This repo now includes a custom Harbor agent adapter:

- Import path: `harbor_adapter.zagent_agent:ZagentHarborAgent`
- Purpose: run local `zagent` binary in Harbor task environments.

## 1) Install Harbor

```bash
uv tool install harbor
# or
pip install harbor
```

## 2) Export ZAI key

```bash
export ZAI_API_KEY="your-zai-key"
```

## 3) Make sure `zagent` binary exists locally

```bash
zig build
ls -l zig-out/bin/zagent
```

## 4) Smoke test in a task environment

```bash
harbor tasks start-env \
  -p /absolute/path/to/task \
  --agent-import-path harbor_adapter.zagent_agent:ZagentHarborAgent \
  --agent-kwarg zagent_binary_path=/absolute/path/to/zig-out/bin/zagent \
  --ae ZAI_API_KEY=$ZAI_API_KEY
```

## 5) Run a single trial

```bash
harbor trials start \
  -p /absolute/path/to/task \
  --agent-import-path harbor_adapter.zagent_agent:ZagentHarborAgent \
  --agent-kwarg zagent_binary_path=/absolute/path/to/zig-out/bin/zagent \
  --agent-kwarg provider_id=zai \
  --agent-kwarg zagent_model_id=glm-4.7 \
  --ae ZAI_API_KEY=$ZAI_API_KEY
```

## 6) Run a benchmark job (multiple tasks)

Use your Harbor dataset/task source and the same agent flags:

```bash
harbor jobs start \
  --dataset /absolute/path/to/dataset_or_registry_ref \
  --agent-import-path harbor_adapter.zagent_agent:ZagentHarborAgent \
  --agent-kwarg zagent_binary_path=/absolute/path/to/zig-out/bin/zagent \
  --agent-kwarg provider_id=zai \
  --agent-kwarg zagent_model_id=glm-4.7 \
  --ae ZAI_API_KEY=$ZAI_API_KEY
```

## Notes

- The adapter runs one prompt then sends `/quit`.
- Raw output is saved to `/logs/agent/zagent.txt` in the trial logs.
- Token/cost metrics are not parsed yet; only metadata is recorded.
