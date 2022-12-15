const std = @import("std");
const rc = @import("rc.zig");
const Resource = rc.Resource;
const CommonResourceAttributes = rc.CommonResourceAttributes;
const Allocator = std.mem.Allocator;
const windows1252 = @import("windows1252.zig");
const CodePage = @import("code_pages.zig").CodePage;
const literals = @import("literals.zig");
const SourceBytes = literals.SourceBytes;
const Codepoint = @import("code_pages.zig").Codepoint;

/// https://learn.microsoft.com/en-us/windows/win32/menurc/resource-types
pub const RT = enum(u8) {
    ACCELERATOR = 9,
    ANICURSOR = 21,
    ANIICON = 22,
    BITMAP = 2,
    CURSOR = 1,
    DIALOG = 5,
    DLGINCLUDE = 17,
    FONT = 8,
    FONTDIR = 7,
    GROUP_CURSOR = 1 + 11, // CURSOR + 11
    GROUP_ICON = 3 + 11, // ICON + 11
    HTML = 23,
    ICON = 3,
    MANIFEST = 24,
    MENU = 4,
    MESSAGETABLE = 11,
    PLUGPLAY = 19,
    RCDATA = 10,
    STRING = 6,
    VERSION = 16,
    VXD = 20,
    _,

    /// Returns null if the resource type doesn't have a 1:1 mapping with an RT constant
    pub fn fromResource(resource: Resource) ?RT {
        return switch (resource) {
            .accelerators => .ACCELERATOR,
            .bitmap => .BITMAP,
            .cursor => .GROUP_CURSOR,
            .dialog => .DIALOG,
            .dialogex => null, // TODO: ?
            .font => .FONT,
            .html => .HTML,
            .icon => .GROUP_ICON,
            .menu => .MENU,
            .menuex => null, // TODO: ?
            .messagetable => .MESSAGETABLE,
            .popup => null,
            .plugplay => .PLUGPLAY,
            .rcdata => .RCDATA,
            .stringtable => null, // TODO: Maybe unreachable?
            .user_defined => null,
            .versioninfo => .VERSION,
            .vxd => .VXD,

            .cursor_num => .CURSOR,
            .icon_num => .ICON,
            .string_num => .STRING,
            .anicursor_num => .ANICURSOR,
            .aniicon_num => .ANIICON,
            .dlginclude_num => .DLGINCLUDE,
            .fontdir_num => .FONTDIR,
            .manifest_num => .MANIFEST,
        };
    }
};

/// https://learn.microsoft.com/en-us/windows/win32/menurc/common-resource-attributes
/// https://learn.microsoft.com/en-us/windows/win32/menurc/resourceheader
pub const MemoryFlags = packed struct(u16) {
    value: u16,

    pub const MOVEABLE: u16 = 0x10;
    // TODO: SHARED and PURE seem to be the same thing? Testing seems to confirm this but
    //       would like to find mention of it somewhere.
    pub const SHARED: u16 = 0x20;
    pub const PURE: u16 = 0x20;
    pub const PRELOAD: u16 = 0x40;
    pub const DISCARDABLE: u16 = 0x1000;

    /// Note: The defaults can have combinations that are not possible to specify within
    ///       an .rc file, as the .rc attributes imply other values (i.e. specifying
    ///       DISCARDABLE always implies MOVEABLE and PURE/SHARED, and yet RT_ICON
    ///       has a default of only MOVEABLE | DISCARDABLE).
    pub fn defaults(predefined_resource_type: ?RT) MemoryFlags {
        if (predefined_resource_type == null) {
            return MemoryFlags{ .value = MOVEABLE | SHARED };
        } else {
            return switch (predefined_resource_type.?) {
                .RCDATA, .BITMAP, .HTML, .MANIFEST, .ACCELERATOR => MemoryFlags{ .value = MOVEABLE | SHARED },
                .GROUP_ICON, .GROUP_CURSOR, .STRING, .FONT => MemoryFlags{ .value = MOVEABLE | SHARED | DISCARDABLE },
                .ICON, .CURSOR => MemoryFlags{ .value = MOVEABLE | DISCARDABLE },
                .FONTDIR => MemoryFlags{ .value = MOVEABLE | PRELOAD },
                else => {
                    std.debug.print("TODO: {}\n", .{predefined_resource_type.?});
                    @panic("TODO");
                },
            };
        }
    }

    pub fn set(self: *MemoryFlags, attribute: CommonResourceAttributes) void {
        switch (attribute) {
            .preload => self.value |= PRELOAD,
            .loadoncall => self.value &= ~PRELOAD,
            .moveable => self.value |= MOVEABLE,
            .fixed => self.value &= ~(MOVEABLE | DISCARDABLE),
            .shared => self.value |= SHARED,
            .nonshared => self.value &= ~(SHARED | DISCARDABLE),
            .pure => self.value |= PURE,
            .impure => self.value &= ~(PURE | DISCARDABLE),
            .discardable => self.value |= DISCARDABLE | MOVEABLE | PURE,
        }
    }
};

