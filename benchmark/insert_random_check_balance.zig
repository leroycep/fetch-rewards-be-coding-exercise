const std = @import("std");
const tracy = @import("tracy");
const Tree = @import("fetch-rewards-be-coding-exercise").transaction_tree.Tree;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    const t = tracy.trace(@src());
    defer t.end();

    var tree = Tree.init(allocator);
    defer tree.deinit();

    var default_prng = std.rand.DefaultPrng.init(13500266781291126803);
    const random = &default_prng.random;

    var transactions = std.ArrayList(i128).init(allocator);
    defer transactions.deinit();
    var running_balance = std.ArrayList(i128).init(allocator);
    defer running_balance.deinit();

    // Generate random transactions
    {
        const t1 = tracy.trace(@src());
        defer t1.end();

        var balance: i128 = 0;
        var i: usize = 0;
        while (i < 1_000_000) : (i += 1) {
            const amount = random.int(i64);
            try transactions.append(amount);

            try running_balance.append(balance);
            balance += amount;
        }
        try running_balance.append(balance);
    }

    // Put transactions into tree in random order
    {
        const t1 = tracy.trace(@src());
        defer t1.end();

        var shuffled_transaction_indices = try std.ArrayList(usize).initCapacity(allocator, transactions.items.len);
        defer shuffled_transaction_indices.deinit();
        for (transactions.items) |_, i| {
            shuffled_transaction_indices.appendAssumeCapacity(i);
        }

        random.shuffle(usize, shuffled_transaction_indices.items);

        for (shuffled_transaction_indices.items) |txIdx| {
            const amount = transactions.items[txIdx];
            try tree.putNoClobber(@intCast(i64, txIdx), amount);
        }
    }

    // Ensure that the tree matches the running balance at each index
    {
        const t1 = tracy.trace(@src());
        defer t1.end();
        for (running_balance.items) |balance, txIdx| {
            try std.testing.expectEqual(balance, tree.getBalance(@intCast(i64, txIdx)));
        }
    }
}
