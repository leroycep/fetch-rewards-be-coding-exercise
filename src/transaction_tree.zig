const std = @import("std");

const PAGE_SIZE = 4096;

pub const Tree = struct {
    allocator: *std.mem.Allocator,
    root: ?*Node,
};

const NodePtr = *align(PAGE_SIZE) const Node;

const Node = struct {
    nodeType: NodeType,
    count: u16,
};

const NodeType = enum {
    leaf,
    internal,
};

const LeafCell = struct {
    timestamp: i64,
    change: i128,
};

const InternalCell = struct {
    greatestTimestamp: i64,
    node: ?NodePtr,
};

test "add 1_000_000 transactions and randomly query balance" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    var default_prng = std.rand.DefaultPrng.init(13500266781291126803);
    const random = &default_prng.random;

    var transactions = std.ArrayList(i128).init(std.testing.allocator);
    defer transactions.deinit();
    var running_balance = std.ArrayList(i128).init(std.testing.allocator);
    defer running_balance.deinit();

    // Generate random transactions
    {
        var balance: i128 = 0;
        var i: usize = 0;
        while (i < 1_000_000) : (i += 1) {
            const amount = random.int(i64);
            try transactions.append(amount);

            balance += amount;
            try running_balance.append(balance);
        }
    }

    // Put transactions into tree in random order
    {
        var shuffled_transaction_indices = try std.ArrayList(usize).initCapacity(std.testing.allocator, transactions.items.len);
        defer shuffled_transaction_indices.deinit();
        for (transactions.items) |_, i| {
            shuffled_transaction_indices.appendAssumeCapacity(i);
        }

        random.shuffle(usize, shuffled_transaction_indices.items);

        for (shuffled_transaction_indices.items) |txIdx| {
            const amount = transactions.items[txIdx];
            tree.putNoClobber(txIdx, amount);
        }
    }

    // Ensure that the tree matches the running balance at each index
    for (running_balance.items) |balance, txIdx| {
        try std.testing.expectEqual(balance, tree.getBalance(txIdx));
    }
}
