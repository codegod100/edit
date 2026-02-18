const std = @import("std");
const provider = @import("provider.zig");
const chart = @import("term_chart.zig");
const C_RESET = "\x1b[0m";
const C_GREEN = "\x1b[32m";
const C_YELLOW = "\x1b[33m";
const C_RED = "\x1b[31m";
const PST_OFFSET_SECONDS: i64 = -8 * 60 * 60;

pub const UsageError = error{
    UnsupportedProvider,
    MissingApiKey,
    InvalidProviderEndpoint,
    RequestFailed,
};

pub fn queryCurrentProviderUsage(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    api_key: ?[]const u8,
) ![]u8 {
    if (!std.mem.eql(u8, provider_id, "zai")) return UsageError.UnsupportedProvider;
    const key = api_key orelse return UsageError.MissingApiKey;
    if (key.len == 0) return UsageError.MissingApiKey;

    const cfg = provider.getProviderConfig(provider_id);
    const base = try baseDomainFromEndpoint(allocator, cfg.endpoint);
    defer allocator.free(base);

    const now = std.time.timestamp();
    const start_ts = now - 24 * 60 * 60;
    const start_s_query = try formatDateTimeWithOffset24(allocator, start_ts, PST_OFFSET_SECONDS);
    defer allocator.free(start_s_query);
    const end_s_query = try formatDateTimeWithOffset24(allocator, now, PST_OFFSET_SECONDS);
    defer allocator.free(end_s_query);
    const start_s_display = try formatDateTimeWithOffset12(allocator, start_ts, PST_OFFSET_SECONDS);
    defer allocator.free(start_s_display);
    const end_s_display = try formatDateTimeWithOffset12(allocator, now, PST_OFFSET_SECONDS);
    defer allocator.free(end_s_display);
    const start_q = try urlEncodeDateTimeParam(allocator, start_s_query);
    defer allocator.free(start_q);
    const end_q = try urlEncodeDateTimeParam(allocator, end_s_query);
    defer allocator.free(end_q);

    const model_url = try std.fmt.allocPrint(
        allocator,
        "{s}/api/monitor/usage/model-usage?startTime={s}&endTime={s}",
        .{ base, start_q, end_q },
    );
    defer allocator.free(model_url);
    const tool_url = try std.fmt.allocPrint(
        allocator,
        "{s}/api/monitor/usage/tool-usage?startTime={s}&endTime={s}",
        .{ base, start_q, end_q },
    );
    defer allocator.free(tool_url);
    const quota_url = try std.fmt.allocPrint(allocator, "{s}/api/monitor/usage/quota/limit", .{base});
    defer allocator.free(quota_url);

    const auth_primary = if (std.mem.startsWith(u8, key, "Bearer ")) key else try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
    defer if (!std.mem.startsWith(u8, key, "Bearer ")) allocator.free(auth_primary);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("Usage ({s})\n", .{provider_id});
    try w.print("Window (PST): {s} -> {s}\n\n", .{ start_s_display, end_s_display });

    var tasks = [_]FetchTask{
        .{ .label = "Model usage", .url = model_url, .auth_primary = auth_primary, .raw_key = key },
        .{ .label = "Tool usage", .url = tool_url, .auth_primary = auth_primary, .raw_key = key },
        .{ .label = "Quota limit", .url = quota_url, .auth_primary = auth_primary, .raw_key = key },
    };

    var threads: [3]?std.Thread = .{ null, null, null };
    var i: usize = 0;
    while (i < tasks.len) : (i += 1) {
        threads[i] = std.Thread.spawn(.{}, fetchTaskMain, .{&tasks[i]}) catch null;
    }

    var results: [3]QueryResult = undefined;
    i = 0;
    while (i < tasks.len) : (i += 1) {
        if (threads[i]) |t| {
            t.join();
            if (tasks[i].result) |qr_thread| {
                results[i] = try cloneQueryResult(allocator, qr_thread);
                freeQueryResult(std.heap.page_allocator, qr_thread);
            } else {
                const msg = try std.fmt.allocPrint(allocator, "request failed: {s}", .{@errorName(tasks[i].err orelse UsageError.RequestFailed)});
                results[i] = .{
                    .label = tasks[i].label,
                    .status = 500,
                    .payload = null,
                    .error_body = msg,
                };
            }
        } else {
            results[i] = try fetchDecodedData(allocator, tasks[i].label, tasks[i].url, tasks[i].auth_primary, tasks[i].raw_key);
        }
    }

    const model_raw = results[0];
    defer freeQueryResult(allocator, model_raw);
    try renderModelUsage(allocator, &out, model_raw);
    try out.append(allocator, '\n');

    const tool_raw = results[1];
    defer freeQueryResult(allocator, tool_raw);
    try renderToolUsage(allocator, &out, tool_raw);
    try out.append(allocator, '\n');

    const quota_raw = results[2];
    defer freeQueryResult(allocator, quota_raw);
    try renderQuotaUsage(allocator, &out, quota_raw);

    return out.toOwnedSlice(allocator);
}