/// https://learn.microsoft.com/en-us/windows/win32/intl/language-identifiers
pub const Language = packed struct(u16) {
    // TODO: Are these defaults dependent on the system's language setting at the time
    //       that the RC compiler is run?
    primary_language_id: u10 = 0x09, // LANG_ENGLISH
    sublanguage_id: u6 = 0x01, // SUBLANG_ENGLISH_US (since primary is ENGLISH)
};

pub const NameOrOrdinal = union(enum) {
    name: [:0]const u16,
    ordinal: u16,

    pub fn deinit(self: NameOrOrdinal, allocator: Allocator) void {
        switch (self) {
            .name => |name| {
                allocator.free(name);
            },
            .ordinal => {},
        }
    }

    /// Returns the full length of the amount of bytes that would be written by `write`
    /// (e.g. for an ordinal it will return the length including the 0xFFFF indicator)
    pub fn byteLen(self: NameOrOrdinal) u32 {
        switch (self) {
            .name => |name| {
                // + 1 for 0-terminated, * 2 for bytes per u16
                return @intCast(u32, (name.len + 1) * 2);
            },
            .ordinal => return 4,
        }
    }

    pub fn write(self: NameOrOrdinal, writer: anytype) !void {
        switch (self) {
            .name => |name| {
                try writer.writeAll(std.mem.sliceAsBytes(name[0 .. name.len + 1]));
            },
            .ordinal => |ordinal| {
                try writer.writeIntLittle(u16, 0xffff);
                try writer.writeIntLittle(u16, ordinal);
            },
        }
    }

    pub fn fromString(allocator: Allocator, bytes: SourceBytes) !NameOrOrdinal {
        if (maybeOrdinalFromString(bytes)) |ordinal| {
            return ordinal;
        }
        return nameFromString(allocator, bytes);
    }

    pub fn nameFromString(allocator: Allocator, bytes: SourceBytes) !NameOrOrdinal {
        // Names have a limit of 256 UTF-16 code units + null terminator
        var buf = try std.ArrayList(u16).initCapacity(allocator, @min(257, bytes.slice.len));
        errdefer buf.deinit();

        var i: usize = 0;
        while (bytes.code_page.codepointAt(i, bytes.slice)) |codepoint| : (i += codepoint.byte_len) {
            if (buf.items.len == 256) break;

            const c = codepoint.value;
            if (c == Codepoint.invalid) {
                try buf.append(std.mem.nativeToLittle(u16, '�'));
            } else if (c < 0x7F) {
                // ASCII chars in names are always converted to uppercase
                try buf.append(std.ascii.toUpper(@intCast(u8, c)));
            } else if (c < 0x10000) {
                const short = @intCast(u16, c);
                try buf.append(std.mem.nativeToLittle(u16, short));
            } else {
                const high = @intCast(u16, (c - 0x10000) >> 10) + 0xD800;
                try buf.append(std.mem.nativeToLittle(u16, high));

                // Note: This can cut-off in the middle of a UTF-16 surrogate pair,
                //       i.e. it can make the string end with an unpaired high surrogate
                if (buf.items.len == 256) break;

                const low = @intCast(u16, c & 0x3FF) + 0xDC00;
                try buf.append(std.mem.nativeToLittle(u16, low));
            }
        }

        return NameOrOrdinal{ .name = try buf.toOwnedSliceSentinel(0) };
    }

    pub fn maybeOrdinalFromString(bytes: SourceBytes) ?NameOrOrdinal {
        var buf = bytes.slice;
        var radix: u8 = 10;
        if (buf.len > 2 and buf[0] == '0') {
            switch (buf[1]) {
                '0'...'9' => {},
                'x', 'X' => {
                    radix = 16;
                    buf = buf[2..];
                    // only the first 4 hex digits matter, anything else is ignored
                    // i.e. 0x12345 is treated as if it were 0x1234
                    buf.len = @min(buf.len, 4);
                },
                else => return null,
            }
        }

        var i: usize = 0;
        var result: u16 = 0;
        while (bytes.code_page.codepointAt(i, buf)) |codepoint| : (i += codepoint.byte_len) {
            const c = codepoint.value;
            const digit = switch (c) {
                // I have no idea why this is the case, but the Windows RC compiler
                // treats ¹, ², and ³ characters as valid digits when the radix is 10
                '¹', '²', '³' => if (radix != 10) break else @intCast(u8, c) - 0x30,
                0x00...0x7F => std.fmt.charToDigit(@intCast(u8, c), radix) catch switch (radix) {
                    10 => return null,
                    // non-hex-digits are treated as a terminator rather than invalidating
                    // the number (note: if there are no valid hex digits then the result
                    // will be zero which is not treated as a valid number)
                    16 => break,
                    else => unreachable,
                },
                else => if (radix == 10) return null else break,
            };

            if (result != 0) {
                result *%= radix;
            }
            result +%= digit;
        }

        // Anything that resolves to zero is not interpretted as a number
        if (result == 0) return null;
        return NameOrOrdinal{ .ordinal = result };
    }

    pub fn predefinedResourceType(self: NameOrOrdinal) ?RT {
        switch (self) {
            .ordinal => |ordinal| {
                switch (@intToEnum(RT, ordinal)) {
                    .ACCELERATOR,
                    .ANICURSOR,
                    .ANIICON,
                    .BITMAP,
                    .CURSOR,
                    .DIALOG,
                    .DLGINCLUDE,
                    .FONT,
                    .FONTDIR,
                    .GROUP_CURSOR,
                    .GROUP_ICON,
                    .HTML,
                    .ICON,
                    .MANIFEST,
                    .MENU,
                    .MESSAGETABLE,
                    .PLUGPLAY,
                    .RCDATA,
                    .STRING,
                    .VERSION,
                    .VXD,
                    => |rt| return rt,
                    _ => return null,
                }
            },
            .name => return null,
        }
    }
};

