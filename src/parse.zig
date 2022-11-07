const std = @import("std");
const Lexer = @import("lex.zig").Lexer;
const Token = @import("lex.zig").Token;
const Node = @import("ast.zig").Node;
const Tree = @import("ast.zig").Tree;
const Resource = @import("rc.zig").Resource;
const isValidNumberDataLiteral = @import("literals.zig").isValidNumberDataLiteral;
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    SyntaxError,
    ExpectedDifferentToken,
};

pub const Parser = struct {
    const Self = @This();

    lexer: *Lexer,
    /// values that need to be initialized per-parse
    state: Parser.State = undefined,

    pub const Error = ParseError || Lexer.Error || Allocator.Error;

    pub fn init(lexer: *Lexer) Parser {
        return Parser{
            .lexer = lexer,
        };
    }

    pub const State = struct {
        token: Token,
        allocator: Allocator,
        arena: Allocator,
    };

    pub fn parse(self: *Self, allocator: Allocator) Error!*Tree {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        self.state = Parser.State{
            .token = try self.lexer.nextWhitespaceDelimeterOnly(),
            .allocator = allocator,
            .arena = arena.allocator(),
        };

        const parsed_root = try self.parseRoot();

        const tree = try self.state.arena.create(Tree);
        tree.* = .{
            .node = parsed_root,
            .source = self.lexer.buffer,
            .arena = arena.state,
            .allocator = allocator,
        };
        return tree;
    }

    fn parseRoot(self: *Self) Error!*Node {
        var statements = std.ArrayList(*Node).init(self.state.allocator);
        defer statements.deinit();

        try self.parseStatements(&statements);
        try self.check(.eof);

        const node = try self.state.arena.create(Node.Root);
        node.* = .{
            .body = try self.state.arena.dupe(*Node, statements.items),
        };
        return &node.base;
    }

    fn parseStatements(self: *Self, statements: *std.ArrayList(*Node)) Error!void {
        while (self.state.token.id != .eof) {
            var statement = try self.parseStatement();
            try statements.append(statement);
        }
    }

    fn parseStatement(self: *Self) Error!*Node {
        const first_token = self.state.token;
        if (first_token.id == .literal and std.mem.eql(u8, first_token.slice(self.lexer.buffer), "LANGUAGE")) {
            @panic("TODO top-level LANGUAGE statement");
        } else {
            try self.checkId();
            const id_token = first_token;
            try self.nextTokenWhitespaceDelimiterOnly();
            const resource = try self.checkResource();
            const type_token = self.state.token;
            try self.nextTokenNormal();

            switch (resource) {
                .icon, .font, .cursor, .bitmap, .messagetable, .user_defined, .rcdata => {
                    var common_resource_attributes = std.ArrayList(Token).init(self.state.allocator);
                    defer common_resource_attributes.deinit();

                    // TODO: Can user-defined resources have common resource attributes?
                    while (self.state.token.id == .literal and common_resource_attributes_set.has(self.state.token.slice(self.lexer.buffer))) {
                        try common_resource_attributes.append(self.state.token);
                        try self.nextTokenNormal();
                    }

                    if (try self.testBegin()) {
                        try self.nextTokenNormal();

                        var raw_data = std.ArrayList(Token).init(self.state.allocator);
                        defer raw_data.deinit();
                        while (true) {
                            switch (self.state.token.id) {
                                .literal => {
                                    if (std.mem.eql(u8, "END", self.tokenSlice())) {
                                        break;
                                    }
                                    try raw_data.append(self.state.token);
                                },
                                .comma => {},
                                .quoted_ascii_string, .quoted_wide_string => {
                                    try raw_data.append(self.state.token);
                                },
                                .close_brace => {
                                    try self.nextTokenWhitespaceDelimiterOnly();
                                    break;
                                },
                                .eof => break, // TODO: emit an error probably
                                else => {
                                    std.debug.print("unhandled token: {any}\n", .{self.state.token});
                                    @panic("TODO: Unhandled token type in raw data block");
                                },
                            }
                            try self.nextTokenNormal();
                        }

                        const node = try self.state.arena.create(Node.ResourceRawData);
                        node.* = .{
                            .id = id_token,
                            .type = type_token,
                            .common_resource_attributes = try self.state.arena.dupe(Token, common_resource_attributes.items),
                            .raw_data = try self.state.arena.dupe(Token, raw_data.items),
                        };
                        return &node.base;
                    }

                    var filename_expression = try self.parseExpression();
                    try self.nextTokenWhitespaceDelimiterOnly();

                    const node = try self.state.arena.create(Node.ResourceExternal);
                    node.* = .{
                        .id = id_token,
                        .type = type_token,
                        .common_resource_attributes = try self.state.arena.dupe(Token, common_resource_attributes.items),
                        .filename = filename_expression,
                    };
                    return &node.base;
                },
                else => @panic("TODO unhandled resource type"),
            }
        }
    }

    fn parseExpression(self: *Self) Error!*Node {
        switch (self.state.token.id) {
            .quoted_ascii_string, .quoted_wide_string => {
                const node = try self.state.arena.create(Node.Literal);
                node.* = .{
                    .token = self.state.token,
                };
                return &node.base;
            },
            .literal => {
                if (!isValidNumberDataLiteral(self.tokenSlice())) {
                    const node = try self.state.arena.create(Node.Literal);
                    node.* = .{
                        .token = self.state.token,
                    };
                    return &node.base;
                } else {}
            },
            else => {},
        }
        std.debug.print("Unhandled token: {any}\n", .{self.state.token});
        @panic("TODO parseExpression");
    }

    fn nextTokenWhitespaceDelimiterOnly(self: *Self) Lexer.Error!void {
        self.state.token = try self.lexer.nextWhitespaceDelimeterOnly();
    }

    fn nextTokenNormal(self: *Self) Lexer.Error!void {
        self.state.token = try self.lexer.nextNormal();
    }

    fn nextTokenNumberExpression(self: *Self) Lexer.Error!void {
        self.state.token = try self.lexer.nextNumberExpression();
    }

    fn tokenSlice(self: *Self) []const u8 {
        return self.state.token.slice(self.lexer.buffer);
    }

    /// Check that the current token is something that can be used as an ID
    fn checkId(self: *Self) !void {
        switch (self.state.token.id) {
            .literal => {},
            else => {
                std.debug.print("expected literal, got {}\n", .{self.state.token.id});
                return ParseError.ExpectedDifferentToken;
            },
        }
    }

    fn testBegin(self: *Self) !bool {
        switch (self.state.token.id) {
            .open_brace => {
                return true;
            },
            .literal => {
                if (std.mem.eql(u8, "BEGIN", self.state.token.slice(self.lexer.buffer))) {
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn check(self: *Self, expected_token_id: Token.Id) !void {
        if (self.state.token.id != expected_token_id) {
            return ParseError.ExpectedDifferentToken;
        }
    }

    fn checkResource(self: *Self) !Resource {
        std.debug.print("{any}\n", .{self.state.token});
        switch (self.state.token.id) {
            .literal => return Resource.fromString(self.state.token.slice(self.lexer.buffer)),
            else => {
                return ParseError.ExpectedDifferentToken;
            },
        }
    }
};

const common_resource_attributes_set = std.ComptimeStringMap(void, .{
    .{"PRELOAD"},
    .{"LOADONCALL"},
    .{"FIXED"},
    .{"MOVEABLE"},
    .{"DISCARDABLE"},
    .{"PURE"},
    .{"IMPURE"},
    .{"SHARED"},
    .{"NONSHARED"},
});

fn testParse(source: []const u8, expected_ast_dump: []const u8) !void {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(source);
    var parser = Parser.init(&lexer);
    var tree = try parser.parse(allocator);
    defer tree.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try tree.dump(buf.writer());
    try std.testing.expectEqualStrings(expected_ast_dump, buf.items);
}

fn expectParseError(expected: ParseError, source: []const u8) !void {
    try std.testing.expectError(expected, testParse(source, ""));
}

test "basic icons" {
    try testParse("id ICON MOVEABLE filename.ico",
        \\root
        \\ resource_external id ICON [1 common_resource_attributes]
        \\  literal filename.ico
        \\
    );
    try testParse(
        \\id1 ICON MOVEABLE filename.ico
        \\id2 ICON filename.ico
    ,
        \\root
        \\ resource_external id1 ICON [1 common_resource_attributes]
        \\  literal filename.ico
        \\ resource_external id2 ICON [0 common_resource_attributes]
        \\  literal filename.ico
        \\
    );
    try testParse(
        \\id1 ICON MOVEABLE filename.ico id2 ICON filename.ico
    ,
        \\root
        \\ resource_external id1 ICON [1 common_resource_attributes]
        \\  literal filename.ico
        \\ resource_external id2 ICON [0 common_resource_attributes]
        \\  literal filename.ico
        \\
    );
    try testParse(
        \\"id1" ICON "filename.ico"
        \\L"id2" ICON L"filename.ico"
    ,
        \\root
        \\ resource_external "id1" ICON [0 common_resource_attributes]
        \\  literal "filename.ico"
        \\ resource_external L"id2" ICON [0 common_resource_attributes]
        \\  literal L"filename.ico"
        \\
    );
}

test "user-defined" {
    try testParse("id \"quoted\" file.bin",
        \\root
        \\ resource_external id "quoted" [0 common_resource_attributes]
        \\  literal file.bin
        \\
    );
}

test "raw data" {
    try testParse("id RCDATA {}",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 0
        \\
    );
    try testParse("id RCDATA { 1,2,3 }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 3
        \\  1
        \\  2
        \\  3
        \\
    );
    try testParse("id RCDATA { L\"1\",\"2\",3 }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 3
        \\  L"1"
        \\  "2"
        \\  3
        \\
    );
    try testParse("id RCDATA { 1\t,,  ,,,2,,  ,  3 ,,,  , }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 3
        \\  1
        \\  2
        \\  3
        \\
    );
    try testParse("id RCDATA { 1 2 3 }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 3
        \\  1
        \\  2
        \\  3
        \\
    );
}