const QueryResult = struct {
    label: []const u8,
    status: u16,
    payload: ?[]u8,
    error_body: ?[]u8,
};

const FetchTask = struct {
    label: []const u8,
    url: []const u8,
    auth_primary: []const u8,
    raw_key: []const u8,
    result: ?QueryResult = null,
    err: ?anyerror = null,
};

fn fetchTaskMain(task: *FetchTask) void {
    task.result = fetchDecodedData(std.heap.page_allocator, task.label, task.url, task.auth_primary, task.raw_key) catch |e| {
        task.err = e;
        return;
    };
}

fn freeQueryResult(allocator: std.mem.Allocator, qr: QueryResult) void {
    if (qr.payload) |p| allocator.free(p);
    if (qr.error_body) |e| allocator.free(e);
}

fn cloneQueryResult(to_allocator: std.mem.Allocator, qr: QueryResult) !QueryResult {
    return .{
        .label = qr.label,
        .status = qr.status,
        .payload = if (qr.payload) |p| try to_allocator.dupe(u8, p) else null,
        .error_body = if (qr.error_body) |e| try to_allocator.dupe(u8, e) else null,
    };
}

fn fetchDecodedData(
    allocator: std.mem.Allocator,
    label: []const u8,
    url: []const u8,
    auth_primary: []const u8,
    raw_key: []const u8,
) !QueryResult {
    var resp = try fetchUsage(allocator, url, auth_primary);

    if (resp.status != 200 and !std.mem.eql(u8, auth_primary, raw_key)) {
        const retry = try fetchUsage(allocator, url, raw_key);
        if (retry.status == 200) {
            allocator.free(resp.body);
            resp = retry;
        } else {
            allocator.free(retry.body);
        }
    }

    if (resp.status != 200) {
        return .{
            .label = label,
            .status = resp.status,
            .payload = null,
            .error_body = resp.body,
        };
    }

    const data_json = try extractDataJson(allocator, resp.body);
    allocator.free(resp.body);
    return .{
        .label = label,
        .status = 200,
        .payload = data_json,
        .error_body = null,
    };
}