fn expectNameOrOrdinal(expected: NameOrOrdinal, actual: NameOrOrdinal) !void {
    switch (expected) {
        .name => {
            if (actual != .name) return error.TestExpectedEqual;
            try std.testing.expectEqualSlices(u16, expected.name, actual.name);
        },
        .ordinal => {
            if (actual != .ordinal) return error.TestExpectedEqual;
            try std.testing.expectEqual(expected.ordinal, actual.ordinal);
        },
    }
}

test "NameOrOrdinal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // zero is treated as a string
    try expectNameOrOrdinal(
        NameOrOrdinal{ .name = std.unicode.utf8ToUtf16LeStringLiteral("0") },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "0", .code_page = .windows1252 }),
    );
    // any non-digit byte invalidates the number
    try expectNameOrOrdinal(
        NameOrOrdinal{ .name = std.unicode.utf8ToUtf16LeStringLiteral("1A") },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "1a", .code_page = .windows1252 }),
    );
    try expectNameOrOrdinal(
        NameOrOrdinal{ .name = std.unicode.utf8ToUtf16LeStringLiteral("1ÿ") },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "1\xff", .code_page = .windows1252 }),
    );
    try expectNameOrOrdinal(
        NameOrOrdinal{ .name = std.unicode.utf8ToUtf16LeStringLiteral("1€") },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "1€", .code_page = .utf8 }),
    );
    try expectNameOrOrdinal(
        NameOrOrdinal{ .name = std.unicode.utf8ToUtf16LeStringLiteral("1�") },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "1\x80", .code_page = .utf8 }),
    );
    // same with overflow that resolves to 0
    try expectNameOrOrdinal(
        NameOrOrdinal{ .name = std.unicode.utf8ToUtf16LeStringLiteral("65536") },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "65536", .code_page = .windows1252 }),
    );
    // hex zero is also treated as a string
    try expectNameOrOrdinal(
        NameOrOrdinal{ .name = std.unicode.utf8ToUtf16LeStringLiteral("0X0") },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "0x0", .code_page = .windows1252 }),
    );
    // hex numbers work
    try expectNameOrOrdinal(
        NameOrOrdinal{ .ordinal = 0x100 },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "0x100", .code_page = .windows1252 }),
    );
    // only the first 4 hex digits matter
    try expectNameOrOrdinal(
        NameOrOrdinal{ .ordinal = 0x1234 },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "0X12345", .code_page = .windows1252 }),
    );
    // octal is not supported so it gets treated as a string
    try expectNameOrOrdinal(
        NameOrOrdinal{ .name = std.unicode.utf8ToUtf16LeStringLiteral("0O1234") },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "0o1234", .code_page = .windows1252 }),
    );
    // overflow wraps
    try expectNameOrOrdinal(
        NameOrOrdinal{ .ordinal = @truncate(u16, 65635) },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "65635", .code_page = .windows1252 }),
    );
    // non-hex-digits in a hex literal are treated as a terminator
    try expectNameOrOrdinal(
        NameOrOrdinal{ .ordinal = 0x4 },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "0x4n", .code_page = .windows1252 }),
    );
    try expectNameOrOrdinal(
        NameOrOrdinal{ .ordinal = 0xFA },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "0xFAZ92348", .code_page = .windows1252 }),
    );
    // 0 at the start is allowed
    try expectNameOrOrdinal(
        NameOrOrdinal{ .ordinal = 50 },
        try NameOrOrdinal.fromString(allocator, .{ .slice = "050", .code_page = .windows1252 }),
    );
    // limit of 256 UTF-16 code units, can cut off between a surrogate pair
    {
        var expected = blk: {
            // the input before the 𐐷 character, but uppercased
            var expected_u8_bytes = "00614982008907933748980730280674788429543776231864944218790698304852300002973622122844631429099469274282385299397783838528QFFL7SHNSIETG0QKLR1UYPBTUV1PMFQRRA0VJDG354GQEDJMUPGPP1W1EXVNTZVEIZ6K3IPQM1AWGEYALMEODYVEZGOD3MFMGEY8FNR4JUETTB1PZDEWSNDRGZUA8SNXP3NGO";
            var buf: [256:0]u16 = undefined;
            for (expected_u8_bytes) |byte, i| {
                buf[i] = byte;
            }
            // surrogate pair that is now orphaned
            buf[255] = 0xD801;
            break :blk buf;
        };
        try expectNameOrOrdinal(
            NameOrOrdinal{ .name = &expected },
            try NameOrOrdinal.fromString(allocator, .{
                .slice = "00614982008907933748980730280674788429543776231864944218790698304852300002973622122844631429099469274282385299397783838528qffL7ShnSIETg0qkLr1UYpbtuv1PMFQRRa0VjDG354GQedJmUPgpp1w1ExVnTzVEiz6K3iPqM1AWGeYALmeODyvEZGOD3MfmGey8fnR4jUeTtB1PzdeWsNDrGzuA8Snxp3NGO𐐷",
                .code_page = .utf8,
            }),
        );
    }
}

