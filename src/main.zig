const std = @import("std");
const http = @import("apple_pie");
const router = http.router;
const chrono = @import("chrono");
pub const transaction_tree = @import("./transaction_tree.zig");
const ArrayDeque = @import("./array_deque.zig").ArrayDeque;

//pub const io_mode = .evented;

const Context = struct {
    allocator: *std.mem.Allocator,
    payers: std.StringHashMap(Payer),

    pub fn init(allocator: *std.mem.Allocator) @This() {
        return @This(){
            .allocator = allocator,
            .payers = std.StringHashMap(Payer).init(allocator),
        };
    }

    pub fn deinit(this: *@This()) void {
        var iter = this.payers.valueIterator();
        while (iter.next()) |payer| {
            payer.transactions.deinit();
            this.allocator.free(payer.name);
        }
        this.payers.deinit();
    }

    pub fn addPoints(this: *@This(), datetime: chrono.datetime.DateTime, payer: []const u8, points: i128) !void {
        const gop = try this.payers.getOrPut(payer);
        if (!gop.found_existing) {
            gop.value_ptr.name = try this.allocator.dupe(u8, payer);
            gop.value_ptr.transactions = transaction_tree.Tree.init(this.allocator);
        }

        const timestamp = datetime.toTimestamp();

        // Check if this would make the points negative at the time of the transaction
        const balance_at_time = gop.value_ptr.transactions.getBalanceAtTime(timestamp);
        if (points < 0 and balance_at_time + points < 0) return error.PointsWouldBeNegative;

        // Check if this would make the points negative in total
        const balance = gop.value_ptr.transactions.getBalance();
        if (points < 0 and balance + points < 0) return error.PointsWouldBeNegative;

        try gop.value_ptr.transactions.putNoClobber(datetime.toTimestamp(), points);
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

    pub fn spendPoints(this: *@This(), allocator: *std.mem.Allocator, points: i128) !SpentPoints {
        var payers = std.ArrayList(SpentPayer).init(allocator);
        defer payers.deinit();

        if (points < 0) return error.CantSpendNegativePoints;

        var points_left = points;

        var iter = this.payers.valueIterator();
        while (iter.next()) |payer| {
            if (points_left == 0) break;
            const balance = payer.transactions.getBalance();
            if (balance > 0) {
                const points_used = std.math.min(balance, points_left);
                try payers.append(.{ .name = payer.name, .points = -@intCast(i128, points_used) });
                try payer.transactions.putNoClobber(std.time.timestamp(), -points_used);
                points_left -= points_used;
            }
        }

        return SpentPoints{
            .allocator = allocator,
            .payers = payers.toOwnedSlice(),
        };
    }

    pub fn getBalance(this: *@This(), allocator: *std.mem.Allocator) !std.StringHashMap(i128) {
        var payers = std.StringHashMap(i128).init(allocator);
        defer payers.deinit();

        var iter = this.payers.valueIterator();
        while (iter.next()) |payer| {
            std.log.warn("payer name = {s}", .{payer.name});
            try payers.putNoClobber(payer.name, payer.transactions.getBalance());
        }

        return payers;
    }
};

const Payer = struct {
    name: []const u8,
    transactions: transaction_tree.Tree,

    pub const OldestPointsResult = struct {
        timestamp: i64,
        amount: i128,
    };

    fn oldestPoints(this: @This(), allocator: *std.mem.Allocator) !?OldestPointsResult {
        var points_queue = ArrayDeque(OldestPointsResult).init(allocator);
        defer points_queue.deinit();

        var current_balance: i128 = 0;
        var iter = this.transactions.iterator(.first);
        while (try iter.next()) |entry| {
            current_balance += entry.change;
            if (entry.change > 0) {
                try points_queue.push_back(.{ .timestamp = entry.timestamp, .amount = entry.change });
            } else if (entry.change < 0) {
                var points_to_remove = -entry.change;
                while (points_to_remove > 0) {
                    const oldest_points = points_queue.idxMut(0) orelse unreachable; // Balance should never dip below zero
                    if (oldest_points.amount <= points_to_remove) {
                        points_to_remove -= oldest_points.amount;
                        _ = points_queue.pop_front();
                    } else {
                        oldest_points.amount -= points_to_remove;
                        points_to_remove = 0;
                    }
                }
            }
        }

        return points_queue.pop_front();
    }
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
        try response.writer().print("{s}: {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
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

    try std.testing.expectEqual(@as(i128, 1_000), balance.get("DANNON").?);
    try std.testing.expectEqual(@as(i128, 0), balance.get("UNILEVER").?);
    try std.testing.expectEqual(@as(i128, 5_300), balance.get("MILLER COORS").?);
    try std.testing.expectEqual(@as(i128, 3), balance.count());
}

test "get payer's oldest points" {
    var payer = Payer{
        .name = "hello",
        .transactions = transaction_tree.Tree.init(std.testing.allocator),
    };
    defer payer.transactions.deinit();

    try payer.transactions.putNoClobber(100, 1_000);
    try payer.transactions.putNoClobber(200, -500);
    try payer.transactions.putNoClobber(250, -500);
    try payer.transactions.putNoClobber(300, 1_000);
    try payer.transactions.putNoClobber(666, 666);
    try payer.transactions.putNoClobber(777, -666);
    try payer.transactions.putNoClobber(1000, 1_337);
    try payer.transactions.putNoClobber(1001, -500);

    try std.testing.expectEqual(Payer.OldestPointsResult{ .timestamp = 666, .amount = 500 }, (try payer.oldestPoints(std.testing.allocator)).?);

    try payer.transactions.putNoClobber(1002, -501);

    try std.testing.expectEqual(Payer.OldestPointsResult{ .timestamp = 1000, .amount = 1336 }, (try payer.oldestPoints(std.testing.allocator)).?);
}