fn renderModelUsage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), qr: QueryResult) !void {
    const w = out.writer(allocator);
    try w.writeAll("Model usage:\n");
    if (qr.status != 200 or qr.payload == null) {
        const body = qr.error_body orelse "";
        const capped = if (body.len > 1200) body[0..1200] else body;
        try w.print("  HTTP {d}\n  {s}\n", .{ qr.status, capped });
        return;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, qr.payload.?, .{ .ignore_unknown_fields = true }) catch {
        try w.print("  {s}\n", .{qr.payload.?});
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try w.print("  {s}\n", .{qr.payload.?});
        return;
    }

    const obj = parsed.value.object;
    const total = obj.get("totalUsage");
    const x_time = obj.get("x_time");
    const call_count = obj.get("modelCallCount");
    const token_usage = obj.get("tokensUsage");

    if (total) |t| {
        if (t == .object) {
            if (t.object.get("totalModelCallCount")) |v| {
                if (v == .integer) try w.print("  Total calls: {d}\n", .{v.integer});
            }
            if (t.object.get("totalTokensUsage")) |v| {
                if (v == .integer) try w.print("  Total tokens: {d}\n", .{v.integer});
            }
        }
    }

    const Metrics = struct { latest_time: ?[]const u8 = null, latest_calls: i64 = 0, latest_tokens: i64 = 0, peak_time: ?[]const u8 = null, peak_tokens: i64 = 0 };
    var m: Metrics = .{};

    if (x_time != null and call_count != null and token_usage != null and x_time.? == .array and call_count.? == .array and token_usage.? == .array) {
        const times = x_time.?.array.items;
        const calls = call_count.?.array.items;
        const toks = token_usage.?.array.items;
        const n = @min(times.len, @min(calls.len, toks.len));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ts = times[i];
            const c = calls[i];
            const t = toks[i];
            const c_val: i64 = if (c == .integer) c.integer else 0;
            const t_val: i64 = if (t == .integer) t.integer else 0;
            if (c_val > 0 or t_val > 0) {
                if (ts == .string) {
                    m.latest_time = ts.string;
                }
                m.latest_calls = c_val;
                m.latest_tokens = t_val;
                if (t_val > m.peak_tokens) {
                    m.peak_tokens = t_val;
                    if (ts == .string) m.peak_time = ts.string;
                }
            }
        }
    }

    if (m.latest_time) |t| {
        const t12 = try formatDisplayTimeString12(allocator, t);
        defer allocator.free(t12);
        try w.print("  Latest active hour: {s} | calls={d} tokens={d}\n", .{ t12, m.latest_calls, m.latest_tokens });
    }
    if (m.peak_time) |t| {
        const t12 = try formatDisplayTimeString12(allocator, t);
        defer allocator.free(t12);
        try w.print("  Peak token hour: {s} | tokens={d}\n", .{ t12, m.peak_tokens });
    }

    if (token_usage != null and token_usage.? == .array and token_usage.?.array.items.len > 0) {
        const toks = token_usage.?.array.items;
        const vals = try allocator.alloc(i64, toks.len);
        defer allocator.free(vals);
        for (toks, 0..) |v, i| {
            vals[i] = if (v == .integer and v.integer > 0) v.integer else 0;
        }
        const spark = try chart.sparkline(allocator, vals, 40);
        defer allocator.free(spark);
        try w.print("  Tokens trend: {s}\n", .{spark});
        if (x_time != null and x_time.? == .array and x_time.?.array.items.len > 0) {
            const axis = try buildAxisLine(allocator, x_time.?.array.items, spark.len);
            defer allocator.free(axis);
            try w.print("                {s}\n", .{axis});
        }
    }

    if (call_count != null and call_count.? == .array and call_count.?.array.items.len > 0) {
        const calls = call_count.?.array.items;
        const vals = try allocator.alloc(i64, calls.len);
        defer allocator.free(vals);
        for (calls, 0..) |v, i| {
            vals[i] = if (v == .integer and v.integer > 0) v.integer else 0;
        }
        const spark = try chart.sparkline(allocator, vals, 40);
        defer allocator.free(spark);
        try w.print("  Calls trend:  {s}\n", .{spark});
        if (x_time != null and x_time.? == .array and x_time.?.array.items.len > 0) {
            const axis = try buildAxisLine(allocator, x_time.?.array.items, spark.len);
            defer allocator.free(axis);
            try w.print("                {s}\n", .{axis});
        }
    }
}

