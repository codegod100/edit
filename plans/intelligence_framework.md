# Z-Bench: Intelligence Testing Framework

**Goal**: Replace the monolithic `test-zagent-intelligence.sh` with a modular, scalable benchmarking suite to measure agent performance, regression, and reliability.

## 1. Directory Structure

We will move tests to a top-level `benchmarks/` directory. Each test case is self-contained.

```text
benchmarks/
├── weather/
│   ├── prompt.txt      # The exact instruction given to the agent
│   ├── setup.sh        # Scaffolds the initial broken/legacy state
│   ├── verify.sh       # Exits 0 if success, 1 if fail
│   └── config.json     # Metadata (max_steps, tags, expected_tools)
├── math/
│   ...
├── kv_store/
│   ...
└── complex_c/
    ...
```

## 2. The Runner (`scripts/zbench.py`)

A Python script to orchestrate the benchmarks. Python is chosen for rapid development of subprocess management and text parsing capabilities.

### Key Features:
-   **Isolation**: Runs each test in a clean temporary directory (`/tmp/zbench_runs/<run_id>/<test_name>`).
-   **Parallelism**: Can run multiple tests (or multiple iterations of one test) in parallel (optional future scope, start sequential).
-   **Metrics Collection**:
    -   **Pass/Fail**: Did `verify.sh` exit 0?
    -   **Steps**: Parsed from the agent's output log.
    -   **Time**: Wall clock execution time.
-   **Reporting**: Generates a summary table in the terminal and a JSON report for CI.

## 3. Migration Plan

1.  **Scaffold**: Create the `benchmarks/` directory tree.
2.  **Port**: Extract the `scaffold_*` functions from the old script into individual `setup.sh` files.
3.  **Port**: Extract the `CHALLENGE_*` strings into `prompt.txt` files.
4.  **Port**: Create `verify.sh` scripts based on the logic (or imply it from the prompt's success criteria).
5.  **Build Runner**: Implement `scripts/zbench.py`.
6.  **Verify**: Run the new suite and confirm it matches the old script's behavior.
7.  **Cleanup**: Delete the old shell script.

## 4. Future Improvements
-   **LLM Judge**: Use a cheap LLM to evaluate the *quality* of the code changes, not just functionality.
-   **Step-by-Step Replay**: Ability to replay a session log to analyze where it went wrong.
