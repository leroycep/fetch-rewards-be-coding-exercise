const std = @import("std");
const chrono = @import("chrono");
const TransactionTree = @import("./transaction_tree.zig").Tree;
const ArrayDeque = @import("./array_deque.zig").ArrayDeque;

pub const Context = struct {
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
            gop.key_ptr.* = gop.value_ptr.name;
            gop.value_ptr.transactions = TransactionTree.init(this.allocator);
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

    pub fn spendPoints(this: *@This(), allocator: *std.mem.Allocator, points: i128) !std.StringHashMap(i128) {
        if (points < 0) return error.CantSpendNegativePoints;

        var spent_points = std.StringHashMap(i128).init(allocator);
        errdefer spent_points.deinit();

        var payers_oldest = std.StringHashMap(ArrayDeque(Payer.OldestPointsResult)).init(allocator);
        defer {
            var iter = payers_oldest.valueIterator();
            while (iter.next()) |old_points_array| {
                old_points_array.deinit();
            }
            payers_oldest.deinit();
        }

        {
            var iter = this.payers.valueIterator();
            while (iter.next()) |payer| {
                var old_points = try payer.oldestPoints(allocator);
                if (old_points.len() > 0) {
                    try payers_oldest.putNoClobber(payer.name, old_points);
                } else {
                    old_points.deinit();
                }
            }
        }

        var points_left = points;
        while (points_left > 0) {
            var oldest_points_or_null: ?Payer.OldestPointsResult = null;
            var oldest_points_payer_name_or_null: ?[]const u8 = null;

            var iter = payers_oldest.iterator();
            while (iter.next()) |old_points_array_entry| {
                const old_points = old_points_array_entry.value_ptr.idx(0).?;
                if (oldest_points_or_null == null or old_points.timestamp < oldest_points_or_null.?.timestamp) {
                    oldest_points_or_null = old_points;
                    oldest_points_payer_name_or_null = old_points_array_entry.key_ptr.*;
                }
            }

            if (oldest_points_or_null) |oldest_points| {
                const points_used = std.math.min(oldest_points.amount, points_left);

                const gop = try spent_points.getOrPut(oldest_points_payer_name_or_null.?);
                if (!gop.found_existing) {
                    gop.value_ptr.* = 0;
                }
                gop.value_ptr.* -= points_used;

                const old_payer = payers_oldest.getPtr(oldest_points_payer_name_or_null.?).?;
                if (oldest_points.amount > points_used) {
                    const old_points = old_payer.idxMut(0).?;
                    old_points.amount -= points_used;
                } else {
                    _ = old_payer.pop_front();
                    if (old_payer.len() <= 0) {
                        old_payer.deinit();
                        std.debug.assert(payers_oldest.remove(oldest_points_payer_name_or_null.?));
                    }
                }

                points_left -= oldest_points.amount;
            } else {
                return error.PointsWouldBeNegative;
            }
        }

        // TODO: Make this atomic
        const now = std.time.timestamp();
        var iter = spent_points.iterator();
        while (iter.next()) |spent_points_entry| {
            const payer = this.payers.getPtr(spent_points_entry.key_ptr.*).?;
            try payer.transactions.putNoClobber(now, spent_points_entry.value_ptr.*);
        }

        return spent_points;
    }

    pub fn getBalance(this: *@This(), allocator: *std.mem.Allocator) !std.StringHashMap(i128) {
        var payers = std.StringHashMap(i128).init(allocator);
        errdefer payers.deinit();

        var iter = this.payers.valueIterator();
        while (iter.next()) |payer| {
            try payers.putNoClobber(payer.name, payer.transactions.getBalance());
        }

        return payers;
    }
};

pub const Payer = struct {
    name: []const u8,
    transactions: TransactionTree,

    pub const OldestPointsResult = struct {
        timestamp: i64,
        amount: i128,
    };

    fn oldestPoints(this: @This(), allocator: *std.mem.Allocator) !ArrayDeque(OldestPointsResult) {
        var points_queue = ArrayDeque(OldestPointsResult).init(allocator);
        errdefer points_queue.deinit();

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

        return points_queue;
    }
};

pub fn parseDateTime(dtString: []const u8) !chrono.datetime.DateTime {
    const naive_datetime = try chrono.format.parseNaiveDateTime("%Y-%m-%dT%H:%M:%SZ", dtString);
    return naive_datetime.with_timezone(chrono.timezone.UTC);
}

test "Use the oldest points" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Add points to balance
    try ctx.addPoints(try parseDateTime("2020-11-02T14:00:00Z"), "DANNON", 1_000);
    try ctx.addPoints(try parseDateTime("2020-10-31T11:00:00Z"), "UNILEVER", 200);
    try ctx.addPoints(try parseDateTime("2020-10-31T10:00:00Z"), "DANNON", 300);
    try ctx.addPoints(try parseDateTime("2020-10-31T15:00:00Z"), "DANNON", -200);
    try ctx.addPoints(try parseDateTime("2020-11-01T14:00:00Z"), "MILLER COORS", 10_000);

    // Spend 5,000 points, make sure the points are from the payers expected
    var spentPoints = try ctx.spendPoints(std.testing.allocator, 5_000);
    defer spentPoints.deinit();

    try std.testing.expectEqual(@as(i128, -100), spentPoints.get("DANNON").?);
    try std.testing.expectEqual(@as(i128, -200), spentPoints.get("UNILEVER").?);
    try std.testing.expectEqual(@as(i128, -4_700), spentPoints.get("MILLER COORS").?);

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
        .transactions = TransactionTree.init(std.testing.allocator),
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

    {
        var oldest_points = try payer.oldestPoints(std.testing.allocator);
        defer oldest_points.deinit();
        try std.testing.expectEqual(Payer.OldestPointsResult{ .timestamp = 666, .amount = 500 }, oldest_points.idx(0).?);
    }

    try payer.transactions.putNoClobber(1002, -501);

    {
        var oldest_points = try payer.oldestPoints(std.testing.allocator);
        defer oldest_points.deinit();
        try std.testing.expectEqual(Payer.OldestPointsResult{ .timestamp = 1000, .amount = 1336 }, oldest_points.idx(0).?);
    }
}
