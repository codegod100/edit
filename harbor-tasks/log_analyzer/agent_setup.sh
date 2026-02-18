#!/usr/bin/env bash
set -euo pipefail

echo "--- Scaffolding/Resetting log_analyzer ---"
mkdir -p examples/log_analyzer

# 1. Create the inefficient and buggy Python script
cat <<'EOF' > examples/log_analyzer/analyzer.py
import sys
import re
import json

def parse_logs(filename):
    # INEFFICIENT: Reads entire file into memory
    with open(filename, 'r') as f:
        lines = f.readlines()
    
    results = []
    # BUG: Regex expects exactly 3 digits for milliseconds, but logs have variable (1-3)
    # Also expects explicit 'ERROR' or 'INFO' but sometimes it's 'WARN'
    pattern = re.compile(r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\] (\w+): (.*)$')
    
    for line in lines:
        match = pattern.match(line)
        if match:
            timestamp, level, message = match.groups()
            results.append({
                'timestamp': timestamp,
                'level': level,
                'message': message
            })
    return results

def generate_report(data):
    counts = {}
    for entry in data:
        lvl = entry['level']
        counts[lvl] = counts.get(lvl, 0) + 1
    
    print("Log Report")
    print("==========")
    for lvl, count in counts.items():
        print(f"{lvl}: {count}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python analyzer.py <logfile>")
        sys.exit(1)
        
    logfile = sys.argv[1]
    data = parse_logs(logfile)
    generate_report(data)
EOF

# 2. Create a sample log file with edge cases
# - WARN level (not handled by original comment logic, but regex \w+ catches it?)
# - Variable milliseconds (bug trigger)
cat <<'EOF' > examples/log_analyzer/server.log
[2023-10-01 10:00:01.123] INFO: Server started
[2023-10-01 10:00:02.45] WARN: Configuration loading took too long
[2023-10-01 10:00:03.1] ERROR: Database connection failed
[2023-10-01 10:00:04.000] INFO: Retrying connection
[2023-10-01 10:00:05.123] INFO: Connection established
EOF

# Add more lines to make it "large" (simulated)
for i in {1..100}; do
    echo "[2023-10-01 10:01:00.$i] INFO: Processing request $i" >> examples/log_analyzer/server.log
done
