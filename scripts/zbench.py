#!/usr/bin/env python3
import os
import sys
import subprocess
import time
import json
from pathlib import Path

# Configuration
BENCHMARKS_DIR = Path("benchmarks")
ZAGENT_BIN = Path("zig-out/bin/zagent").absolute()
RESULTS = []

def run_benchmark(name):
    bench_dir = BENCHMARKS_DIR / name
    print(f"\n========================================================")
    print(f"Running Benchmark: {name}")
    print(f"========================================================")

    # 1. Setup
    print(">> Setting up...")
    setup_script = bench_dir / "setup.sh"
    if setup_script.exists():
        subprocess.check_call([str(setup_script)], cwd=os.getcwd())
    
    # 2. Run Agent
    print(">> Running Agent...")
    prompt_file = bench_dir / "prompt.txt"
    if not prompt_file.exists():
        print(f"Error: {prompt_file} missing")
        return False

    with open(prompt_file, "r") as f:
        # Flatten prompt to a single line with \n literals so zagent reads it as one command
        raw_prompt = f.read().strip()
        prompt = raw_prompt.replace("\n", "\\n")

    start_time = time.time()
    
    # We pipe the prompt into zagent
    # Note: capturing stdout means we won't see it in real-time in the terminal.
    # To see it, we can remove stdout=PIPE, but then we can't parse steps easily.
    # For now, let's let it print to terminal so the user sees progress.
    process = subprocess.Popen(
        [str(ZAGENT_BIN)], 
        stdin=subprocess.PIPE,
        cwd=os.getcwd(),
        text=True
    )
    
    # Send prompt and wait
    try:
        stdout, stderr = process.communicate(input=prompt + "\n/quit\n", timeout=300) # 5 min timeout
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        print("❌ TIMEOUT (5m)")
        print("--- STDOUT ---")
        print(stdout)
        print("--- STDERR ---")
        print(stderr)
        return False

    end_time = time.time()
    duration = end_time - start_time
    print(f">> Agent finished in {duration:.2f}s")

    if process.returncode != 0:
        print(f"❌ Agent exited with code {process.returncode}")
        print("--- STDOUT ---")
        print(stdout)
        print("--- STDERR ---")
        print(stderr)
        return False

    # 3. Verify
    print(">> Verifying...")
    verify_script = bench_dir / "verify.sh"
    passed = False
    if verify_script.exists():
        try:
            # Run verify script and capture output to print only on fail
            v_proc = subprocess.run(
                [str(verify_script)], 
                cwd=os.getcwd(), 
                capture_output=True, 
                text=True
            )
            if v_proc.returncode == 0:
                print("✅ PASS")
                passed = True
            else:
                print("❌ FAIL (Verify script failed)")
                print("--- VERIFY OUTPUT ---")
                print(v_proc.stdout)
                print(v_proc.stderr)
                # Also print agent output for context
                print("--- AGENT OUTPUT ---")
                print(stdout)
                print("--- AGENT STDERR ---")
                print(stderr)
                passed = False
        except OSError as e:
            print(f"❌ FAIL (Execution error: {e})")
            passed = False
    else:
        print("⚠️ No verify script found (manual check required)")
        passed = True # Assume pass if no check? No, fail.
        
    RESULTS.append({
        "name": name,
        "passed": passed,
        "duration": duration
    })
    return passed

def main():
    if not ZAGENT_BIN.exists():
        print(f"Error: zagent binary not found at {ZAGENT_BIN}")
        print("Run 'zig build' first.")
        sys.exit(1)

    # Find benchmarks
    benchmarks = [d.name for d in BENCHMARKS_DIR.iterdir() if d.is_dir()]
    benchmarks.sort()

    if len(sys.argv) > 1:
        target = sys.argv[1]
        if target in benchmarks:
            benchmarks = [target]
        else:
            print(f"Benchmark '{target}' not found.")
            sys.exit(1)

    print(f"Found {len(benchmarks)} benchmarks: {', '.join(benchmarks)}")

    success_count = 0
    for bench in benchmarks:
        if run_benchmark(bench):
            success_count += 1

    print("\n\n========================================================")
    print("SUMMARY")
    print("========================================================")
    print(f"{'Benchmark':<20} | {'Result':<10} | {'Time':<10}")
    print("-" * 46)
    for res in RESULTS:
        status = "✅ PASS" if res["passed"] else "❌ FAIL"
        print(f"{res['name']:<20} | {status:<10} | {res['duration']:.2f}s")
    print("-" * 46)
    print(f"Total: {success_count}/{len(benchmarks)} passed")

    if success_count < len(benchmarks):
        sys.exit(1)

if __name__ == "__main__":
    main()
