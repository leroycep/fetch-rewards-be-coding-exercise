const std = @import("std");
const tracy = @import("tracy");

const PAGE_SIZE = 4096;
const LEAF_CELL_SIZE = 32;
const INTERNAL_CELL_SIZE = 32;
const MAX_LEAF_CELLS = (PAGE_SIZE - @sizeOf(NodeHeader)) / LEAF_CELL_SIZE;
const MAX_INTERNAL_CELLS = (PAGE_SIZE - @sizeOf(NodeHeader)) / INTERNAL_CELL_SIZE;
const MAX_DEPTH = 10;

comptime {
    std.debug.assert(LEAF_CELL_SIZE == @sizeOf(LeafCell));
    std.debug.assert(INTERNAL_CELL_SIZE == @sizeOf(InternalCell));
}

pub const Tree = struct {
    allocator: *std.mem.Allocator,
    root: ?NodePtr,
    freeNodes: std.ArrayList(NodePtr),

    pub fn init(allocator: *std.mem.Allocator) @This() {
        return @This(){
            .allocator = allocator,
            .root = null,
            .freeNodes = std.ArrayList(NodePtr).init(allocator),
        };
    }

    pub fn deinit(this: *@This()) void {
        if (this.root) |root| {
            // Iterate over root and free children nodes
            root.destroyChildrenAlloc(this.allocator);
            this.allocator.destroy(root);
        }
        for (this.freeNodes.items) |free_node| {
            this.allocator.destroy(free_node);
        }
        this.freeNodes.deinit();
    }

    fn createNode(this: *@This()) !NodePtr {
        return this.freeNodes.popOrNull() orelse {
            const node_slice = try this.allocator.allocWithOptions(Node, 1, PAGE_SIZE, null);
            return &node_slice[0];
        };
    }

    fn destroyNode(this: *@This(), node: NodePtr) void {
        this.freeNodes.append(node) catch {
            this.allocator.destroy(node);
        };
    }

    const PathSegment = struct {
        node: NodePtr,
        cellIdx: usize,
    };

    pub fn putNoClobber(this: *@This(), timestamp: i64, change: i128) !void {
        const t = tracy.trace(@src());
        defer t.end();

        if (this.root) |root| {
            switch (root.header.nodeType) {
                .leaf => {
                    switch (try this.putIntoLeafNode(root, timestamp, change)) {
                        .update => |new_node| {
                            this.root = new_node;
                            this.destroyNode(root);
                        },
                        .split => |new_nodes| {
                            const new_root = try this.createNode();

                            std.debug.assert(new_nodes.len == 2);
                            new_root.header = .{
                                .nodeType = .internal,
                                .count = 2,
                            };
                            for (new_nodes) |new_node, new_idx| {
                                new_root.cells.internal[new_idx] = .{
                                    .node = new_node,
                                    .greatestTimestamp = new_node.greatestTimestamp(),
                                    .cumulativeChange = new_node.cumulativeChange(),
                                };
                            }

                            this.root = new_root;
                            this.destroyNode(root);
                        },
                    }
                },
                .internal => {
                    var path = try std.BoundedArray(PathSegment, MAX_DEPTH).init(0);

                    try path.append(.{ .node = root, .cellIdx = undefined });

                    // Find leaf node
                    {
                        const t1 = tracy.trace(@src());
                        defer t1.end();

                        while (path.slice()[path.slice().len - 1].node.header.nodeType == .internal) {
                            const current = &path.slice()[path.slice().len - 1];
                            current.cellIdx = current.node.findInternalCellIdx(timestamp) orelse current.node.header.count - 1;
                            const next_node = current.node.cells.internal[current.cellIdx].node;
                            try path.append(.{ .node = next_node, .cellIdx = undefined });
                        }
                    }
                    const leaf_node = path.slice()[path.slice().len - 1].node;
                    std.debug.assert(leaf_node.header.nodeType == .leaf);

                    // Iterate over every node in path except the last
                    var put_result = try this.putIntoLeafNode(leaf_node, timestamp, change);
                    errdefer {
                        switch (put_result) {
                            .update => |new_node| {
                                new_node.destroyChildren(this);
                                this.destroyNode(new_node);
                            },
                            .split => |new_nodes| {
                                for (new_nodes) |new_node| {
                                    new_node.destroyChildren(this);
                                    this.destroyNode(new_node);
                                }
                            },
                        }
                    }

                    var path_idx = @intCast(isize, path.slice().len) - 2;
                    while (path_idx >= 0) : (path_idx -= 1) {
                        const path_segment = &path.slice()[@intCast(usize, path_idx)];

                        const new_put_result = try this.updateInternalNode(path_segment.node, path_segment.cellIdx, put_result);
                        put_result = new_put_result;
                    }

                    switch (put_result) {
                        .update => |new_node| this.root = new_node,
                        .split => |new_nodes| {
                            const new_root = try this.createNode();

                            std.debug.assert(new_nodes.len == 2);
                            new_root.header = .{
                                .nodeType = .internal,
                                .count = 2,
                            };
                            for (new_nodes) |new_node, new_idx| {
                                new_root.cells.internal[new_idx] = .{
                                    .node = new_node,
                                    .greatestTimestamp = new_node.greatestTimestamp(),
                                    .cumulativeChange = new_node.cumulativeChange(),
                                };
                            }

                            this.root = new_root;
                        },
                    }

                    {
                        const t1 = tracy.trace(@src());
                        defer t1.end();
                        for (path.slice()) |segment| {
                            this.destroyNode(segment.node);
                        }
                    }
                },
            }
        } else {
            const root = try this.createNode();

            root.* = .{
                .header = .{
                    .nodeType = .leaf,
                    .count = 1,
                },
                .cells = undefined,
            };
            root.cells.leaf[0] = .{
                .timestamp = timestamp,
                .change = change,
            };

            this.root = root;
        }
    }

    const PutLeafResult = union(enum) {
        update: NodePtr,
        split: [2]NodePtr,
    };

    /// Duplicates the leaf node and puts the given value into it. Caller is responsible for
    /// freeing the returned nodes and the node that was passed into.
    fn putIntoLeafNode(this: *@This(), leafNode: NodePtr, timestamp: i64, change: i128) !PutLeafResult {
        const t = tracy.trace(@src());
        defer t.end();
        std.debug.assert(leafNode.header.nodeType == .leaf);
        if (leafNode.header.count < MAX_LEAF_CELLS) {
            const new_leaf = try this.createNode();
            leafNode.copyTo(new_leaf);
            new_leaf.putLeafMutNoSplit(timestamp, change);
            return PutLeafResult{ .update = new_leaf };
        } else {
            const left_node = try this.createNode();
            const right_node = try this.createNode();

            const midpoint = leafNode.header.count / 2;

            left_node.header = .{
                .nodeType = .leaf,
                .count = midpoint,
            };
            std.mem.copy(LeafCell, left_node.cells.leaf[0..left_node.header.count], leafNode.cells.leaf[0..midpoint]);

            right_node.header = .{
                .nodeType = .leaf,
                .count = leafNode.header.count - midpoint,
            };
            std.mem.copy(LeafCell, right_node.cells.leaf[0..right_node.header.count], leafNode.cells.leaf[midpoint..leafNode.header.count]);

            std.debug.assert(leafNode.header.count == left_node.header.count + right_node.header.count);

            // insert value into the approriate new node
            if (timestamp <= left_node.greatestTimestamp()) {
                left_node.putLeafMutNoSplit(timestamp, change);
            } else {
                right_node.putLeafMutNoSplit(timestamp, change);
            }

            return PutLeafResult{ .split = .{ left_node, right_node } };
        }
    }

    /// Duplicates the internal node and points it to the new child nodes.
    ///
    /// `cellIdx` is the index of the cell that was pointing to the child node before the update.
    fn updateInternalNode(this: *@This(), internalNode: NodePtr, cellIdx: usize, prevResult: PutLeafResult) !PutLeafResult {
        const t = tracy.trace(@src());
        defer t.end();
        std.debug.assert(internalNode.header.nodeType == .internal);
        std.debug.assert(cellIdx <= internalNode.header.count);
        if (prevResult == .update or internalNode.header.count < MAX_INTERNAL_CELLS) {
            const new_internal = try this.createNode();

            new_internal.header = internalNode.header;

            std.mem.copy(
                InternalCell,
                new_internal.cells.internal[0..cellIdx],
                internalNode.cells.internal[0..cellIdx],
            );

            switch (prevResult) {
                .update => |new_node| {
                    std.mem.copy(
                        InternalCell,
                        new_internal.cells.internal[cellIdx + 1 .. internalNode.header.count],
                        internalNode.cells.internal[cellIdx + 1 .. internalNode.header.count],
                    );
                    new_internal.cells.internal[cellIdx] = .{
                        .node = new_node,
                        .greatestTimestamp = new_node.greatestTimestamp(),
                        .cumulativeChange = new_node.cumulativeChange(),
                    };
                },
                .split => |new_nodes| {
                    std.mem.copy(
                        InternalCell,
                        new_internal.cells.internal[cellIdx + 2 .. internalNode.header.count + 1],
                        internalNode.cells.internal[cellIdx + 1 .. internalNode.header.count],
                    );
                    for (new_nodes) |new_node, offset| {
                        new_internal.cells.internal[cellIdx + offset] = .{
                            .node = new_node,
                            .greatestTimestamp = new_node.greatestTimestamp(),
                            .cumulativeChange = new_node.cumulativeChange(),
                        };
                    }
                    new_internal.header.count += 1;
                },
            }

            return PutLeafResult{ .update = new_internal };
        } else {
            const left_node = try this.createNode();
            const right_node = try this.createNode();

            const midpoint = internalNode.header.count / 2;

            left_node.header = .{
                .nodeType = .internal,
                .count = midpoint,
            };

            right_node.header = .{
                .nodeType = .internal,
                .count = internalNode.header.count - midpoint,
            };

            std.debug.assert(internalNode.header.count == left_node.header.count + right_node.header.count);

            if (cellIdx < midpoint) {
                std.mem.copy(InternalCell, right_node.cells.internal[0..right_node.header.count], internalNode.cells.internal[midpoint..internalNode.header.count]);

                const idx = cellIdx;
                std.mem.copy(InternalCell, left_node.cells.internal[0..idx], internalNode.cells.internal[0..idx]);
                std.mem.copy(InternalCell, left_node.cells.internal[idx + 2 .. left_node.header.count + 1], internalNode.cells.internal[idx + 1 .. left_node.header.count]);

                for (prevResult.split) |new_node, offset| {
                    left_node.cells.internal[idx + offset] = .{
                        .node = new_node,
                        .greatestTimestamp = new_node.greatestTimestamp(),
                        .cumulativeChange = new_node.cumulativeChange(),
                    };
                }

                left_node.header.count += 1;
            } else if (cellIdx == midpoint) {
                std.mem.copy(InternalCell, left_node.cells.internal[0..left_node.header.count], internalNode.cells.internal[0..midpoint]);
                std.mem.copy(InternalCell, right_node.cells.internal[0..right_node.header.count], internalNode.cells.internal[midpoint..internalNode.header.count]);

                left_node.cells.internal[left_node.header.count] = .{
                    .node = prevResult.split[0],
                    .greatestTimestamp = prevResult.split[0].greatestTimestamp(),
                    .cumulativeChange = prevResult.split[0].cumulativeChange(),
                };
                left_node.header.count += 1;
                right_node.cells.internal[0] = .{
                    .node = prevResult.split[1],
                    .greatestTimestamp = prevResult.split[1].greatestTimestamp(),
                    .cumulativeChange = prevResult.split[1].cumulativeChange(),
                };
            } else {
                std.mem.copy(InternalCell, left_node.cells.internal[0..left_node.header.count], internalNode.cells.internal[0..left_node.header.count]);

                const idx = cellIdx - midpoint;
                std.mem.copy(InternalCell, right_node.cells.internal[0..idx], internalNode.cells.internal[midpoint..cellIdx]);
                std.mem.copy(InternalCell, right_node.cells.internal[idx + 2 .. right_node.header.count + 1], internalNode.cells.internal[cellIdx + 1 .. internalNode.header.count]);

                for (prevResult.split) |new_node, offset| {
                    right_node.cells.internal[idx + offset] = .{
                        .node = new_node,
                        .greatestTimestamp = new_node.greatestTimestamp(),
                        .cumulativeChange = new_node.cumulativeChange(),
                    };
                }

                right_node.header.count += 1;
            }

            std.debug.assert(internalNode.header.count + 1 == left_node.header.count + right_node.header.count);

            return PutLeafResult{ .split = .{ left_node, right_node } };
        }
    }

    pub fn getBalance(this: @This()) i128 {
        const t = tracy.trace(@src());
        defer t.end();

        if (this.root) |root| {
            return root.cumulativeChange();
        }

        return 0;
    }

    pub fn getBalanceAtTime(this: @This(), timestamp: i64) i128 {
        const t = tracy.trace(@src());
        defer t.end();

        var balance: i128 = 0;
        if (this.root) |root| {
            var node = root;
            while (node.header.nodeType == .internal) {
                var idx: usize = 0;
                while (idx < node.header.count and node.cells.internal[idx].greatestTimestamp < timestamp) : (idx += 1) {
                    balance += node.cells.internal[idx].cumulativeChange;
                }

                if (idx >= node.header.count) return balance;

                node = node.cells.internal[idx].node;
            }

            std.debug.assert(node.header.nodeType == .leaf);

            for (node.cells.leaf[0..node.header.count]) |leaf_cell| {
                if (leaf_cell.timestamp < timestamp) {
                    balance += leaf_cell.change;
                } else {
                    break;
                }
            }
        }

        return balance;
    }

    pub const Entry = struct {
        timestamp: i64,
        change: i128,
    };

    const Iterator = struct {
        tree: *const Tree,
        path: std.BoundedArray(PathSegment, MAX_DEPTH),

        pub fn next(this: *@This()) !?Entry {
            if (this.path.len == 0) return null;

            var currentNode = &this.path.slice()[this.path.len - 1];
            while (currentNode.cellIdx >= currentNode.node.header.count) {
                _ = this.path.pop();
                if (this.path.len < 1) return null;
                currentNode = &this.path.slice()[this.path.len - 1];
            }

            while (currentNode.node.header.nodeType == .internal) {
                if (currentNode.cellIdx >= currentNode.node.header.count) return null;
                try this.path.append(.{
                    .node = currentNode.node.cells.internal[currentNode.cellIdx].node,
                    .cellIdx = 0,
                });
                currentNode.cellIdx += 1;
                currentNode = &this.path.slice()[this.path.len - 1];
            }

            const cell = currentNode.node.cells.leaf[currentNode.cellIdx];
            const entry = Entry{
                .timestamp = cell.timestamp,
                .change = cell.change,
            };
            currentNode.cellIdx += 1;
            return entry;
        }

        pub fn prev(this: *@This()) !?Entry {
            if (this.path.len == 0) return null;

            var currentNode = &this.path.slice()[this.path.len - 1];
            while (currentNode.cellIdx == 0) {
                _ = this.path.pop();
                if (this.path.len < 1) return null;
                currentNode = &this.path.slice()[this.path.len - 1];
            }

            while (currentNode.node.header.nodeType == .internal) {
                if (currentNode.cellIdx == 0) return null;
                const prev_node = currentNode.node.cells.internal[currentNode.cellIdx - 1].node;
                try this.path.append(.{
                    .node = prev_node,
                    .cellIdx = prev_node.header.count,
                });
                currentNode.cellIdx -= 1;
                currentNode = &this.path.slice()[this.path.len - 1];
            }

            const cell = currentNode.node.cells.leaf[currentNode.cellIdx - 1];
            const entry = Entry{
                .timestamp = cell.timestamp,
                .change = cell.change,
            };
            currentNode.cellIdx -= 1;
            return entry;
        }
    };

    pub const Position = union(enum) {
        first: void,
        last: void,
    };

    pub fn iterator(this: *const @This(), pos: Position) Iterator {
        var path = std.BoundedArray(PathSegment, MAX_DEPTH).init(0) catch unreachable;
        if (this.root) |root| {
            switch (pos) {
                .first => path.append(.{
                    .node = root,
                    .cellIdx = 0,
                }) catch unreachable,
                .last => path.append(.{
                    .node = root,
                    .cellIdx = root.header.count,
                }) catch unreachable,
            }
        }
        return Iterator{
            .tree = this,
            .path = path,
        };
    }
};