test "NameOrOrdinal code page awareness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    try expectNameOrOrdinal(
        NameOrOrdinal{ .name = std.unicode.utf8ToUtf16LeStringLiteral("��𐐷") },
        try NameOrOrdinal.fromString(allocator, .{
            .slice = "\xF0\x80\x80𐐷",
            .code_page = .utf8,
        }),
    );
    try expectNameOrOrdinal(
        // The UTF-8 representation of 𐐷 is 0xF0 0x90 0x90 0xB7. In order to provide valid
        // UTF-8 to utf8ToUtf16LeStringLiteral, it uses the UTF-8 representation of the codepoint
        // <U+0x90> which is 0xC2 0x90. The code units in the expected UTF-16 string are:
        // { 0x00F0, 0x20AC, 0x20AC, 0x00F0, 0x0090, 0x0090, 0x00B7 }
        NameOrOrdinal{ .name = std.unicode.utf8ToUtf16LeStringLiteral("ð€€ð\xC2\x90\xC2\x90·") },
        try NameOrOrdinal.fromString(allocator, .{
            .slice = "\xF0\x80\x80𐐷",
            .code_page = .windows1252,
        }),
    );
}

/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-accel#members
/// https://devblogs.microsoft.com/oldnewthing/20070316-00/?p=27593
pub const AcceleratorModifiers = packed struct(u8) {
    value: u8 = 0,

    pub const ASCII = 0;
    pub const VIRTKEY = 1;
    pub const NOINVERT = 1 << 1;
    pub const SHIFT = 1 << 2;
    pub const CONTROL = 1 << 3;
    pub const ALT = 1 << 4;
    /// Marker for the last accelerator in an accelerator table
    pub const last_accelerator_in_table = 1 << 7;

    pub fn apply(self: *AcceleratorModifiers, modifier: rc.AcceleratorTypeAndOptions) void {
        self.value |= modifierValue(modifier);
    }

    pub fn isSet(self: AcceleratorModifiers, modifier: rc.AcceleratorTypeAndOptions) bool {
        // ASCII is set whenever VIRTKEY is not
        if (modifier == .ascii) return self.value & modifierValue(.virtkey) == 0;
        return self.value & modifierValue(modifier) != 0;
    }

    fn modifierValue(modifier: rc.AcceleratorTypeAndOptions) u8 {
        return switch (modifier) {
            .ascii => ASCII,
            .virtkey => VIRTKEY,
            .noinvert => NOINVERT,
            .shift => SHIFT,
            .control => CONTROL,
            .alt => ALT,
        };
    }

    pub fn markLast(self: *AcceleratorModifiers) void {
        self.value |= last_accelerator_in_table;
    }
};

