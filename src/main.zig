const std = @import("std");
const http = @import("apple_pie");
const router = http.router;
pub const transaction_tree = @import("./transaction_tree.zig");
const context = @import("./context.zig");
const Context = @import("./context.zig").Context;

//pub const io_mode = .evented;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var my_context = Context.init(&gpa.allocator);

    const address = try std.net.Address.parseIp("127.0.0.1", 35866);

    std.log.info("listening on address {}", .{address});

    try http.listenAndServe(
        &gpa.allocator,
        address,
        &my_context,
        comptime router.Router(*Context, &.{
            router.get("/balance", getBalance),
            router.post("/transactions", postTransaction),
            router.post("/spend", postSpend),
            router.get("/", getIndex),
        }),
    );
}

fn getIndex(_: *Context, response: *http.Response, _: http.Request) !void {
    try response.writer().print("Hello, world!\n", .{});
}

fn getBalance(ctx: *Context, response: *http.Response, _: http.Request) !void {
    var balance = try ctx.getBalance(ctx.allocator);
    defer balance.deinit();

    var iter = balance.iterator();
    while (iter.next()) |entry| {
        try response.writer().print("{s}: {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

fn postTransaction(ctx: *Context, response: *http.Response, request: http.Request) !void {
    const Input = struct {
        payer: ?[]const u8 = null,
        points: ?i128 = null,
        timestamp: ?[]const u8 = null,
    };
    const Output = struct {
        message: []const u8,
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    const headers = try request.headers(&arena.allocator);

    const mime_type = headers.get("Content-Type") orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, "application/json", mime_type)) {
        return error.InvalidFormat;
    }

    const input = try std.json.parse(Input, &std.json.TokenStream.init(request.body()), .{ .allocator = &arena.allocator });

    if (input.payer == null or input.points == null or input.timestamp == null) {
        var error_message = std.ArrayList(u8).init(&arena.allocator);
        const writer = error_message.writer();

        try writer.writeAll("Malformed request; the following fields are missing: ");
        if (input.payer == null) try writer.writeAll("payer, ");
        if (input.points == null) try writer.writeAll("points, ");
        if (input.timestamp == null) try writer.writeAll("timestamp, ");

        response.status_code = .bad_request;
        try response.headers.put("Content-Type", "application/json");
        try std.json.stringify(Output{
            .message = error_message.items,
        }, .{}, response.writer());
        return;
    }

    const payer = input.payer orelse return error.InvalidFormat;
    const points = input.points orelse return error.InvalidFormat;
    const timestamp_string = input.timestamp orelse return error.InvalidFormat;

    const datetime = try context.parseDateTime(timestamp_string);

    try ctx.addPoints(datetime, payer, points);

    try response.headers.put("Content-Type", "application/json");
    try std.json.stringify(Output{
        .message = "Points added",
    }, .{}, response.writer());
}

fn postSpend(ctx: *Context, response: *http.Response, request: http.Request) !void {
    const Input = struct {
        points: ?i128 = null,
    };
    const OutputErr = struct {
        message: []const u8,
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    const headers = try request.headers(&arena.allocator);

    const mime_type = headers.get("Content-Type") orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, "application/json", mime_type)) {
        return error.InvalidFormat;
    }

    const input = try std.json.parse(Input, &std.json.TokenStream.init(request.body()), .{ .allocator = &arena.allocator });

    if (input.points == null) {
        var error_message = std.ArrayList(u8).init(&arena.allocator);
        const writer = error_message.writer();

        try writer.writeAll("Malformed request; the following fields are missing: ");
        if (input.points == null) try writer.writeAll("points, ");

        response.status_code = .bad_request;
        try response.headers.put("Content-Type", "application/json");
        try std.json.stringify(OutputErr{
            .message = error_message.items,
        }, .{}, response.writer());
        return;
    }

    const points = input.points orelse return error.InvalidFormat;

    const payers_spent_from = try ctx.spendPoints(&arena.allocator, points);

    var iter = payers_spent_from.iterator();
    while (iter.next()) |entry| {
        try response.writer().print("{s}: {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

test {
    std.testing.refAllDecls(@This());
}