const NodePtr = *align(PAGE_SIZE) Node;
//const NodePtrMut = *align(PAGE_SIZE) Node;

const Node = extern struct {
    header: NodeHeader,
    cells: packed union {
        leaf: [MAX_LEAF_CELLS]LeafCell,
        internal: [MAX_INTERNAL_CELLS]InternalCell,
    },

    pub fn destroyChildren(this: @This(), tree: *Tree) void {
        if (this.header.nodeType == .leaf) return;
        for (this.cells.internal[0..this.header.count]) |internal_cell| {
            internal_cell.node.destroyChildren(tree);
            tree.destroyNode(internal_cell.node);
        }
    }

    pub fn destroyChildrenAlloc(this: @This(), allocator: *std.mem.Allocator) void {
        if (this.header.nodeType == .leaf) return;
        for (this.cells.internal[0..this.header.count]) |internal_cell| {
            internal_cell.node.destroyChildrenAlloc(allocator);
            allocator.destroy(internal_cell.node);
        }
    }

    pub fn copyTo(this: @This(), other: NodePtr) void {
        other.header = this.header;

        const count = this.header.count;
        switch (this.header.nodeType) {
            .leaf => std.mem.copy(
                LeafCell,
                other.cells.leaf[0..count],
                this.cells.leaf[0..count],
            ),
            .internal => std.mem.copy(
                InternalCell,
                other.cells.internal[0..count],
                this.cells.internal[0..count],
            ),
        }
    }

    pub fn smallestTimestamp(this: @This()) i64 {
        std.debug.assert(this.header.count != 0);
        return switch (this.header.nodeType) {
            .leaf => this.cells.leaf[0].timestamp,
            .internal => this.cells.internal[0].node.smallestTimestamp(),
        };
    }

    pub fn greatestTimestamp(this: @This()) i64 {
        const count = this.header.count;
        return switch (this.header.nodeType) {
            .leaf => this.cells.leaf[count - 1].timestamp,
            .internal => this.cells.internal[count - 1].greatestTimestamp,
        };
    }

    pub fn cumulativeChange(this: @This()) i128 {
        const count = this.header.count;

        var cumulative_change: i128 = 0;
        switch (this.header.nodeType) {
            .leaf => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    cumulative_change += this.cells.leaf[i].change;
                }
                //for (this.cells.leaf[0..count]) |_, idx| {
                //    cumulative_change += this.cells.leaf[idx].change;
                //}
            },
            .internal => {
                //for (this.cells.internal[0..count]) |internal_cell| {
                //    cumulative_change += internal_cell.cumulativeChange;
                //}
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    cumulative_change += this.cells.internal[i].cumulativeChange;
                }
            },
        }

        return cumulative_change;
    }

    /// Find the internal cell that points to a node that may contain the given timestamp, or
    /// null if the timestamp is greater than any timestamp in this node.
    pub fn findInternalCellIdx(this: @This(), timestamp: i64) ?usize {
        const t = tracy.trace(@src());
        defer t.end();

        std.debug.assert(this.header.nodeType == .internal);

        const count = this.header.count;

        for (this.cells.internal[0..count]) |cell, idx| {
            if (timestamp < cell.greatestTimestamp) {
                return idx;
            }
        }

        return null;
    }

    fn putLeafMutNoSplit(this: *@This(), timestamp: i64, change: i128) void {
        std.debug.assert(this.header.nodeType == .leaf);
        std.debug.assert(this.header.count < MAX_LEAF_CELLS);

        // Find where to insert cell in leaf cell array
        for (this.cells.leaf[0..this.header.count]) |leaf_cell, idx| {
            if (leaf_cell.timestamp == timestamp) {
                // Replace cell
                unreachable; // No clobber, user guarantees this won't happen
            } else if (leaf_cell.timestamp > timestamp) {
                // Insert cell in the middle of the array
                var prev_cell = LeafCell{ .timestamp = timestamp, .change = change };
                for (this.cells.leaf[idx .. this.header.count + 1]) |*cell_to_move| {
                    const tmp = cell_to_move.*;
                    cell_to_move.* = prev_cell;
                    prev_cell = tmp;
                    //std.mem.swap(LeafCell, &prev_cell, cell_to_move);
                }
                this.header.count += 1;
                break;
            }
        } else {
            // Insert cell at end of array
            this.cells.leaf[this.header.count] = .{
                .timestamp = timestamp,
                .change = change,
            };
            this.header.count += 1;
        }
    }
};