const AcceleratorKeyCodepointTranslator = struct {
    string_type: literals.IterativeStringParser.StringType,

    pub fn translate(self: @This(), maybe_parsed: ?literals.IterativeStringParser.ParsedCodepoint) ?u21 {
        const parsed = maybe_parsed orelse return null;
        if (parsed.codepoint == Codepoint.invalid) return 0xFFFD;
        if (parsed.from_escaped_integer and self.string_type == .ascii) {
            return windows1252.toCodepoint(@intCast(u8, parsed.codepoint));
        }
        return parsed.codepoint;
    }
};

/// Expects bytes to be the full bytes of a string literal token (e.g. including the "" or L"").
pub fn parseAcceleratorKeyString(bytes: SourceBytes, is_virt: bool, options: literals.StringParseOptions) !u16 {
    if (bytes.slice.len == 0) {
        return error.InvalidAccelerator;
    }

    var parser = literals.IterativeStringParser.init(bytes, options);
    var translator = AcceleratorKeyCodepointTranslator{ .string_type = parser.string_type };

    const first_codepoint = translator.translate(try parser.next()) orelse return error.InvalidAccelerator;
    // 0 is treated as a terminator, so this is equivalent to an empty string
    if (first_codepoint == 0) return error.InvalidAccelerator;

    if (first_codepoint == '^') {
        const c = translator.translate(try parser.next()) orelse return error.InvalidControlCharacter;
        switch (c) {
            '^' => return '^', // special case
            'a'...'z', 'A'...'Z' => return std.ascii.toUpper(@intCast(u8, c)) - 0x40,
            // Note: The Windows RC compiler allows more than just A-Z, but what it allows
            //       seems to be tied to some sort of Unicode-aware 'is character' function or something.
            //       The full list of codepoints that trigger an out-of-range error can be found here:
            //       https://gist.github.com/squeek502/2e9d0a4728a83eed074ad9785a209fd0
            //       For codepoints >= 0x80 that don't trigger the error, the Windows RC compiler takes the
            //       codepoint and does the `- 0x40` transformation as if it were A-Z which couldn't lead
            //       to anything useable, so there's no point in emulating that behavior--erroring for
            //       all non-[a-zA-Z] makes much more sense and is what was probably intended by the
            //       Windows RC compiler.
            else => return error.ControlCharacterOutOfRange,
        }
        @compileError("this should be unreachable");
    }

    const second_codepoint = translator.translate(try parser.next());

    var result: u32 = initial_value: {
        if (first_codepoint >= 0x10000) {
            if (second_codepoint != null and second_codepoint.? != 0) return error.InvalidAccelerator;
            // No idea why it works this way, but this seems to match the Windows RC
            // behavior for codepoints >= 0x10000
            const low = @intCast(u16, first_codepoint & 0x3FF) + 0xDC00;
            const extra = (first_codepoint - 0x10000) / 0x400;
            break :initial_value low + extra * 0x100;
        }
        break :initial_value first_codepoint;
    };

    // 0 is treated as a terminator
    if (second_codepoint != null and second_codepoint.? == 0) return @truncate(u16, result);

    const third_codepoint = translator.translate(try parser.next());
    // 0 is treated as a terminator, so a 0 in the third position is fine but
    // anything else is too many codepoints for an accelerator
    if (third_codepoint != null and third_codepoint.? != 0) return error.InvalidAccelerator;

    if (second_codepoint) |c| {
        if (c >= 0x10000) return error.InvalidAccelerator;
        result <<= 8;
        result += c;
    } else if (is_virt) {
        switch (result) {
            'a'...'z' => result -= 0x20, // toUpper
            else => {},
        }
    }
    return @truncate(u16, result);
}