fn renderToolUsage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), qr: QueryResult) !void {
    const w = out.writer(allocator);
    try w.writeAll("Tool usage:\n");
    if (qr.status != 200 or qr.payload == null) {
        const body = qr.error_body orelse "";
        const capped = if (body.len > 1200) body[0..1200] else body;
        try w.print("  HTTP {d}\n  {s}\n", .{ qr.status, capped });
        return;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, qr.payload.?, .{ .ignore_unknown_fields = true }) catch {
        try w.print("  {s}\n", .{qr.payload.?});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try w.print("  {s}\n", .{qr.payload.?});
        return;
    }

    const obj = parsed.value.object;
    const total = obj.get("totalUsage");
    if (total != null and total.? == .object) {
        const t = total.?.object;
        const network_search = if (t.get("totalNetworkSearchCount")) |v| if (v == .integer) v.integer else 0 else 0;
        const web_read = if (t.get("totalWebReadMcpCount")) |v| if (v == .integer) v.integer else 0 else 0;
        const zread = if (t.get("totalZreadMcpCount")) |v| if (v == .integer) v.integer else 0 else 0;
        const search_mcp = if (t.get("totalSearchMcpCount")) |v| if (v == .integer) v.integer else 0 else 0;
        const total_calls = network_search + web_read + zread + search_mcp;

        try w.print("  Total calls: {d}\n", .{total_calls});
        if (network_search > 0) try w.print("  Network search: {d}\n", .{network_search});
        if (web_read > 0) try w.print("  Web read: {d}\n", .{web_read});
        if (zread > 0) try w.print("  Zread: {d}\n", .{zread});
        if (search_mcp > 0) try w.print("  Search MCP: {d}\n", .{search_mcp});
        if (total_calls == 0) try w.writeAll("  No tool calls in this window.\n");

        if (t.get("toolDetails")) |d| {
            if (d == .array and d.array.items.len > 0) {
                try w.writeAll("  Tool details:\n");
                for (d.array.items) |it| {
                    if (it != .object) continue;
                    const name = if (it.object.get("modelCode")) |v| if (v == .string) v.string else "unknown" else "unknown";
                    const usage = if (it.object.get("usage")) |v| if (v == .integer) v.integer else 0 else 0;
                    try w.print("    - {s}: {d}\n", .{ name, usage });
                }
            }
        }
        return;
    }

    try w.print("  {s}\n", .{qr.payload.?});
}

fn renderQuotaUsage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), qr: QueryResult) !void {
    const w = out.writer(allocator);
    try w.writeAll("Quota:\n");
    if (qr.status != 200 or qr.payload == null) {
        const body = qr.error_body orelse "";
        const capped = if (body.len > 1200) body[0..1200] else body;
        try w.print("  HTTP {d}\n  {s}\n", .{ qr.status, capped });
        return;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, qr.payload.?, .{ .ignore_unknown_fields = true }) catch {
        try w.print("  {s}\n", .{qr.payload.?});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try w.print("  {s}\n", .{qr.payload.?});
        return;
    }

    const obj = parsed.value.object;
    if (obj.get("level")) |lvl| {
        if (lvl == .string) try w.print("  Plan level: {s}\n", .{lvl.string});
    }
    if (obj.get("limits")) |limits| {
        if (limits == .array and limits.array.items.len > 0) {
            for (limits.array.items) |it| {
                if (it != .object) continue;
                const raw_typ = if (it.object.get("type")) |v| if (v == .string) v.string else "UNKNOWN" else "UNKNOWN";
                const unit = if (it.object.get("unit")) |v| if (v == .integer) v.integer else -1 else -1;
                const number = if (it.object.get("number")) |v| if (v == .integer) v.integer else -1 else -1;
                const pct = if (it.object.get("percentage")) |v| if (v == .integer) v.integer else 0 else 0;
                const current = if (it.object.get("currentValue")) |v| if (v == .integer) v.integer else -1 else -1;
                const remain = if (it.object.get("remaining")) |v| if (v == .integer) v.integer else -1 else -1;
                const next_reset_ms = if (it.object.get("nextResetTime")) |v| if (v == .integer) v.integer else -1 else -1;
                const bar = try chart.pctBar(allocator, pct, 20);
                defer allocator.free(bar);
                const color = if (pct >= 85) C_RED else if (pct >= 60) C_YELLOW else C_GREEN;
                const typ = switch (std.meta.stringToEnum(enum { TOKENS_LIMIT, TIME_LIMIT }, raw_typ) orelse .TOKENS_LIMIT) {
                    .TOKENS_LIMIT => "Token usage",
                    .TIME_LIMIT => "MCP usage",
                };

                var label_extra: std.ArrayListUnmanaged(u8) = .empty;
                defer label_extra.deinit(allocator);
                const le = label_extra.writer(allocator);
                if (number >= 0 or unit >= 0) {
                    const window_label = try quotaWindowLabel(allocator, number, unit, next_reset_ms);
                    defer allocator.free(window_label);
                    try le.print(" ({s})", .{window_label});
                }
                if (next_reset_ms > 0) {
                    const reset_sec: i64 = @intCast(@divTrunc(next_reset_ms, 1000));
                    const reset_s = try formatDateTimeWithOffset12(allocator, reset_sec, PST_OFFSET_SECONDS);
                    defer allocator.free(reset_s);
                    try le.print(" reset={s} PST", .{reset_s});
                }

                if (current >= 0 and remain >= 0) {
                    try w.print("  - {s}{s}: {s}{s}{s} (current={d}, remaining={d})\n", .{ typ, label_extra.items, color, bar, C_RESET, current, remain });
                } else {
                    try w.print("  - {s}{s}: {s}{s}{s}\n", .{ typ, label_extra.items, color, bar, C_RESET });
                }
            }
            return;
        }
    }
    try w.print("  {s}\n", .{qr.payload.?});
}

