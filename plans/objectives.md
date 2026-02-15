# Objectives

## Current Status

### ✅ Completed
- **Modularization**: Split monolithic files into `ai_bridge/` and `model_loop/` modules
- **HTTP Client Fix**: Replaced Zig `std.http.Client` with curl subprocess (fixes empty response bug)
- **Memory Leaks**: Fixed arena allocator issues for provider specs and per-turn allocations
- **Error Handling**: Better handling for empty responses and API errors

### 🔄 In Progress
- **OpenRouter Integration**: Currently receiving Clerk 502 authentication errors
  - Direct curl commands work successfully
  - Subprocess curl calls return 502 from OpenRouter/Clerk
  - Likely: rate limiting, timing, or encoding issue

### 🎯 Next Objectives

1. **Debug OpenRouter Clerk 502 Issue**
   - Compare exact curl commands between direct execution and subprocess
   - Check payload encoding/format differences
   - Verify environment variable passing to subprocess

2. **Stabilize HTTP Client**
   - Add retry logic for transient errors
   - Better error messages for authentication failures
   - Rate limiting handling

3. **Testing & Validation**
   - Full integration test with OpenRouter working
   - Test all model providers (Anthropic, OpenAI, etc.)
   - Validate subagent functionality

4. **Cleanup**
   - Remove debug logging from production
   - Document known issues/workarounds
   - Update README with new architecture

## Known Issues

1. **Zig HTTP Client Bug** (Workaround Applied)
   - `std.http.Client.fetch()` with `response_writer` returns HTTP 200 with 0-byte body
   - Affects all providers using OpenRouter
   - Workaround: Use curl subprocess instead

2. **OpenRouter Clerk 502** (Active Investigation)
   - Authentication error from OpenRouter's identity provider
   - Direct curl works, subprocess fails
   - May be rate limiting or timing issue

## Technical Debt

- Memory leaks from request body allocation in async context
- Need proper ownership model for HTTP payloads
- Consider using arena for entire request lifecycle
