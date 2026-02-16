# Objectives

## Current Status

### ✅ Completed
- **Modularization**: Split monolithic files into `ai_bridge/` and `model_loop/` modules
- **HTTP Client**: Native Zig HTTP client with retry logic (3 retries, exponential backoff)
- **Memory Leaks**: Fixed arena allocator issues for provider specs and per-turn allocations
- **Error Handling**: Better handling for empty responses and API errors
- **Zig 0.15.x API Migration**: Fixed all compilation errors in auth.zig and llm/client.zig
  - Updated `std.ArrayList(T).init(allocator)` → `var list: std.ArrayList(T) = .empty`
  - Updated `response_storage` → `response_writer` with Allocating writer
- **OpenRouter Integration**: ✅ **RESOLVED** - Working correctly
  - Fixed Zig 0.15.x API compatibility issues
  - Native Zig HTTP client working properly with OpenRouter
- **Context Restore**: Made optional via `ZAGENT_RESTORE_CONTEXT` env var and `/restore` command
- **Memory Leak Fixes**: ✅ **FIXED**
  - Fixed in llm/chat.zig: Added errdefer cleanup for tool call allocations
  - Fixed in model_loop/legacy.zig: Added cleanup for last_tool_name/last_tool_args

### 🎯 Next Objectives

1. **Testing & Validation**
   - Test all model providers (Anthropic, OpenAI, etc.)
   - Validate subagent functionality
   - Test tool calling with various providers

2. **Provider Error Handling**
   - Some providers return 400 errors for certain models - need better fallback
   - Improve error classification per provider

3. **Documentation**
   - Update README with new architecture
   - Document environment variables (ZAGENT_RESTORE_CONTEXT)
   - Document /restore command

## Known Issues

None currently identified.

## Resolved Issues

1. **OpenRouter Clerk 502** ✅ **FIXED**
   - Root cause: Zig 0.15.x API compatibility issues in auth.zig and llm/client.zig
   - Fixed by updating ArrayList initialization and HTTP client fetch API
   - Both direct and subprocess curl now work identically

2. **Zig HTTP Client Bug** ✅ **FIXED**
   - Previously: `std.http.Client.fetch()` with `response_writer` returned HTTP 200 with 0-byte body
   - Root cause was API compatibility issues, not the HTTP client itself
   - Fixed by using correct Zig 0.15.x API with `Allocating` writer
   - Removed curl subprocess workaround, now using native Zig HTTP client

3. **Memory Leaks in Error Paths** ✅ **FIXED**
   - Fixed in llm/chat.zig: Added errdefer cleanup for tool call allocations
   - Fixed in model_loop/legacy.zig: Added cleanup for last_tool_name/last_tool_args on early returns and errors

## Build Status

✅ **BUILD SUCCESS** - All compilation errors resolved. The project compiles successfully with Zig 0.15.x.

## Technical Debt

- Consider using arena for entire request lifecycle to simplify memory management
- Optimize JSON parsing for large responses
- Add comprehensive error handling for all provider-specific edge cases

## Recent Fixes (2026-02-15)

1. **auth.zig**: Updated httpRequest to use Zig 0.15.x API
   - Changed `var out = std.ArrayList(u8).init(allocator)` → `var out: std.ArrayListUnmanaged(u8) = .empty`
   - Changed `response_storage` → `response_writer` with Allocating writer

2. **llm/client.zig**: Added retry logic and switched to native Zig HTTP
   - Removed curl subprocess workaround
   - Added 3 retries with exponential backoff (1s, 2s, 3s delays)
   - Added proper error classification (NetworkError, RateLimited, AuthenticationError, etc.)

3. **llm/chat.zig**: Fixed memory leaks in parseChatResponse
   - Added errdefer cleanup for tool call allocations on error
   - Structured result construction to ensure proper cleanup

4. **model_loop/legacy.zig**: Fixed memory leaks
   - Added cleanup for last_tool_name/last_tool_args on cancellation
   - Added cleanup at end of function
   - Fixed error handling to prevent partial allocation leaks