const HttpResponse = struct {
    status: u16,
    body: []u8,
};

fn fetchUsage(allocator: std.mem.Allocator, url: []const u8, auth_value: []const u8) !HttpResponse {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    var extra_headers: [2]std.http.Header = .{
        .{ .name = "Accept-Language", .value = "en-US,en" },
        .{ .name = "accept-encoding", .value = "identity" },
    };

    const headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = headers,
        .extra_headers = extra_headers[0..],
        .response_writer = &writer.writer,
    }) catch return UsageError.RequestFailed;

    const body = try writer.toOwnedSlice();
    return .{
        .status = @intFromEnum(result.status),
        .body = body,
    };
}

fn extractDataJson(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return allocator.dupe(u8, body);
    };
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("data")) |data| {
            return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(data, .{})});
        }
    }
    return allocator.dupe(u8, body);
}

fn baseDomainFromEndpoint(allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    const scheme_idx = std.mem.indexOf(u8, endpoint, "://") orelse return UsageError.InvalidProviderEndpoint;
    const host_start = scheme_idx + 3;
    const rest = endpoint[host_start..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return allocator.dupe(u8, endpoint[0 .. host_start + slash]);
}

fn formatDateTimeWithOffset24(allocator: std.mem.Allocator, ts: i64, offset_seconds: i64) ![]u8 {
    const shifted = ts + offset_seconds;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(shifted) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn formatDateTimeWithOffset12(allocator: std.mem.Allocator, ts: i64, offset_seconds: i64) ![]u8 {
    const shifted = ts + offset_seconds;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(shifted) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const h24: u8 = day_seconds.getHoursIntoDay();
    const ampm = if (h24 < 12) "AM" else "PM";
    const h12: u8 = if (h24 == 0) 12 else if (h24 > 12) h24 - 12 else h24;

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d}:{d:0>2}:{d:0>2} {s}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        h12,
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        ampm,
    });
}