const NodeHeader = extern struct {
    nodeType: NodeType,
    count: u16,
};

const NodeType = enum(u8) {
    leaf,
    internal,
};

const LeafCell = extern struct {
    change: i128,
    timestamp: i64,
};

const InternalCell = extern struct {
    greatestTimestamp: i64,
    node: NodePtr,
    cumulativeChange: i128,
};

test "align of node" {
    const nodes = try std.testing.allocator.allocWithOptions(Node, 2, PAGE_SIZE, null);
    defer std.testing.allocator.free(nodes);

    try std.testing.expect(@ptrToInt(nodes[1..].ptr) - @ptrToInt(nodes[0..].ptr) <= PAGE_SIZE);
}

test "tree returns balance up to timestamp non inclusive" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.putNoClobber(100, 1_000);
    try tree.putNoClobber(300, 1_000);
    try tree.putNoClobber(666, 666);
    try tree.putNoClobber(1000, 1_337);
    try tree.putNoClobber(1001, -500);

    try std.testing.expectEqual(@as(i128, 0), tree.getBalanceAtTime(100));
    try std.testing.expectEqual(@as(i128, 1_000), tree.getBalanceAtTime(101));

    try std.testing.expectEqual(@as(i128, 1_000), tree.getBalanceAtTime(300));
    try std.testing.expectEqual(@as(i128, 2_000), tree.getBalanceAtTime(301));

    try std.testing.expectEqual(@as(i128, 2_000), tree.getBalanceAtTime(666));
    try std.testing.expectEqual(@as(i128, 2_666), tree.getBalanceAtTime(667));

    try std.testing.expectEqual(@as(i128, 2_666), tree.getBalanceAtTime(1000));
    try std.testing.expectEqual(@as(i128, 4_003), tree.getBalanceAtTime(1001));
    try std.testing.expectEqual(@as(i128, 3_503), tree.getBalanceAtTime(1002));
}