test "accelerator keys" {
    try std.testing.expectEqual(@as(u16, 1), try parseAcceleratorKeyString(
        .{ .slice = "\"^a\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    try std.testing.expectEqual(@as(u16, 1), try parseAcceleratorKeyString(
        .{ .slice = "\"^A\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    try std.testing.expectEqual(@as(u16, 26), try parseAcceleratorKeyString(
        .{ .slice = "\"^Z\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    try std.testing.expectEqual(@as(u16, '^'), try parseAcceleratorKeyString(
        .{ .slice = "\"^^\"", .code_page = .windows1252 },
        false,
        .{},
    ));

    try std.testing.expectEqual(@as(u16, 'a'), try parseAcceleratorKeyString(
        .{ .slice = "\"a\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    try std.testing.expectEqual(@as(u16, 0x6162), try parseAcceleratorKeyString(
        .{ .slice = "\"ab\"", .code_page = .windows1252 },
        false,
        .{},
    ));

    try std.testing.expectEqual(@as(u16, 'C'), try parseAcceleratorKeyString(
        .{ .slice = "\"c\"", .code_page = .windows1252 },
        true,
        .{},
    ));
    try std.testing.expectEqual(@as(u16, 0x6363), try parseAcceleratorKeyString(
        .{ .slice = "\"cc\"", .code_page = .windows1252 },
        true,
        .{},
    ));

    // \x00 or any escape that evaluates to zero acts as a terminator, everything past it
    // is ignored
    try std.testing.expectEqual(@as(u16, 'a'), try parseAcceleratorKeyString(
        .{ .slice = "\"a\\0bcdef\"", .code_page = .windows1252 },
        false,
        .{},
    ));

    // \x80 is € in Windows-1252, which is Unicode codepoint 20AC
    try std.testing.expectEqual(@as(u16, 0x20AC), try parseAcceleratorKeyString(
        .{ .slice = "\"\x80\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    // This depends on the code page, though, with codepage 65001, \x80
    // on its own is invalid UTF-8 so it gets converted to the replacement character
    try std.testing.expectEqual(@as(u16, 0xFFFD), try parseAcceleratorKeyString(
        .{ .slice = "\"\x80\"", .code_page = .utf8 },
        false,
        .{},
    ));
    try std.testing.expectEqual(@as(u16, 0xCCAC), try parseAcceleratorKeyString(
        .{ .slice = "\"\x80\x80\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    // This also behaves the same with escaped characters
    try std.testing.expectEqual(@as(u16, 0x20AC), try parseAcceleratorKeyString(
        .{ .slice = "\"\\x80\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    // Even with utf8 code page
    try std.testing.expectEqual(@as(u16, 0x20AC), try parseAcceleratorKeyString(
        .{ .slice = "\"\\x80\"", .code_page = .utf8 },
        false,
        .{},
    ));
    try std.testing.expectEqual(@as(u16, 0xCCAC), try parseAcceleratorKeyString(
        .{ .slice = "\"\\x80\\x80\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    // Wide string with the actual characters behaves like the ASCII string version
    try std.testing.expectEqual(@as(u16, 0xCCAC), try parseAcceleratorKeyString(
        .{ .slice = "L\"\x80\x80\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    // But wide string with escapes behaves differently
    try std.testing.expectEqual(@as(u16, 0x8080), try parseAcceleratorKeyString(
        .{ .slice = "L\"\\x80\\x80\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    // and invalid escapes within wide strings get skipped
    try std.testing.expectEqual(@as(u16, 'z'), try parseAcceleratorKeyString(
        .{ .slice = "L\"\\Hz\"", .code_page = .windows1252 },
        false,
        .{},
    ));

    // any non-A-Z codepoints are illegal
    try std.testing.expectError(error.ControlCharacterOutOfRange, parseAcceleratorKeyString(
        .{ .slice = "\"^\x83\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    try std.testing.expectError(error.ControlCharacterOutOfRange, parseAcceleratorKeyString(
        .{ .slice = "\"^1\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    try std.testing.expectError(error.InvalidControlCharacter, parseAcceleratorKeyString(
        .{ .slice = "\"^\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    try std.testing.expectError(error.InvalidAccelerator, parseAcceleratorKeyString(
        .{ .slice = "\"\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    try std.testing.expectError(error.InvalidAccelerator, parseAcceleratorKeyString(
        .{ .slice = "\"hello\"", .code_page = .windows1252 },
        false,
        .{},
    ));
    try std.testing.expectError(error.ControlCharacterOutOfRange, parseAcceleratorKeyString(
        .{ .slice = "\"^\x80\"", .code_page = .windows1252 },
        false,
        .{},
    ));

    // Invalid UTF-8 gets converted to 0xFFFD, multiple invalids get shifted and added together
    // The behavior is the same for ascii and wide strings
    try std.testing.expectEqual(@as(u16, 0xFCFD), try parseAcceleratorKeyString(
        .{ .slice = "\"\x80\x80\"", .code_page = .utf8 },
        false,
        .{},
    ));
    try std.testing.expectEqual(@as(u16, 0xFCFD), try parseAcceleratorKeyString(
        .{ .slice = "L\"\x80\x80\"", .code_page = .utf8 },
        false,
        .{},
    ));

    // Codepoints >= 0x10000
    try std.testing.expectEqual(@as(u16, 0xDD00), try parseAcceleratorKeyString(
        .{ .slice = "\"\xF0\x90\x84\x80\"", .code_page = .utf8 },
        false,
        .{},
    ));
    try std.testing.expectEqual(@as(u16, 0xDD00), try parseAcceleratorKeyString(
        .{ .slice = "L\"\xF0\x90\x84\x80\"", .code_page = .utf8 },
        false,
        .{},
    ));
    try std.testing.expectEqual(@as(u16, 0x9C01), try parseAcceleratorKeyString(
        .{ .slice = "\"\xF4\x80\x80\x81\"", .code_page = .utf8 },
        false,
        .{},
    ));
    // anything before or after a codepoint >= 0x10000 causes an error
    try std.testing.expectError(error.InvalidAccelerator, parseAcceleratorKeyString(
        .{ .slice = "\"a\xF0\x90\x80\x80\"", .code_page = .utf8 },
        false,
        .{},
    ));
    try std.testing.expectError(error.InvalidAccelerator, parseAcceleratorKeyString(
        .{ .slice = "\"\xF0\x90\x80\x80a\"", .code_page = .utf8 },
        false,
        .{},
    ));
}
