Optimize and Extend the Log Analyzer in examples/log_analyzer/analyzer.py:

1. **Fix the Bug**: The current regex `\.\d{3}` fails to match timestamps with fewer than 3 digits of milliseconds (e.g., `.45` or `.1`). Update the regex to handle variable millisecond lengths.
2. **Optimize**: The script uses `f.readlines()` which loads the entire file into memory. Refactor `parse_logs` to process the file line-by-line using a generator or direct iteration, yielding results instead of returning a giant list.
3. **New Feature**: Add a `--json` command-line argument. If present, print the report as a JSON object `{"INFO": 50, ...}` instead of the text report.
4. Verify by running `python examples/log_analyzer/analyzer.py examples/log_analyzer/server.log` (and with `--json`).
5. Reply DONE.