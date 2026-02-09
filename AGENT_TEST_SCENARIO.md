# Agent Test Scenario: Idempotent Feature Addition

## Objective
Implement a new multiplication feature in the `examples/calculator` mini project.

## Requirements
1. **Multiplication Function:**
   - Add a `pub fn multiply(a: i32, b: i32) i32` function to `examples/calculator/main.zig`.
   - It should return the product of `a` and `b`.

2. **Integration:**
   - Update the `main` function to call `multiply(10, 5)` and print the result.
   - Example output line: `10 * 5 = 50`.

3. **Idempotency:**
   - The implementation must be idempotent. If you run this scenario again, it should not duplicate the function or the print statement.
   - Check if the function or print call already exists before adding it.

## Strategy
1. **Explore:** Read `examples/calculator/main.zig` to understand current state.
2. **Implement:** Add the `multiply` function and update `main`.
3. **Verify:** Use `zig run examples/calculator/main.zig` to ensure it works.