test "add 10_000 transactions and randomly query balance" {
    const t = tracy.trace(@src());
    defer t.end();

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
        const t1 = tracy.trace(@src());
        defer t1.end();

        var balance: i128 = 0;
        var i: usize = 0;
        while (i < 10_000) : (i += 1) {
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

        var shuffled_transaction_indices = try std.ArrayList(usize).initCapacity(std.testing.allocator, transactions.items.len);
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
    const t1 = tracy.trace(@src());
    defer t1.end();
    for (running_balance.items) |balance, txIdx| {
        try std.testing.expectEqual(balance, tree.getBalanceAtTime(@intCast(i64, txIdx)));
    }
}

test "add 1_000 transactions and iterate" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    var default_prng = std.rand.DefaultPrng.init(13280421048943141057);
    const random = &default_prng.random;

    var transactions = std.ArrayList(i128).init(std.testing.allocator);
    defer transactions.deinit();

    // Generate random transactions
    {
        var i: usize = 0;
        while (i < 1_000) : (i += 1) {
            try transactions.append(random.int(i64));
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
            try tree.putNoClobber(@intCast(i64, txIdx), amount);
        }
    }

    // Ensure that the tree matches the running balance at each index
    {
        var iterator = tree.iterator(.first);
        var count: usize = 0;
        while (try iterator.next()) |entry| {
            try std.testing.expectEqual(transactions.items[@intCast(usize, entry.timestamp)], entry.change);
            count += 1;
        }
        try std.testing.expectEqual(transactions.items.len, count);
    }
    {
        var iterator = tree.iterator(.last);
        var count: usize = 0;
        while (try iterator.prev()) |entry| {
            try std.testing.expectEqual(transactions.items[@intCast(usize, entry.timestamp)], entry.change);
            count += 1;
        }
        try std.testing.expectEqual(transactions.items.len, count);
    }
}