fn urlEncodeDateTimeParam(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        switch (c) {
            ' ' => try out.appendSlice(allocator, "%20"),
            ':' => try out.appendSlice(allocator, "%3A"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn buildAxisLine(allocator: std.mem.Allocator, times: []const std.json.Value, width: usize) ![]u8 {
    if (times.len == 0 or width == 0) return allocator.dupe(u8, "");
    const left = try shortTimeLabel(allocator, times[0]);
    defer allocator.free(left);
    const right = try shortTimeLabel(allocator, times[times.len - 1]);
    defer allocator.free(right);
    if (left.len == 0 and right.len == 0) return allocator.dupe(u8, "");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, left);
    const need_gap = if (width > left.len + right.len) width - left.len - right.len else 1;
    var i: usize = 0;
    while (i < need_gap) : (i += 1) try out.append(allocator, ' ');
    try out.appendSlice(allocator, right);
    return out.toOwnedSlice(allocator);
}

fn shortTimeLabel(allocator: std.mem.Allocator, v: std.json.Value) ![]u8 {
    if (v != .string) return allocator.dupe(u8, "");
    const s = v.string;
    const candidate = if (s.len >= 5) s[s.len - 5 ..] else s;
    return formatDisplayTimeString12(allocator, candidate);
}

fn formatDisplayTimeString12(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var time_start: usize = 0;
    var has_date_prefix = false;
    if (std.mem.indexOfScalar(u8, s, ' ')) |idx| {
        has_date_prefix = true;
        time_start = idx + 1;
        if (time_start >= s.len) return allocator.dupe(u8, s);
    }

    const time_part = s[time_start..];
    if (time_part.len < 5) return allocator.dupe(u8, s);

    const h_len: usize = if (time_part.len >= 2 and time_part[1] == ':') 1 else if (time_part.len >= 3 and time_part[2] == ':') 2 else 0;
    if (h_len == 0) return allocator.dupe(u8, s);
    if (time_part[h_len] != ':') return allocator.dupe(u8, s);
    if (time_part.len < h_len + 3) return allocator.dupe(u8, s);

    const hour = std.fmt.parseInt(u8, time_part[0..h_len], 10) catch return allocator.dupe(u8, s);
    if (hour > 23) return allocator.dupe(u8, s);

    const minute = time_part[h_len + 1 .. h_len + 3];
    const has_seconds = time_part.len >= h_len + 6 and time_part[h_len + 3] == ':';
    const seconds = if (has_seconds) time_part[h_len + 4 .. h_len + 6] else "";

    const ampm = if (hour < 12) "AM" else "PM";
    const h12: u8 = if (hour == 0) 12 else if (hour > 12) hour - 12 else hour;

    if (has_date_prefix) {
        const date_prefix = s[0 .. time_start - 1];
        if (has_seconds) {
            return std.fmt.allocPrint(allocator, "{s} {d}:{s}:{s} {s}", .{ date_prefix, h12, minute, seconds, ampm });
        }
        return std.fmt.allocPrint(allocator, "{s} {d}:{s} {s}", .{ date_prefix, h12, minute, ampm });
    }

    if (has_seconds) {
        return std.fmt.allocPrint(allocator, "{d}:{s}:{s} {s}", .{ h12, minute, seconds, ampm });
    }
    return std.fmt.allocPrint(allocator, "{d}:{s} {s}", .{ h12, minute, ampm });
}

fn quotaWindowLabel(allocator: std.mem.Allocator, number: i64, unit: i64, next_reset_ms: i64) ![]u8 {
    if (number < 0 and unit < 0) return allocator.dupe(u8, "");
    if (number < 0) return std.fmt.allocPrint(allocator, "unit {d} quota", .{unit});
    if (unit < 0) return std.fmt.allocPrint(allocator, "{d} quota", .{number});

    const unit_name = switch (unit) {
        0 => "minute",
        1 => "hour",
        2 => "day",
        // Observed provider enum: 3 corresponds to hourly quotas.
        3 => "hour",
        4 => "month",
        5 => "month",
        6 => "week",
        else => "custom",
    };

    if (std.mem.eql(u8, unit_name, "custom")) {
        if (next_reset_ms > 0) {
            const now_ms = std.time.milliTimestamp();
            const delta_ms = if (next_reset_ms > now_ms) next_reset_ms - now_ms else 0;
            const day_ms: i64 = 24 * 60 * 60 * 1000;
            if (delta_ms <= 2 * day_ms) return std.fmt.allocPrint(allocator, "{d} day quota", .{number});
            if (delta_ms <= 10 * day_ms) return std.fmt.allocPrint(allocator, "{d} week quota", .{number});
            if (delta_ms <= 45 * day_ms) return std.fmt.allocPrint(allocator, "{d} month quota", .{number});
        }
        return std.fmt.allocPrint(allocator, "{d} custom quota", .{number});
    }

    const unit_label = if (number == 1) unit_name else switch (unit) {
        0 => "minutes",
        1, 3 => "hours",
        2 => "days",
        4, 5 => "months",
        6 => "weeks",
        else => unit_name,
    };
    return std.fmt.allocPrint(allocator, "{d} {s} quota", .{ number, unit_label });
}
