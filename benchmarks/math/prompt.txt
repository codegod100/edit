Perform a Legacy Migration & Dead Code Elimination on examples/legacy_math/:
1. In core.zig, define 'pub const Number = struct { value: f64 };'.
2. Refactor 'core.add', 'core.subtract', and 'utils.log_value' to accept and return 'Number' instead of 'f64'.
3. ANALYZE dependencies starting from main.zig. Identify functions that are NOT reachable from main.zig (even if they call each other).
   - Hint: 'calculate_hypotenuse' calls 'multiply_legacy', but is 'calculate_hypotenuse' called by main?
4. DELETE all unreachable functions from core.zig, advanced.zig, and utils.zig.
5. Update main.zig to use the new Number struct (e.g. 'Number{ .value = 10.0 }').
6. Ensure 'zig run examples/legacy_math/main.zig' works.
7. Reply DONE.