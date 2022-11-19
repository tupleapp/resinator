const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn randomNumberLiteral(allocator: Allocator, rand: std.rand.Random) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const Prefix = enum { none, minus, complement };
    var prefix = rand.enumValue(Prefix);

    switch (prefix) {
        .none => {},
        .minus => try buf.append('-'),
        .complement => try buf.append('~'),
    }

    const has_radix = rand.boolean();
    if (has_radix) {
        try buf.append('0');
        var radix_specifier = randomAlphanumeric(rand);
        // The Windows RC preprocessor rejects number literals of the pattern \d+[eE]\d
        // so just switch to x to avoid this cropping up a ton.
        //
        // Note: This \d+[eE]\d pattern is still possible to generate in the
        // main number literal component stuff below)
        if (std.ascii.toLower(radix_specifier) == 'e') radix_specifier += 'x' - 'e';
        try buf.append(radix_specifier);
    } else {
        // needs to start with a digit
        try buf.append(randomNumeric(rand));
    }

    // TODO: increase this limit?
    var length = rand.int(u8);
    if (length == 0 and !has_radix and prefix == .none) {
        length = 1;
    }
    const num_numeric_digits = rand.uintLessThanBiased(usize, @as(usize, length) + 1);
    var i: usize = 0;
    while (i < length) : (i += 1) {
        if (i < num_numeric_digits) {
            try buf.append(randomNumeric(rand));
        } else {
            try buf.append(randomAlphanumeric(rand));
        }
    }

    return buf.toOwnedSlice();
}

pub fn randomAlphanumeric(rand: std.rand.Random) u8 {
    const dict = [_]u8{
        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
        'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j',
        'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't',
        'u', 'v', 'w', 'x', 'y', 'z', 'A', 'B', 'C', 'D',
        'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N',
        'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X',
        'Y', 'Z',
    };
    var index = rand.uintLessThanBiased(u8, dict.len);
    return dict[index];
}

pub fn randomNumeric(rand: std.rand.Random) u8 {
    return rand.uintLessThanBiased(u8, 10) + '0';
}

pub fn randomOperator(rand: std.rand.Random) u8 {
    const dict = [_]u8{ '-', '+', '|', '&' };
    const index = rand.uintLessThanBiased(u8, dict.len);
    return dict[index];
}

pub fn randomAsciiStringLiteral(allocator: Allocator, rand: std.rand.Random) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.append('"');

    // for now, just a backslash and then a random alphanumeric
    try buf.append('\\');
    try buf.append(randomAlphanumeric(rand));

    try buf.append('"');

    return buf.toOwnedSlice();
}

/// Iterates all K-permutations of the given size `n` where k varies from (0..n).
/// e.g. for AllKPermutationsIterator(3) the returns from `next` will be (in this order):
/// k=0 {  }
/// k=1 { 0 } { 1 } { 2 }
/// k=2 { 0, 1 } { 0, 2 } { 1, 0 } { 1, 2 } { 2, 0 } { 2, 1 }
/// k=3 { 0, 1, 2 } { 0, 2, 1 } { 1, 0, 2 } { 1, 2, 0 } { 2, 0, 1 } { 2, 1, 0 }
pub fn AllKPermutationsIterator(comptime n: usize) type {
    return struct {
        buf: [n]usize,
        iterator: KPermutationsIterator,
        k: usize,

        const Self = @This();

        pub fn init() Self {
            var self = Self{
                .buf = undefined,
                .iterator = undefined,
                .k = 0,
            };
            self.resetBuf();
            return self;
        }

        fn resetBuf(self: *Self) void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                self.buf[i] = i;
            }
        }

        fn nextK(self: *Self) void {
            self.resetBuf();
            self.k += 1;
            self.iterator = KPermutationsIterator.init(&self.buf, self.k);
        }

        pub fn next(self: *Self) ?[]usize {
            if (self.k == 0) {
                self.nextK();
                return self.buf[0..0];
            }

            if (self.iterator.next()) |perm| {
                return perm;
            } else {
                if (self.k == n) {
                    return null;
                }
                self.nextK();
                return self.iterator.next().?;
            }
        }
    };
}

test "AllKPermutationsIterator" {
    const n = 5;
    var iterator = AllKPermutationsIterator(n).init();
    var i: usize = 0;
    while (iterator.next()) |_| {
        i += 1;
    }
    try std.testing.expectEqual(numAllKPermutations(n), i);
}

pub const KPermutationsIterator = struct {
    indexes: []usize,
    k: usize,
    initial: bool = true,

    pub fn init(indexes_in_order: []usize, k: usize) KPermutationsIterator {
        return .{
            .indexes = indexes_in_order,
            .k = k,
        };
    }

    /// Adapted from https://stackoverflow.com/a/51292710
    pub fn next(self: *KPermutationsIterator) ?[]usize {
        if (self.initial) {
            self.initial = false;
            return self.indexes[0..self.k];
        }
        const n = self.indexes.len;
        var tailmax = self.indexes[n - 1];
        var tail: usize = self.k;
        while (tail > 0 and self.indexes[tail - 1] >= tailmax) {
            tail -= 1;
            tailmax = self.indexes[tail];
        }

        if (tail > 0) {
            var swap_in: usize = 0;
            var pivot: usize = self.indexes[tail - 1];

            if (pivot >= self.indexes[n - 1]) {
                swap_in = tail;
                while (swap_in + 1 < self.k and self.indexes[swap_in + 1] > pivot) : (swap_in += 1) {}
            } else {
                swap_in = n - 1;
                while (swap_in > self.k and self.indexes[swap_in - 1] > pivot) : (swap_in -= 1) {}
            }

            // swap the pivots
            self.indexes[tail - 1] = self.indexes[swap_in];
            self.indexes[swap_in] = pivot;

            // flip the tail
            flip(self.indexes, self.k, n);
            flip(self.indexes, tail, n);
        }

        if (tail > 0) {
            return self.indexes[0..self.k];
        } else {
            return null;
        }
    }
};

test "KPermutationsIterator" {
    var buf = [_]usize{ 0, 1, 2, 3, 4 };
    var iterator = KPermutationsIterator.init(&buf, 2);
    var i: usize = 0;
    while (iterator.next()) |_| {
        i += 1;
    }
    try std.testing.expectEqual(numKPermutationsWithoutRepetition(buf.len, 2), i);
}

fn flip(elements: []usize, lo: usize, hi: usize) void {
    var _lo = lo;
    var _hi = hi;
    while (_lo + 1 < _hi) : ({
        _lo += 1;
        _hi -= 1;
    }) {
        swap(elements, _lo, _hi - 1);
    }
}

fn swap(elements: []usize, a: usize, b: usize) void {
    const tmp = elements[a];
    elements[a] = elements[b];
    elements[b] = tmp;
}

pub fn numAllKPermutations(n: usize) usize {
    // P(n, 0) = n!/(n-0)! = 1
    // P(n, 1) = n!/(n-1)! = choices
    // P(n, 2) = n!/(n-2)!
    // ...
    // P(n, n) = n!
    var k: usize = 0;
    var num: usize = 0;
    while (k <= n) : (k += 1) {
        num += numKPermutationsWithoutRepetition(n, k);
    }
    return num;
}

fn numKPermutationsWithoutRepetition(n: usize, k: usize) usize {
    return factorial(n) / factorial(n - k);
}

fn factorial(n: usize) usize {
    var result: usize = 1;
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        result *= i;
    }
    return result;
}