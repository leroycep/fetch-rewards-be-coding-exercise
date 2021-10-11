const std = @import("std");
const http = @import("apple_pie");
const router = http.router;
const chrono = @import("chrono");
pub const transaction_tree = @import("./transaction_tree.zig");

//pub const io_mode = .evented;

const Context = struct {
    allocator: *std.mem.Allocator,
    payers: std.StringHashMap(Payer),
    // Points in order of when they arrived
    pointsInOrder: std.PriorityDequeue(TimestampedPoints),

    pub fn init(allocator: *std.mem.Allocator) @This() {
        return @This(){
            .allocator = allocator,
            .payers = std.StringHashMap(Payer).init(allocator),
            .pointsInOrder = std.PriorityDequeue(TimestampedPoints).init(allocator, TimestampedPoints.orderByTimestamp),
        };
    }

    pub fn deinit(this: *@This()) void {
        this.pointsInOrder.deinit();
        var iter = this.payers.valueIterator();
        while (iter.next()) |payer| {
            this.allocator.free(payer.name);
        }
        this.payers.deinit();
    }

    pub fn addPoints(this: *@This(), datetime: chrono.datetime.DateTime, payer: []const u8, points: i128) !void {
        _ = datetime;

        const payer_name = try this.allocator.dupe(u8, payer);
        errdefer this.allocator.free(payer_name);

        const gop = try this.payers.getOrPut(payer_name);
        if (gop.found_existing) {
            this.allocator.free(payer_name);
            if (points < 0) {
                if (-points > gop.value_ptr.points) return error.PointsWouldBeNegative;
                gop.value_ptr.points -= @intCast(u128, -points);

                // TODO: Remove points from previous transaction
            } else {
                gop.value_ptr.points += @intCast(u128, points);

                try this.pointsInOrder.add(.{
                    .payer = gop.value_ptr.name,
                    .timestamp = datetime.toTimestamp(),
                    .amount = points,
                });
            }
        } else {
            gop.value_ptr.name = payer_name;
            gop.value_ptr.points = @intCast(u128, points);

            try this.pointsInOrder.add(.{
                .payer = gop.value_ptr.name,
                .timestamp = datetime.toTimestamp(),
                .amount = points,
            });
        }
    }

    const SpentPoints = struct {
        allocator: *std.mem.Allocator,
        payers: []const SpentPayer,

        pub fn deinit(this: *@This()) void {
            this.allocator.free(this.payers);
        }
    };

    const SpentPayer = struct {
        name: []const u8,
        points: i128,
    };

    pub fn spendPoints(this: *@This(), allocator: *std.mem.Allocator, points: u128) !SpentPoints {
        var payers = std.ArrayList(SpentPayer).init(allocator);
        defer payers.deinit();

        var points_left = points;

        var iter = this.payers.valueIterator();
        while (iter.next()) |payer| {
            if (points_left == 0) break;
            if (payer.points > 0) {
                const points_used = std.math.min(payer.points, points_left);
                try payers.append(.{ .name = payer.name, .points = -@intCast(i128, points_used) });
                payer.points -= points_used;
                points_left -= points_used;
            }
        }

        return SpentPoints{
            .allocator = allocator,
            .payers = payers.toOwnedSlice(),
        };
    }

    pub fn getBalance(this: *@This(), allocator: *std.mem.Allocator) !std.StringHashMap(u128) {
        var payers = std.StringHashMap(u128).init(allocator);
        defer payers.deinit();

        var iter = this.payers.valueIterator();
        while (iter.next()) |payer| {
            std.log.warn("payer name = {s}", .{payer.name});
            try payers.putNoClobber(payer.name, payer.points);
        }

        return payers;
    }
};

const Payer = struct {
    name: []const u8,
    points: u128,
};

const TimestampedPoints = struct {
    payer: []const u8,
    timestamp: i64,
    amount: i128,

    pub fn orderByTimestamp(a: @This(), b: @This()) std.math.Order {
        return std.math.order(a.timestamp, b.timestamp);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var my_context = Context.init(&gpa.allocator);

    const address = try std.net.Address.parseIp("127.0.0.1", 8080);

    std.log.info("listening on address {}", .{address});

    try http.listenAndServe(
        &gpa.allocator,
        address,
        &my_context,
        comptime router.Router(*Context, &.{
            router.get("/balance", getBalance),
        }),
    );
}

fn getBalance(ctx: *Context, response: *http.Response, request: http.Request) !void {
    _ = request;

    var balance = try ctx.getBalance(ctx.allocator);
    defer balance.deinit();

    var iter = balance.iterator();
    while (iter.next()) |entry| {
        try response.writer().print("{s}: {}\n", .{entry.key_ptr.*, entry.value_ptr.*});
    }
}

fn parseDateTime(dtString: []const u8) !chrono.datetime.DateTime {
    const naive_datetime = try chrono.format.parseNaiveDateTime("%Y-%m-%dT%H:%M:%SZ", dtString);
    return naive_datetime.with_timezone(chrono.timezone.UTC);
}

test {
    std.testing.refAllDecls(@This());
}

test "Use the oldest points" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Add points to balance
    try ctx.addPoints(try parseDateTime("2020-11-02T14:00:00Z"), "DANNON", 1_000);
    try ctx.addPoints(try parseDateTime("2020-10-31T11:00:00Z"), "UNILEVER", 200);
    try ctx.addPoints(try parseDateTime("2020-10-31T15:00:00Z"), "DANNON", -200);
    try ctx.addPoints(try parseDateTime("2020-11-01T14:00:00Z"), "MILLER COORS", 10_000);
    try ctx.addPoints(try parseDateTime("2020-10-31T10:00:00Z"), "DANNON", 300);

    // Spend 5,000 points, make sure the points are from the payers expected
    var spentPoints = try ctx.spendPoints(std.testing.allocator, 5_000);
    defer spentPoints.deinit();

    try std.testing.expectEqualStrings("DANNON", spentPoints.payers[0].name);
    try std.testing.expectEqual(@as(i128, -100), spentPoints.payers[0].points);

    try std.testing.expectEqualStrings("UNILEVER", spentPoints.payers[1].name);
    try std.testing.expectEqual(@as(i128, -200), spentPoints.payers[1].points);

    try std.testing.expectEqualStrings("MILLER COORS", spentPoints.payers[2].name);
    try std.testing.expectEqual(@as(i128, -4_700), spentPoints.payers[2].points);

    // get balance
    var balance = try ctx.getBalance(std.testing.allocator);
    defer balance.deinit();

    try std.testing.expectEqual(@as(u128, 1_000), balance.get("DANNON").?);
    try std.testing.expectEqual(@as(u128, 0), balance.get("UNILEVER").?);
    try std.testing.expectEqual(@as(u128, 5_300), balance.get("MILLER COORS").?);
    try std.testing.expectEqual(@as(u128, 3), balance.count());
}
