const std = @import("std");
const Lexer = @import("lex.zig").Lexer;
const Token = @import("lex.zig").Token;
const Node = @import("ast.zig").Node;
const Tree = @import("ast.zig").Tree;
const CodePageLookup = @import("ast.zig").CodePageLookup;
const Resource = @import("rc.zig").Resource;
const Allocator = std.mem.Allocator;
const ErrorDetails = @import("errors.zig").ErrorDetails;
const Diagnostics = @import("errors.zig").Diagnostics;
const SourceBytes = @import("literals.zig").SourceBytes;
const Compiler = @import("compile.zig").Compiler;
const rc = @import("rc.zig");
const res = @import("res.zig");

// TODO: Make these configurable?
pub const max_nested_menu_level: u32 = 512;
pub const max_nested_version_level: u32 = 512;
pub const max_nested_expression_level: u32 = 200;

pub const Parser = struct {
    const Self = @This();

    lexer: *Lexer,
    /// values that need to be initialized per-parse
    state: Parser.State = undefined,
    options: Parser.Options,

    pub const Error = error{ParseError} || Allocator.Error;

    pub const Options = struct {
        warn_instead_of_error_on_invalid_code_page: bool = false,
    };

    pub fn init(lexer: *Lexer, options: Options) Parser {
        return Parser{
            .lexer = lexer,
            .options = options,
        };
    }

    pub const State = struct {
        token: Token,
        lookahead_lexer: Lexer,
        allocator: Allocator,
        arena: Allocator,
        diagnostics: *Diagnostics,
        input_code_page_lookup: CodePageLookup,
        output_code_page_lookup: CodePageLookup,
    };

    pub fn parse(self: *Self, allocator: Allocator, diagnostics: *Diagnostics) Error!*Tree {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        self.state = Parser.State{
            .token = undefined,
            .lookahead_lexer = undefined,
            .allocator = allocator,
            .arena = arena.allocator(),
            .diagnostics = diagnostics,
            .input_code_page_lookup = CodePageLookup.init(arena.allocator(), self.lexer.default_code_page),
            .output_code_page_lookup = CodePageLookup.init(arena.allocator(), self.lexer.default_code_page),
        };

        const parsed_root = try self.parseRoot();

        const tree = try self.state.arena.create(Tree);
        tree.* = .{
            .node = parsed_root,
            .input_code_pages = self.state.input_code_page_lookup,
            .output_code_pages = self.state.output_code_page_lookup,
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
        while (true) {
            try self.nextToken(.whitespace_delimiter_only);
            if (self.state.token.id == .eof) break;
            // The Win32 compiler will sometimes try to recover from errors
            // and then restart parsing afterwards. We don't ever do this
            // because it almost always leads to unhelpful error messages
            // (usually it will end up with bogus things like 'file
            // not found: {')
            var statement = try self.parseStatement();
            try statements.append(statement);
        }
    }

    /// Expects the current token to be the token before possible common resource attributes.
    /// After return, the current token will be the token immediately before the end of the
    /// common resource attributes (if any). If there are no common resource attributes, the
    /// current token is unchanged.
    /// The returned slice is allocated by the parser's arena
    fn parseCommonResourceAttributes(self: *Self) ![]Token {
        var common_resource_attributes = std.ArrayListUnmanaged(Token){};
        while (true) {
            const maybe_common_resource_attribute = try self.lookaheadToken(.normal);
            if (maybe_common_resource_attribute.id == .literal and rc.CommonResourceAttributes.map.has(maybe_common_resource_attribute.slice(self.lexer.buffer))) {
                try common_resource_attributes.append(self.state.arena, maybe_common_resource_attribute);
                self.nextToken(.normal) catch unreachable;
            } else {
                break;
            }
        }
        return common_resource_attributes.toOwnedSlice(self.state.arena);
    }

    /// Expects the current token to have already been dealt with, and that the
    /// optional statements will potentially start on the next token.
    /// After return, the current token will be the token immediately before the end of the
    /// optional statements (if any). If there are no optional statements, the
    /// current token is unchanged.
    /// The returned slice is allocated by the parser's arena
    fn parseOptionalStatements(self: *Self, resource: Resource) ![]*Node {
        var optional_statements = std.ArrayListUnmanaged(*Node){};
        while (true) {
            const lookahead_token = try self.lookaheadToken(.normal);
            if (lookahead_token.id != .literal) break;
            const slice = lookahead_token.slice(self.lexer.buffer);
            const optional_statement_type = rc.OptionalStatements.map.get(slice) orelse switch (resource) {
                .dialog, .dialogex => rc.OptionalStatements.dialog_map.get(slice) orelse break,
                else => break,
            };
            self.nextToken(.normal) catch unreachable;
            switch (optional_statement_type) {
                .language => {
                    const language = try self.parseLanguageStatement();
                    try optional_statements.append(self.state.arena, language);
                },
                // Number only
                .version, .characteristics, .style, .exstyle => {
                    const identifier = self.state.token;
                    const value = try self.parseExpression(.{
                        .can_contain_not_expressions = optional_statement_type == .style or optional_statement_type == .exstyle,
                        .allowed_types = .{ .number = true },
                    });
                    const node = try self.state.arena.create(Node.SimpleStatement);
                    node.* = .{
                        .identifier = identifier,
                        .value = value,
                    };
                    try optional_statements.append(self.state.arena, &node.base);
                },
                // String only
                .caption => {
                    const identifier = self.state.token;
                    try self.nextToken(.normal);
                    const value = self.state.token;
                    if (!value.isStringLiteral()) {
                        return self.addErrorDetailsAndFail(ErrorDetails{
                            .err = .expected_something_else,
                            .token = value,
                            .extra = .{ .expected_types = .{
                                .string_literal = true,
                            } },
                        });
                    }
                    // TODO: Wrapping this in a Node.Literal is superfluous but necessary
                    //       to put it in a SimpleStatement
                    const value_node = try self.state.arena.create(Node.Literal);
                    value_node.* = .{
                        .token = value,
                    };
                    const node = try self.state.arena.create(Node.SimpleStatement);
                    node.* = .{
                        .identifier = identifier,
                        .value = &value_node.base,
                    };
                    try optional_statements.append(self.state.arena, &node.base);
                },
                // String or number
                .class => {
                    const identifier = self.state.token;
                    const value = try self.parseExpression(.{ .allowed_types = .{ .number = true, .string = true } });
                    const node = try self.state.arena.create(Node.SimpleStatement);
                    node.* = .{
                        .identifier = identifier,
                        .value = value,
                    };
                    try optional_statements.append(self.state.arena, &node.base);
                },
                // Special case
                .menu => {
                    const identifier = self.state.token;
                    try self.nextToken(.whitespace_delimiter_only);
                    try self.check(.literal);
                    // TODO: Wrapping this in a Node.Literal is superfluous but necessary
                    //       to put it in a SimpleStatement
                    const value_node = try self.state.arena.create(Node.Literal);
                    value_node.* = .{
                        .token = self.state.token,
                    };
                    const node = try self.state.arena.create(Node.SimpleStatement);
                    node.* = .{
                        .identifier = identifier,
                        .value = &value_node.base,
                    };
                    try optional_statements.append(self.state.arena, &node.base);
                },
                .font => {
                    const identifier = self.state.token;
                    const point_size = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

                    // The comma between point_size and typeface is both optional and
                    // there can be any number of them
                    try self.skipAnyCommas();

                    try self.nextToken(.normal);
                    const typeface = self.state.token;
                    if (!typeface.isStringLiteral()) {
                        return self.addErrorDetailsAndFail(ErrorDetails{
                            .err = .expected_something_else,
                            .token = typeface,
                            .extra = .{ .expected_types = .{
                                .string_literal = true,
                            } },
                        });
                    }

                    const ExSpecificValues = struct {
                        weight: ?*Node = null,
                        italic: ?*Node = null,
                        char_set: ?*Node = null,
                    };
                    var ex_specific = ExSpecificValues{};
                    ex_specific: {
                        var optional_param_parser = OptionalParamParser{ .parser = self };
                        switch (resource) {
                            .dialogex => {
                                {
                                    ex_specific.weight = try optional_param_parser.parse(.{});
                                    if (optional_param_parser.finished) break :ex_specific;
                                }
                                {
                                    if (!(try self.parseOptionalToken(.comma))) break :ex_specific;
                                    ex_specific.italic = try self.parseExpression(.{ .allowed_types = .{ .number = true } });
                                }
                                {
                                    ex_specific.char_set = try optional_param_parser.parse(.{});
                                    if (optional_param_parser.finished) break :ex_specific;
                                }
                            },
                            .dialog => {},
                            else => unreachable, // only DIALOG and DIALOGEX have FONT optional-statements
                        }
                    }

                    const node = try self.state.arena.create(Node.FontStatement);
                    node.* = .{
                        .identifier = identifier,
                        .point_size = point_size,
                        .typeface = typeface,
                        .weight = ex_specific.weight,
                        .italic = ex_specific.italic,
                        .char_set = ex_specific.char_set,
                    };
                    try optional_statements.append(self.state.arena, &node.base);
                },
            }
        }
        return optional_statements.toOwnedSlice(self.state.arena);
    }

    /// Expects the current token to be the first token of the statement.
    fn parseStatement(self: *Self) Error!*Node {
        const first_token = self.state.token;
        std.debug.assert(first_token.id == .literal);

        if (rc.TopLevelKeywords.map.get(first_token.slice(self.lexer.buffer))) |keyword| switch (keyword) {
            .language => {
                const language_statement = try self.parseLanguageStatement();
                return language_statement;
            },
            .version, .characteristics => {
                const identifier = self.state.token;
                const value = try self.parseExpression(.{ .allowed_types = .{ .number = true } });
                const node = try self.state.arena.create(Node.SimpleStatement);
                node.* = .{
                    .identifier = identifier,
                    .value = value,
                };
                return &node.base;
            },
            .stringtable => {
                // common resource attributes must all be contiguous and come before optional-statements
                const common_resource_attributes = try self.parseCommonResourceAttributes();
                const optional_statements = try self.parseOptionalStatements(.stringtable);

                try self.nextToken(.normal);
                const begin_token = self.state.token;
                try self.check(.begin);

                var strings = std.ArrayList(*Node).init(self.state.allocator);
                defer strings.deinit();
                while (true) {
                    const maybe_end_token = try self.lookaheadToken(.normal);
                    switch (maybe_end_token.id) {
                        .end => {
                            self.nextToken(.normal) catch unreachable;
                            break;
                        },
                        .eof => {
                            return self.addErrorDetailsAndFail(ErrorDetails{
                                .err = .unfinished_string_table_block,
                                .token = maybe_end_token,
                            });
                        },
                        else => {},
                    }
                    const id_expression = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

                    const comma_token: ?Token = if (try self.parseOptionalToken(.comma)) self.state.token else null;

                    try self.nextToken(.normal);
                    if (self.state.token.id != .quoted_ascii_string and self.state.token.id != .quoted_wide_string) {
                        return self.addErrorDetailsAndFail(ErrorDetails{
                            .err = .expected_something_else,
                            .token = self.state.token,
                            .extra = .{ .expected_types = .{ .string_literal = true } },
                        });
                    }

                    const string_node = try self.state.arena.create(Node.StringTableString);
                    string_node.* = .{
                        .id = id_expression,
                        .maybe_comma = comma_token,
                        .string = self.state.token,
                    };
                    try strings.append(&string_node.base);
                }

                if (strings.items.len == 0) {
                    return self.addErrorDetailsAndFail(ErrorDetails{
                        .err = .expected_token, // TODO: probably a more specific error message
                        .token = self.state.token,
                        .extra = .{ .expected = .number },
                    });
                }

                const end_token = self.state.token;
                try self.check(.end);

                const node = try self.state.arena.create(Node.StringTable);
                node.* = .{
                    .type = first_token,
                    .common_resource_attributes = common_resource_attributes,
                    .optional_statements = optional_statements,
                    .begin_token = begin_token,
                    .strings = try self.state.arena.dupe(*Node, strings.items),
                    .end_token = end_token,
                };
                return &node.base;
            },
        };

        // The Win32 RC compiler allows for a 'dangling' literal at the end of a file
        // (as long as it's not a valid top-level keyword), and there is actually an
        // .rc file with a such a dangling literal in the Windows-classic-samples set
        // of projects. So, we have special compatibility for this particular case.
        const maybe_eof = try self.lookaheadToken(.whitespace_delimiter_only);
        if (maybe_eof.id == .eof) {
            // TODO: emit warning
            var context = try self.state.arena.alloc(Token, 2);
            context[0] = first_token;
            context[1] = maybe_eof;
            const invalid_node = try self.state.arena.create(Node.Invalid);
            invalid_node.* = .{
                .context = context,
            };
            return &invalid_node.base;
        }

        const id_token = first_token;
        const id_code_page = self.lexer.current_code_page;
        try self.nextToken(.whitespace_delimiter_only);
        const resource = try self.checkResource();
        const type_token = self.state.token;

        if (resource == .string_num) {
            try self.addErrorDetails(.{
                .err = .string_resource_as_numeric_type,
                .token = type_token,
            });
            return self.addErrorDetailsAndFail(.{
                .err = .string_resource_as_numeric_type,
                .token = type_token,
                .type = .note,
                .print_source_line = false,
            });
        }

        if (resource == .font) {
            const id_bytes = SourceBytes{
                .slice = id_token.slice(self.lexer.buffer),
                .code_page = id_code_page,
            };
            const maybe_ordinal = res.NameOrOrdinal.maybeOrdinalFromString(id_bytes);
            if (maybe_ordinal == null) {
                const would_be_win32_rc_ordinal = res.NameOrOrdinal.maybeNonAsciiOrdinalFromString(id_bytes);
                if (would_be_win32_rc_ordinal) |win32_rc_ordinal| {
                    try self.addErrorDetails(ErrorDetails{
                        .err = .id_must_be_ordinal,
                        .token = id_token,
                        .extra = .{ .resource = resource },
                    });
                    return self.addErrorDetailsAndFail(ErrorDetails{
                        .err = .win32_non_ascii_ordinal,
                        .token = id_token,
                        .type = .note,
                        .print_source_line = false,
                        .extra = .{ .number = win32_rc_ordinal.ordinal },
                    });
                } else {
                    return self.addErrorDetailsAndFail(ErrorDetails{
                        .err = .id_must_be_ordinal,
                        .token = id_token,
                        .extra = .{ .resource = resource },
                    });
                }
            }
        }

        switch (resource) {
            .accelerators => {
                // common resource attributes must all be contiguous and come before optional-statements
                const common_resource_attributes = try self.parseCommonResourceAttributes();
                const optional_statements = try self.parseOptionalStatements(resource);

                try self.nextToken(.normal);
                const begin_token = self.state.token;
                try self.check(.begin);

                var accelerators = std.ArrayListUnmanaged(*Node){};

                while (true) {
                    const lookahead = try self.lookaheadToken(.normal);
                    switch (lookahead.id) {
                        .end, .eof => {
                            self.nextToken(.normal) catch unreachable;
                            break;
                        },
                        else => {},
                    }
                    const event = try self.parseExpression(.{ .allowed_types = .{ .number = true, .string = true } });

                    try self.nextToken(.normal);
                    try self.check(.comma);

                    const idvalue = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

                    var type_and_options = std.ArrayListUnmanaged(Token){};
                    while (true) {
                        if (!(try self.parseOptionalToken(.comma))) break;

                        try self.nextToken(.normal);
                        if (!rc.AcceleratorTypeAndOptions.map.has(self.tokenSlice())) {
                            return self.addErrorDetailsAndFail(.{
                                .err = .expected_something_else,
                                .token = self.state.token,
                                .extra = .{ .expected_types = .{
                                    .accelerator_type_or_option = true,
                                } },
                            });
                        }
                        try type_and_options.append(self.state.arena, self.state.token);
                    }

                    const node = try self.state.arena.create(Node.Accelerator);
                    node.* = .{
                        .event = event,
                        .idvalue = idvalue,
                        .type_and_options = try type_and_options.toOwnedSlice(self.state.arena),
                    };
                    try accelerators.append(self.state.arena, &node.base);
                }

                const end_token = self.state.token;
                try self.check(.end);

                const node = try self.state.arena.create(Node.Accelerators);
                node.* = .{
                    .id = id_token,
                    .type = type_token,
                    .common_resource_attributes = common_resource_attributes,
                    .optional_statements = optional_statements,
                    .begin_token = begin_token,
                    .accelerators = try accelerators.toOwnedSlice(self.state.arena),
                    .end_token = end_token,
                };
                return &node.base;
            },
            .dialog, .dialogex => {
                // common resource attributes must all be contiguous and come before optional-statements
                const common_resource_attributes = try self.parseCommonResourceAttributes();

                const x = try self.parseExpression(.{ .allowed_types = .{ .number = true } });
                _ = try self.parseOptionalToken(.comma);

                const y = try self.parseExpression(.{ .allowed_types = .{ .number = true } });
                _ = try self.parseOptionalToken(.comma);

                const width = try self.parseExpression(.{ .allowed_types = .{ .number = true } });
                _ = try self.parseOptionalToken(.comma);

                const height = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

                var optional_param_parser = OptionalParamParser{ .parser = self };
                const help_id: ?*Node = try optional_param_parser.parse(.{});

                const optional_statements = try self.parseOptionalStatements(resource);

                try self.nextToken(.normal);
                const begin_token = self.state.token;
                try self.check(.begin);

                var controls = std.ArrayListUnmanaged(*Node){};
                defer controls.deinit(self.state.allocator);
                while (try self.parseControlStatement(resource)) |control_node| {
                    // The number of controls must fit in a u16 in order for it to
                    // be able to be written into the relevant field in the .res data.
                    if (controls.items.len >= std.math.maxInt(u16)) {
                        try self.addErrorDetails(.{
                            .err = .too_many_dialog_controls,
                            .token = id_token,
                            .extra = .{ .resource = resource },
                        });
                        return self.addErrorDetailsAndFail(.{
                            .err = .too_many_dialog_controls,
                            .type = .note,
                            .token = control_node.getFirstToken(),
                            .token_span_end = control_node.getLastToken(),
                            .extra = .{ .resource = resource },
                        });
                    }

                    try controls.append(self.state.allocator, control_node);
                }

                try self.nextToken(.normal);
                const end_token = self.state.token;
                try self.check(.end);

                const node = try self.state.arena.create(Node.Dialog);
                node.* = .{
                    .id = id_token,
                    .type = type_token,
                    .common_resource_attributes = common_resource_attributes,
                    .x = x,
                    .y = y,
                    .width = width,
                    .height = height,
                    .help_id = help_id,
                    .optional_statements = optional_statements,
                    .begin_token = begin_token,
                    .controls = try self.state.arena.dupe(*Node, controls.items),
                    .end_token = end_token,
                };
                return &node.base;
            },
            .toolbar => {
                // common resource attributes must all be contiguous and come before optional-statements
                const common_resource_attributes = try self.parseCommonResourceAttributes();

                const button_width = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

                try self.nextToken(.normal);
                try self.check(.comma);

                const button_height = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

                try self.nextToken(.normal);
                const begin_token = self.state.token;
                try self.check(.begin);

                var buttons = std.ArrayListUnmanaged(*Node){};
                while (try self.parseToolbarButtonStatement()) |button_node| {
                    try buttons.append(self.state.arena, button_node);
                }

                try self.nextToken(.normal);
                const end_token = self.state.token;
                try self.check(.end);

                const node = try self.state.arena.create(Node.Toolbar);
                node.* = .{
                    .id = id_token,
                    .type = type_token,
                    .common_resource_attributes = common_resource_attributes,
                    .button_width = button_width,
                    .button_height = button_height,
                    .begin_token = begin_token,
                    .buttons = try buttons.toOwnedSlice(self.state.arena),
                    .end_token = end_token,
                };
                return &node.base;
            },
            .menu, .menuex => {
                // common resource attributes must all be contiguous and come before optional-statements
                const common_resource_attributes = try self.parseCommonResourceAttributes();
                // help id is optional but must come between common resource attributes and optional-statements
                var help_id: ?*Node = null;
                // Note: No comma is allowed before or after help_id of MENUEX and help_id is not
                //       a possible field of MENU.
                if (resource == .menuex and try self.lookaheadCouldBeNumberExpression(.not_disallowed)) {
                    help_id = try self.parseExpression(.{
                        .is_known_to_be_number_expression = true,
                    });
                }
                const optional_statements = try self.parseOptionalStatements(.stringtable);

                try self.nextToken(.normal);
                const begin_token = self.state.token;
                try self.check(.begin);

                var items = std.ArrayListUnmanaged(*Node){};
                defer items.deinit(self.state.allocator);
                while (try self.parseMenuItemStatement(resource, id_token, 1)) |item_node| {
                    try items.append(self.state.allocator, item_node);
                }

                try self.nextToken(.normal);
                const end_token = self.state.token;
                try self.check(.end);

                if (items.items.len == 0) {
                    return self.addErrorDetailsAndFail(.{
                        .err = .empty_menu_not_allowed,
                        .token = type_token,
                    });
                }

                const node = try self.state.arena.create(Node.Menu);
                node.* = .{
                    .id = id_token,
                    .type = type_token,
                    .common_resource_attributes = common_resource_attributes,
                    .optional_statements = optional_statements,
                    .help_id = help_id,
                    .begin_token = begin_token,
                    .items = try self.state.arena.dupe(*Node, items.items),
                    .end_token = end_token,
                };
                return &node.base;
            },
            .versioninfo => {
                // common resource attributes must all be contiguous and come before optional-statements
                const common_resource_attributes = try self.parseCommonResourceAttributes();

                var fixed_info = std.ArrayListUnmanaged(*Node){};
                while (try self.parseVersionStatement()) |version_statement| {
                    try fixed_info.append(self.state.arena, version_statement);
                }

                try self.nextToken(.normal);
                const begin_token = self.state.token;
                try self.check(.begin);

                var block_statements = std.ArrayListUnmanaged(*Node){};
                while (try self.parseVersionBlockOrValue(id_token, 1)) |block_node| {
                    try block_statements.append(self.state.arena, block_node);
                }

                try self.nextToken(.normal);
                const end_token = self.state.token;
                try self.check(.end);

                const node = try self.state.arena.create(Node.VersionInfo);
                node.* = .{
                    .id = id_token,
                    .versioninfo = type_token,
                    .common_resource_attributes = common_resource_attributes,
                    .fixed_info = try fixed_info.toOwnedSlice(self.state.arena),
                    .begin_token = begin_token,
                    .block_statements = try block_statements.toOwnedSlice(self.state.arena),
                    .end_token = end_token,
                };
                return &node.base;
            },
            .dlginclude => {
                const common_resource_attributes = try self.parseCommonResourceAttributes();

                var filename_expression = try self.parseExpression(.{
                    .allowed_types = .{ .string = true },
                });

                const node = try self.state.arena.create(Node.ResourceExternal);
                node.* = .{
                    .id = id_token,
                    .type = type_token,
                    .common_resource_attributes = common_resource_attributes,
                    .filename = filename_expression,
                };
                return &node.base;
            },
            .stringtable => {
                return self.addErrorDetailsAndFail(.{
                    .err = .name_or_id_not_allowed,
                    .token = id_token,
                    .extra = .{ .resource = resource },
                });
            },
            // Just try everything as a 'generic' resource (raw data or external file)
            // TODO: More fine-grained switch cases as necessary
            else => {
                const common_resource_attributes = try self.parseCommonResourceAttributes();

                const maybe_begin = try self.lookaheadToken(.normal);
                if (maybe_begin.id == .begin) {
                    self.nextToken(.normal) catch unreachable;

                    if (!resource.canUseRawData()) {
                        try self.addErrorDetails(ErrorDetails{
                            .err = .resource_type_cant_use_raw_data,
                            .token = maybe_begin,
                            .extra = .{ .resource = resource },
                        });
                        return self.addErrorDetailsAndFail(ErrorDetails{
                            .err = .resource_type_cant_use_raw_data,
                            .type = .note,
                            .print_source_line = false,
                            .token = maybe_begin,
                        });
                    }

                    const raw_data = try self.parseRawDataBlock();
                    const end_token = self.state.token;

                    const node = try self.state.arena.create(Node.ResourceRawData);
                    node.* = .{
                        .id = id_token,
                        .type = type_token,
                        .common_resource_attributes = common_resource_attributes,
                        .begin_token = maybe_begin,
                        .raw_data = raw_data,
                        .end_token = end_token,
                    };
                    return &node.base;
                }

                var filename_expression = try self.parseExpression(.{
                    // Don't tell the user that numbers are accepted since we error on
                    // number expressions and regular number literals are treated as unquoted
                    // literals rather than numbers, so from the users perspective
                    // numbers aren't really allowed.
                    .expected_types_override = .{
                        .literal = true,
                        .string_literal = true,
                    },
                });

                const node = try self.state.arena.create(Node.ResourceExternal);
                node.* = .{
                    .id = id_token,
                    .type = type_token,
                    .common_resource_attributes = common_resource_attributes,
                    .filename = filename_expression,
                };
                return &node.base;
            },
        }
    }

    /// Expects the current token to be a begin token.
    /// After return, the current token will be the end token.
    fn parseRawDataBlock(self: *Self) Error![]*Node {
        var raw_data = std.ArrayList(*Node).init(self.state.allocator);
        defer raw_data.deinit();
        while (true) {
            const maybe_end_token = try self.lookaheadToken(.normal);
            switch (maybe_end_token.id) {
                .comma => {
                    // comma as the first token in a raw data block is an error
                    if (raw_data.items.len == 0) {
                        return self.addErrorDetailsAndFail(ErrorDetails{
                            .err = .expected_something_else,
                            .token = maybe_end_token,
                            .extra = .{ .expected_types = .{
                                .number = true,
                                .number_expression = true,
                                .string_literal = true,
                            } },
                        });
                    }
                    // otherwise just skip over commas
                    self.nextToken(.normal) catch unreachable;
                    continue;
                },
                .end => {
                    self.nextToken(.normal) catch unreachable;
                    break;
                },
                .eof => {
                    return self.addErrorDetailsAndFail(ErrorDetails{
                        .err = .unfinished_raw_data_block,
                        .token = maybe_end_token,
                    });
                },
                else => {},
            }
            const expression = try self.parseExpression(.{ .allowed_types = .{ .number = true, .string = true } });
            try raw_data.append(expression);

            if (expression.isNumberExpression()) {
                const maybe_close_paren = try self.lookaheadToken(.normal);
                if (maybe_close_paren.id == .close_paren) {
                    // <number expression>) is an error
                    return self.addErrorDetailsAndFail(ErrorDetails{
                        .err = .expected_token,
                        .token = maybe_close_paren,
                        .extra = .{ .expected = .operator },
                    });
                }
            }
        }
        return try self.state.arena.dupe(*Node, raw_data.items);
    }

    /// Expects the current token to be handled, and that the control statement will
    /// begin on the next token.
    /// After return, the current token will be the token immediately before the end of the
    /// control statement (or unchanged if the function returns null).
    fn parseControlStatement(self: *Self, resource: Resource) Error!?*Node {
        const control_token = try self.lookaheadToken(.normal);
        const control = rc.Control.map.get(control_token.slice(self.lexer.buffer)) orelse return null;
        self.nextToken(.normal) catch unreachable;

        try self.skipAnyCommas();

        var text: ?Token = null;
        if (control.hasTextParam()) {
            try self.nextToken(.normal);
            switch (self.state.token.id) {
                .quoted_ascii_string, .quoted_wide_string, .number => {
                    text = self.state.token;
                },
                else => {
                    return self.addErrorDetailsAndFail(ErrorDetails{
                        .err = .expected_something_else,
                        .token = self.state.token,
                        .extra = .{ .expected_types = .{
                            .number = true,
                            .string_literal = true,
                        } },
                    });
                },
            }
            try self.skipAnyCommas();
        }

        const id = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

        try self.skipAnyCommas();

        var class: ?*Node = null;
        var style: ?*Node = null;
        if (control == .control) {
            class = try self.parseExpression(.{});
            if (class.?.id == .literal) {
                const class_literal = @fieldParentPtr(Node.Literal, "base", class.?);
                const is_invalid_control_class = class_literal.token.id == .literal and !rc.ControlClass.map.has(class_literal.token.slice(self.lexer.buffer));
                if (is_invalid_control_class) {
                    return self.addErrorDetailsAndFail(.{
                        .err = .expected_something_else,
                        .token = self.state.token,
                        .extra = .{ .expected_types = .{
                            .control_class = true,
                        } },
                    });
                }
            }
            try self.skipAnyCommas();
            style = try self.parseExpression(.{
                .can_contain_not_expressions = true,
                .allowed_types = .{ .number = true },
            });
            // If there is no comma after the style paramter, the Win32 RC compiler
            // could misinterpret the statement and end up skipping over at least one token
            // that should have been interepeted as the next parameter (x). For example:
            //   CONTROL "text", 1, BUTTON, 15 30, 1, 2, 3, 4
            // the `15` is the style parameter, but in the Win32 implementation the `30`
            // is completely ignored (i.e. the `1, 2, 3, 4` are `x`, `y`, `w`, `h`).
            // If a comma is added after the `15`, then `30` gets interpreted (correctly)
            // as the `x` value.
            //
            // Instead of emulating this behavior, we just warn about the potential for
            // weird behavior in the Win32 implementation whenever there isn't a comma after
            // the style parameter.
            const lookahead_token = try self.lookaheadToken(.normal);
            if (lookahead_token.id != .comma and lookahead_token.id != .eof) {
                try self.addErrorDetails(.{
                    .err = .rc_could_miscompile_control_params,
                    .type = .warning,
                    .token = lookahead_token,
                });
                try self.addErrorDetails(.{
                    .err = .rc_could_miscompile_control_params,
                    .type = .note,
                    .token = style.?.getFirstToken(),
                    .token_span_end = style.?.getLastToken(),
                });
            }
            try self.skipAnyCommas();
        }

        const x = try self.parseExpression(.{ .allowed_types = .{ .number = true } });
        _ = try self.parseOptionalToken(.comma);
        const y = try self.parseExpression(.{ .allowed_types = .{ .number = true } });
        _ = try self.parseOptionalToken(.comma);
        const width = try self.parseExpression(.{ .allowed_types = .{ .number = true } });
        _ = try self.parseOptionalToken(.comma);
        const height = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

        var optional_param_parser = OptionalParamParser{ .parser = self };
        if (control != .control) {
            style = try optional_param_parser.parse(.{ .not_expression_allowed = true });
        }

        var exstyle: ?*Node = try optional_param_parser.parse(.{ .not_expression_allowed = true });
        var help_id: ?*Node = switch (resource) {
            .dialogex => try optional_param_parser.parse(.{}),
            else => null,
        };

        var extra_data: []*Node = &[_]*Node{};
        var extra_data_begin: ?Token = null;
        var extra_data_end: ?Token = null;
        // extra data is DIALOGEX-only
        if (resource == .dialogex and try self.parseOptionalToken(.begin)) {
            extra_data_begin = self.state.token;
            extra_data = try self.parseRawDataBlock();
            extra_data_end = self.state.token;
        }

        const node = try self.state.arena.create(Node.ControlStatement);
        node.* = .{
            .type = control_token,
            .text = text,
            .class = class,
            .id = id,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .style = style,
            .exstyle = exstyle,
            .help_id = help_id,
            .extra_data_begin = extra_data_begin,
            .extra_data = extra_data,
            .extra_data_end = extra_data_end,
        };
        return &node.base;
    }

    fn parseToolbarButtonStatement(self: *Self) Error!?*Node {
        const keyword_token = try self.lookaheadToken(.normal);
        const button_type = rc.ToolbarButton.map.get(keyword_token.slice(self.lexer.buffer)) orelse return null;
        self.nextToken(.normal) catch unreachable;

        switch (button_type) {
            .separator => {
                const node = try self.state.arena.create(Node.Literal);
                node.* = .{
                    .token = keyword_token,
                };
                return &node.base;
            },
            .button => {
                const button_id = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

                const node = try self.state.arena.create(Node.SimpleStatement);
                node.* = .{
                    .identifier = keyword_token,
                    .value = button_id,
                };
                return &node.base;
            },
        }
    }

    /// Expects the current token to be handled, and that the menuitem/popup statement will
    /// begin on the next token.
    /// After return, the current token will be the token immediately before the end of the
    /// menuitem statement (or unchanged if the function returns null).
    fn parseMenuItemStatement(self: *Self, resource: Resource, top_level_menu_id_token: Token, nesting_level: u32) Error!?*Node {
        const menuitem_token = try self.lookaheadToken(.normal);
        const menuitem = rc.MenuItem.map.get(menuitem_token.slice(self.lexer.buffer)) orelse return null;
        self.nextToken(.normal) catch unreachable;

        if (nesting_level > max_nested_menu_level) {
            try self.addErrorDetails(.{
                .err = .nested_resource_level_exceeds_max,
                .token = top_level_menu_id_token,
                .extra = .{ .resource = resource },
            });
            return self.addErrorDetailsAndFail(.{
                .err = .nested_resource_level_exceeds_max,
                .type = .note,
                .token = menuitem_token,
                .extra = .{ .resource = resource },
            });
        }

        switch (resource) {
            .menu => switch (menuitem) {
                .menuitem => {
                    try self.nextToken(.normal);
                    if (rc.MenuItem.isSeparator(self.state.token.slice(self.lexer.buffer))) {
                        const separator_token = self.state.token;
                        // There can be any number of trailing commas after SEPARATOR
                        try self.skipAnyCommas();
                        const node = try self.state.arena.create(Node.MenuItemSeparator);
                        node.* = .{
                            .menuitem = menuitem_token,
                            .separator = separator_token,
                        };
                        return &node.base;
                    } else {
                        const text = self.state.token;
                        if (!text.isStringLiteral()) {
                            return self.addErrorDetailsAndFail(ErrorDetails{
                                .err = .expected_something_else,
                                .token = text,
                                .extra = .{ .expected_types = .{
                                    .string_literal = true,
                                } },
                            });
                        }
                        try self.skipAnyCommas();

                        const result = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

                        _ = try self.parseOptionalToken(.comma);

                        var options = std.ArrayListUnmanaged(Token){};
                        while (true) {
                            const option_token = try self.lookaheadToken(.normal);
                            if (!rc.MenuItem.Option.map.has(option_token.slice(self.lexer.buffer))) {
                                break;
                            }
                            self.nextToken(.normal) catch unreachable;
                            try options.append(self.state.arena, option_token);
                            try self.skipAnyCommas();
                        }

                        const node = try self.state.arena.create(Node.MenuItem);
                        node.* = .{
                            .menuitem = menuitem_token,
                            .text = text,
                            .result = result,
                            .option_list = try options.toOwnedSlice(self.state.arena),
                        };
                        return &node.base;
                    }
                },
                .popup => {
                    try self.nextToken(.normal);
                    const text = self.state.token;
                    if (!text.isStringLiteral()) {
                        return self.addErrorDetailsAndFail(ErrorDetails{
                            .err = .expected_something_else,
                            .token = text,
                            .extra = .{ .expected_types = .{
                                .string_literal = true,
                            } },
                        });
                    }
                    try self.skipAnyCommas();

                    var options = std.ArrayListUnmanaged(Token){};
                    while (true) {
                        const option_token = try self.lookaheadToken(.normal);
                        if (!rc.MenuItem.Option.map.has(option_token.slice(self.lexer.buffer))) {
                            break;
                        }
                        self.nextToken(.normal) catch unreachable;
                        try options.append(self.state.arena, option_token);
                        try self.skipAnyCommas();
                    }

                    try self.nextToken(.normal);
                    const begin_token = self.state.token;
                    try self.check(.begin);

                    var items = std.ArrayListUnmanaged(*Node){};
                    while (try self.parseMenuItemStatement(resource, top_level_menu_id_token, nesting_level + 1)) |item_node| {
                        try items.append(self.state.arena, item_node);
                    }

                    try self.nextToken(.normal);
                    const end_token = self.state.token;
                    try self.check(.end);

                    if (items.items.len == 0) {
                        return self.addErrorDetailsAndFail(.{
                            .err = .empty_menu_not_allowed,
                            .token = menuitem_token,
                        });
                    }

                    const node = try self.state.arena.create(Node.Popup);
                    node.* = .{
                        .popup = menuitem_token,
                        .text = text,
                        .option_list = try options.toOwnedSlice(self.state.arena),
                        .begin_token = begin_token,
                        .items = try items.toOwnedSlice(self.state.arena),
                        .end_token = end_token,
                    };
                    return &node.base;
                },
            },
            .menuex => {
                try self.nextToken(.normal);
                const text = self.state.token;
                if (!text.isStringLiteral()) {
                    return self.addErrorDetailsAndFail(ErrorDetails{
                        .err = .expected_something_else,
                        .token = text,
                        .extra = .{ .expected_types = .{
                            .string_literal = true,
                        } },
                    });
                }

                var param_parser = OptionalParamParser{ .parser = self };
                const id = try param_parser.parse(.{});
                const item_type = try param_parser.parse(.{});
                const state = try param_parser.parse(.{});

                if (menuitem == .menuitem) {
                    // trailing comma is allowed, skip it
                    _ = try self.parseOptionalToken(.comma);

                    const node = try self.state.arena.create(Node.MenuItemEx);
                    node.* = .{
                        .menuitem = menuitem_token,
                        .text = text,
                        .id = id,
                        .type = item_type,
                        .state = state,
                    };
                    return &node.base;
                }

                const help_id = try param_parser.parse(.{});

                // trailing comma is allowed, skip it
                _ = try self.parseOptionalToken(.comma);

                try self.nextToken(.normal);
                const begin_token = self.state.token;
                try self.check(.begin);

                var items = std.ArrayListUnmanaged(*Node){};
                while (try self.parseMenuItemStatement(resource, top_level_menu_id_token, nesting_level + 1)) |item_node| {
                    try items.append(self.state.arena, item_node);
                }

                try self.nextToken(.normal);
                const end_token = self.state.token;
                try self.check(.end);

                if (items.items.len == 0) {
                    return self.addErrorDetailsAndFail(.{
                        .err = .empty_menu_not_allowed,
                        .token = menuitem_token,
                    });
                }

                const node = try self.state.arena.create(Node.PopupEx);
                node.* = .{
                    .popup = menuitem_token,
                    .text = text,
                    .id = id,
                    .type = item_type,
                    .state = state,
                    .help_id = help_id,
                    .begin_token = begin_token,
                    .items = try items.toOwnedSlice(self.state.arena),
                    .end_token = end_token,
                };
                return &node.base;
            },
            else => unreachable,
        }
        @compileError("unreachable");
    }

    pub const OptionalParamParser = struct {
        finished: bool = false,
        parser: *Self,

        pub const Options = struct {
            not_expression_allowed: bool = false,
        };

        pub fn parse(self: *OptionalParamParser, options: OptionalParamParser.Options) Error!?*Node {
            if (self.finished) return null;
            if (!(try self.parser.parseOptionalToken(.comma))) {
                self.finished = true;
                return null;
            }
            // If the next lookahead token could be part of a number expression,
            // then parse it. Otherwise, treat it as an 'empty' expression and
            // continue parsing, since 'empty' values are allowed.
            if (try self.parser.lookaheadCouldBeNumberExpression(switch (options.not_expression_allowed) {
                true => .not_allowed,
                false => .not_disallowed,
            })) {
                const node = try self.parser.parseExpression(.{
                    .allowed_types = .{ .number = true },
                    .can_contain_not_expressions = options.not_expression_allowed,
                });
                return node;
            }
            return null;
        }
    };

    /// Expects the current token to be handled, and that the version statement will
    /// begin on the next token.
    /// After return, the current token will be the token immediately before the end of the
    /// version statement (or unchanged if the function returns null).
    fn parseVersionStatement(self: *Self) Error!?*Node {
        const type_token = try self.lookaheadToken(.normal);
        const statement_type = rc.VersionInfo.map.get(type_token.slice(self.lexer.buffer)) orelse return null;
        self.nextToken(.normal) catch unreachable;
        switch (statement_type) {
            .file_version, .product_version => {
                var parts = std.BoundedArray(*Node, 4){};

                while (parts.len < 4) {
                    const value = try self.parseExpression(.{ .allowed_types = .{ .number = true } });
                    parts.addOneAssumeCapacity().* = value;

                    if (parts.len == 4 or !(try self.parseOptionalToken(.comma))) {
                        break;
                    }
                }

                const node = try self.state.arena.create(Node.VersionStatement);
                node.* = .{
                    .type = type_token,
                    .parts = try self.state.arena.dupe(*Node, parts.slice()),
                };
                return &node.base;
            },
            else => {
                const value = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

                const node = try self.state.arena.create(Node.SimpleStatement);
                node.* = .{
                    .identifier = type_token,
                    .value = value,
                };
                return &node.base;
            },
        }
    }

    /// Expects the current token to be handled, and that the version BLOCK/VALUE will
    /// begin on the next token.
    /// After return, the current token will be the token immediately before the end of the
    /// version BLOCK/VALUE (or unchanged if the function returns null).
    fn parseVersionBlockOrValue(self: *Self, top_level_version_id_token: Token, nesting_level: u32) Error!?*Node {
        const keyword_token = try self.lookaheadToken(.normal);
        const keyword = rc.VersionBlock.map.get(keyword_token.slice(self.lexer.buffer)) orelse return null;
        self.nextToken(.normal) catch unreachable;

        if (nesting_level > max_nested_version_level) {
            try self.addErrorDetails(.{
                .err = .nested_resource_level_exceeds_max,
                .token = top_level_version_id_token,
                .extra = .{ .resource = .versioninfo },
            });
            return self.addErrorDetailsAndFail(.{
                .err = .nested_resource_level_exceeds_max,
                .type = .note,
                .token = keyword_token,
                .extra = .{ .resource = .versioninfo },
            });
        }

        try self.nextToken(.normal);
        const key = self.state.token;
        if (!key.isStringLiteral()) {
            return self.addErrorDetailsAndFail(.{
                .err = .expected_something_else,
                .token = key,
                .extra = .{ .expected_types = .{
                    .string_literal = true,
                } },
            });
        }
        // Need to keep track of this to detect a potential miscompilation when
        // the comma is omitted and the first value is a quoted string.
        const had_comma_before_first_value = try self.parseOptionalToken(.comma);
        try self.skipAnyCommas();

        const values = try self.parseBlockValuesList(had_comma_before_first_value);

        switch (keyword) {
            .block => {
                try self.nextToken(.normal);
                const begin_token = self.state.token;
                try self.check(.begin);

                var children = std.ArrayListUnmanaged(*Node){};
                while (try self.parseVersionBlockOrValue(top_level_version_id_token, nesting_level + 1)) |value_node| {
                    try children.append(self.state.arena, value_node);
                }

                try self.nextToken(.normal);
                const end_token = self.state.token;
                try self.check(.end);

                const node = try self.state.arena.create(Node.Block);
                node.* = .{
                    .identifier = keyword_token,
                    .key = key,
                    .values = values,
                    .begin_token = begin_token,
                    .children = try children.toOwnedSlice(self.state.arena),
                    .end_token = end_token,
                };
                return &node.base;
            },
            .value => {
                const node = try self.state.arena.create(Node.BlockValue);
                node.* = .{
                    .identifier = keyword_token,
                    .key = key,
                    .values = values,
                };
                return &node.base;
            },
        }
    }

    fn parseBlockValuesList(self: *Self, had_comma_before_first_value: bool) Error![]*Node {
        var values = std.ArrayListUnmanaged(*Node){};
        var seen_number: bool = false;
        var first_string_value: ?*Node = null;
        while (true) {
            const lookahead_token = try self.lookaheadToken(.normal);
            switch (lookahead_token.id) {
                .operator,
                .number,
                .open_paren,
                .quoted_ascii_string,
                .quoted_wide_string,
                => {},
                else => break,
            }
            const value = try self.parseExpression(.{});

            if (value.isNumberExpression()) {
                seen_number = true;
            } else if (first_string_value == null) {
                std.debug.assert(value.isStringLiteral());
                first_string_value = value;
            }

            const has_trailing_comma = try self.parseOptionalToken(.comma);
            try self.skipAnyCommas();

            const value_value = try self.state.arena.create(Node.BlockValueValue);
            value_value.* = .{
                .expression = value,
                .trailing_comma = has_trailing_comma,
            };
            try values.append(self.state.arena, &value_value.base);
        }
        if (seen_number and first_string_value != null) {
            // The Win32 RC compiler does some strange stuff with the data size:
            // Strings are counted as UTF-16 code units including the null-terminator
            // Numbers are counted as their byte lengths
            // So, when both strings and numbers are within a single value,
            // it incorrectly sets the value's type as binary, but then gives the
            // data length as a mixture of bytes and UTF-16 code units. This means that
            // when the length is read, it will be treated as byte length and will
            // not read the full value. We don't reproduce this behavior, so we warn
            // of the miscompilation here.
            try self.addErrorDetails(.{
                .err = .rc_would_miscompile_version_value_byte_count,
                .type = .warning,
                .token = first_string_value.?.getFirstToken(),
                .token_span_start = values.items[0].getFirstToken(),
                .token_span_end = values.items[values.items.len - 1].getLastToken(),
            });
            try self.addErrorDetails(.{
                .err = .rc_would_miscompile_version_value_byte_count,
                .type = .note,
                .token = first_string_value.?.getFirstToken(),
                .token_span_start = values.items[0].getFirstToken(),
                .token_span_end = values.items[values.items.len - 1].getLastToken(),
                .print_source_line = false,
            });
        }
        if (!had_comma_before_first_value and values.items.len > 0 and values.items[0].cast(.block_value_value).?.expression.isStringLiteral()) {
            const token = values.items[0].cast(.block_value_value).?.expression.cast(.literal).?.token;
            try self.addErrorDetails(.{
                .err = .rc_would_miscompile_version_value_padding,
                .type = .warning,
                .token = token,
            });
            try self.addErrorDetails(.{
                .err = .rc_would_miscompile_version_value_padding,
                .type = .note,
                .token = token,
                .print_source_line = false,
            });
        }
        return values.toOwnedSlice(self.state.arena);
    }

    fn numberExpressionContainsAnyLSuffixes(expression_node: *Node, source: []const u8, code_page_lookup: *const CodePageLookup) bool {
        // TODO: This could probably be done without evaluating the whole expression
        return Compiler.evaluateNumberExpression(expression_node, source, code_page_lookup).is_long;
    }

    /// Expects the current token to be a literal token that contains the string LANGUAGE
    fn parseLanguageStatement(self: *Self) Error!*Node {
        const language_token = self.state.token;

        const primary_language = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

        try self.nextToken(.normal);
        try self.check(.comma);

        const sublanguage = try self.parseExpression(.{ .allowed_types = .{ .number = true } });

        // The Win32 RC compiler errors if either parameter contains any number with an L
        // suffix. Instead of that, we want to warn and then let the values get truncated.
        // The warning is done here to allow the compiler logic to not have to deal with this.
        if (numberExpressionContainsAnyLSuffixes(primary_language, self.lexer.buffer, &self.state.input_code_page_lookup)) {
            try self.addErrorDetails(.{
                .err = .rc_would_error_u16_with_l_suffix,
                .type = .warning,
                .token = primary_language.getFirstToken(),
                .token_span_end = primary_language.getLastToken(),
                .extra = .{ .statement_with_u16_param = .language },
            });
            try self.addErrorDetails(.{
                .err = .rc_would_error_u16_with_l_suffix,
                .print_source_line = false,
                .type = .note,
                .token = primary_language.getFirstToken(),
                .token_span_end = primary_language.getLastToken(),
                .extra = .{ .statement_with_u16_param = .language },
            });
        }
        if (numberExpressionContainsAnyLSuffixes(sublanguage, self.lexer.buffer, &self.state.input_code_page_lookup)) {
            try self.addErrorDetails(.{
                .err = .rc_would_error_u16_with_l_suffix,
                .type = .warning,
                .token = sublanguage.getFirstToken(),
                .token_span_end = sublanguage.getLastToken(),
                .extra = .{ .statement_with_u16_param = .language },
            });
            try self.addErrorDetails(.{
                .err = .rc_would_error_u16_with_l_suffix,
                .print_source_line = false,
                .type = .note,
                .token = sublanguage.getFirstToken(),
                .token_span_end = sublanguage.getLastToken(),
                .extra = .{ .statement_with_u16_param = .language },
            });
        }

        const node = try self.state.arena.create(Node.LanguageStatement);
        node.* = .{
            .language_token = language_token,
            .primary_language_id = primary_language,
            .sublanguage_id = sublanguage,
        };
        return &node.base;
    }

    pub const ParseExpressionOptions = struct {
        is_known_to_be_number_expression: bool = false,
        can_contain_not_expressions: bool = false,
        nesting_context: NestingContext = .{},
        allowed_types: AllowedTypes = .{ .literal = true, .number = true, .string = true },
        expected_types_override: ?ErrorDetails.ExpectedTypes = null,

        pub const AllowedTypes = struct {
            literal: bool = false,
            number: bool = false,
            string: bool = false,
        };

        pub const NestingContext = struct {
            first_token: ?Token = null,
            last_token: ?Token = null,
            level: u32 = 0,

            /// Returns a new NestingContext with values modified appropriately for an increased nesting level
            fn incremented(ctx: NestingContext, first_token: Token, most_recent_token: Token) NestingContext {
                return .{
                    .first_token = ctx.first_token orelse first_token,
                    .last_token = most_recent_token,
                    .level = ctx.level + 1,
                };
            }
        };

        pub fn toErrorDetails(options: ParseExpressionOptions, token: Token) ErrorDetails {
            // TODO: expected_types_override interaction with is_known_to_be_number_expression?
            var expected_types = options.expected_types_override orelse ErrorDetails.ExpectedTypes{
                .number = options.allowed_types.number,
                .number_expression = options.allowed_types.number,
                .string_literal = options.allowed_types.string and !options.is_known_to_be_number_expression,
                .literal = options.allowed_types.literal and !options.is_known_to_be_number_expression,
            };
            return ErrorDetails{
                .err = .expected_something_else,
                .token = token,
                .extra = .{ .expected_types = expected_types },
            };
        }
    };

    /// Returns true if the next lookahead token is a number or could be the start of a number expression.
    /// Only useful when looking for empty expressions in optional fields.
    fn lookaheadCouldBeNumberExpression(self: *Self, not_allowed: enum { not_allowed, not_disallowed }) Error!bool {
        var lookahead_token = try self.lookaheadToken(.normal);
        switch (lookahead_token.id) {
            .literal => if (not_allowed == .not_allowed) {
                return std.ascii.eqlIgnoreCase("NOT", lookahead_token.slice(self.lexer.buffer));
            } else return false,
            .number => return true,
            .open_paren => return true,
            .operator => {
                // + can be a unary operator, see parseExpression's handling of unary +
                const operator_char = lookahead_token.slice(self.lexer.buffer)[0];
                return operator_char == '+';
            },
            else => return false,
        }
    }

    fn parsePrimary(self: *Self, options: ParseExpressionOptions) Error!*Node {
        try self.nextToken(.normal);
        const first_token = self.state.token;
        var is_close_paren_expression = false;
        var is_unary_plus_expression = false;
        switch (self.state.token.id) {
            .quoted_ascii_string, .quoted_wide_string => {
                if (!options.allowed_types.string) return self.addErrorDetailsAndFail(options.toErrorDetails(self.state.token));
                const node = try self.state.arena.create(Node.Literal);
                node.* = .{ .token = self.state.token };
                return &node.base;
            },
            .literal => {
                if (options.can_contain_not_expressions and std.ascii.eqlIgnoreCase("NOT", self.state.token.slice(self.lexer.buffer))) {
                    const not_token = self.state.token;
                    try self.nextToken(.normal);
                    try self.check(.number);
                    if (!options.allowed_types.number) return self.addErrorDetailsAndFail(options.toErrorDetails(self.state.token));
                    const node = try self.state.arena.create(Node.NotExpression);
                    node.* = .{
                        .not_token = not_token,
                        .number_token = self.state.token,
                    };
                    return &node.base;
                }
                if (!options.allowed_types.literal) return self.addErrorDetailsAndFail(options.toErrorDetails(self.state.token));
                const node = try self.state.arena.create(Node.Literal);
                node.* = .{ .token = self.state.token };
                return &node.base;
            },
            .number => {
                if (!options.allowed_types.number) return self.addErrorDetailsAndFail(options.toErrorDetails(self.state.token));
                const node = try self.state.arena.create(Node.Literal);
                node.* = .{ .token = self.state.token };
                return &node.base;
            },
            .open_paren => {
                const open_paren_token = self.state.token;

                const expression = try self.parseExpression(.{
                    .is_known_to_be_number_expression = true,
                    .can_contain_not_expressions = options.can_contain_not_expressions,
                    .nesting_context = options.nesting_context.incremented(first_token, open_paren_token),
                    .allowed_types = .{ .number = true },
                });

                try self.nextToken(.normal);
                // TODO: Add context to error about where the open paren is
                try self.check(.close_paren);

                if (!options.allowed_types.number) return self.addErrorDetailsAndFail(options.toErrorDetails(open_paren_token));
                const node = try self.state.arena.create(Node.GroupedExpression);
                node.* = .{
                    .open_token = open_paren_token,
                    .expression = expression,
                    .close_token = self.state.token,
                };
                return &node.base;
            },
            .close_paren => {
                // Note: In the Win32 implementation, a single close paren
                // counts as a valid "expression", but only when its the first and
                // only token in the expression. Such an expression is then treated
                // as a 'skip this expression' instruction. For example:
                //   1 RCDATA { 1, ), ), ), 2 }
                // will be evaluated as if it were `1 RCDATA { 1, 2 }` and only
                // 0x0001 and 0x0002 will be written to the .res data.
                //
                // This behavior is not emulated because it almost certainly has
                // no valid use cases and only introduces edge cases that are
                // not worth the effort to track down and deal with. Instead,
                // we error but also add a note about the Win32 RC behavior if
                // this edge case is detected.
                if (!options.is_known_to_be_number_expression) {
                    is_close_paren_expression = true;
                }
            },
            .operator => {
                // In the Win32 implementation, something akin to a unary +
                // is allowed but it doesn't behave exactly like a unary +.
                // Instead of emulating the Win32 behavior, we instead error
                // and add a note about unary plus not being allowed.
                //
                // This is done because unary + only works in some places,
                // and there's no real use-case for it since it's so limited
                // in how it can be used (e.g. +1 is accepted but (+1) will error)
                //
                // Even understanding when unary plus is allowed is difficult, so
                // we don't do any fancy detection of when the Win32 RC compiler would
                // allow a unary + and instead just output the note in all cases.
                //
                // Some examples of allowed expressions by the Win32 compiler:
                //  +1
                //  0|+5
                //  +1+2
                //  +~-5
                //  +(1)
                //
                // Some examples of disallowed expressions by the Win32 compiler:
                //  (+1)
                //  ++5
                //
                // TODO: Potentially re-evaluate and support the unary plus in a bug-for-bug
                //       compatible way.
                const operator_char = self.state.token.slice(self.lexer.buffer)[0];
                if (operator_char == '+') {
                    is_unary_plus_expression = true;
                }
            },
            else => {},
        }

        try self.addErrorDetails(options.toErrorDetails(self.state.token));
        if (is_close_paren_expression) {
            try self.addErrorDetails(ErrorDetails{
                .err = .close_paren_expression,
                .type = .note,
                .token = self.state.token,
                .print_source_line = false,
            });
        }
        if (is_unary_plus_expression) {
            try self.addErrorDetails(ErrorDetails{
                .err = .unary_plus_expression,
                .type = .note,
                .token = self.state.token,
                .print_source_line = false,
            });
        }
        return error.ParseError;
    }

    /// Expects the current token to have already been dealt with, and that the
    /// expression will start on the next token.
    /// After return, the current token will have been dealt with.
    fn parseExpression(self: *Self, options: ParseExpressionOptions) Error!*Node {
        if (options.nesting_context.level > max_nested_expression_level) {
            try self.addErrorDetails(.{
                .err = .nested_expression_level_exceeds_max,
                .token = options.nesting_context.first_token.?,
            });
            return self.addErrorDetailsAndFail(.{
                .err = .nested_expression_level_exceeds_max,
                .type = .note,
                .token = options.nesting_context.last_token.?,
            });
        }
        var expr: *Node = try self.parsePrimary(options);
        const first_token = expr.getFirstToken();

        // Non-number expressions can't have operators, so we can just return
        if (!expr.isNumberExpression()) return expr;

        while (try self.parseOptionalTokenAdvanced(.operator, .normal_expect_operator)) {
            const operator = self.state.token;
            const rhs_node = try self.parsePrimary(.{
                .is_known_to_be_number_expression = true,
                .can_contain_not_expressions = options.can_contain_not_expressions,
                .nesting_context = options.nesting_context.incremented(first_token, operator),
                .allowed_types = options.allowed_types,
            });

            if (!rhs_node.isNumberExpression()) {
                return self.addErrorDetailsAndFail(ErrorDetails{
                    .err = .expected_something_else,
                    .token = rhs_node.getFirstToken(),
                    .token_span_end = rhs_node.getLastToken(),
                    .extra = .{ .expected_types = .{
                        .number = true,
                        .number_expression = true,
                    } },
                });
            }

            const node = try self.state.arena.create(Node.BinaryExpression);
            node.* = .{
                .left = expr,
                .operator = operator,
                .right = rhs_node,
            };
            expr = &node.base;
        }

        return expr;
    }

    /// Skips any amount of commas (including zero)
    /// In other words, it will skip the regex `,*`
    /// Assumes the token(s) should be parsed with `.normal` as the method.
    fn skipAnyCommas(self: *Self) !void {
        while (try self.parseOptionalToken(.comma)) {}
    }

    /// Advances the current token only if the token's id matches the specified `id`.
    /// Assumes the token should be parsed with `.normal` as the method.
    /// Returns true if the token matched, false otherwise.
    fn parseOptionalToken(self: *Self, id: Token.Id) Error!bool {
        return self.parseOptionalTokenAdvanced(id, .normal);
    }

    /// Advances the current token only if the token's id matches the specified `id`.
    /// Returns true if the token matched, false otherwise.
    fn parseOptionalTokenAdvanced(self: *Self, id: Token.Id, comptime method: Lexer.LexMethod) Error!bool {
        const maybe_token = try self.lookaheadToken(method);
        if (maybe_token.id != id) return false;
        self.nextToken(method) catch unreachable;
        return true;
    }

    fn addErrorDetails(self: *Self, details: ErrorDetails) Allocator.Error!void {
        try self.state.diagnostics.append(details);
    }

    fn addErrorDetailsAndFail(self: *Self, details: ErrorDetails) Error {
        try self.addErrorDetails(details);
        return error.ParseError;
    }

    fn nextToken(self: *Self, comptime method: Lexer.LexMethod) Error!void {
        self.state.token = token: while (true) {
            const token = self.lexer.next(method) catch |err| switch (err) {
                error.CodePagePragmaInIncludedFile => {
                    // The Win32 RC compiler silently ignores such `#pragma code_point` directives,
                    // but we want to both ignore them *and* emit a warning
                    try self.addErrorDetails(.{
                        .err = .code_page_pragma_in_included_file,
                        .type = .warning,
                        .token = self.lexer.error_context_token.?,
                    });
                    continue;
                },
                error.CodePagePragmaInvalidCodePage => {
                    var details = self.lexer.getErrorDetails(err);
                    if (!self.options.warn_instead_of_error_on_invalid_code_page) {
                        return self.addErrorDetailsAndFail(details);
                    }
                    details.type = .warning;
                    try self.addErrorDetails(details);
                    continue;
                },
                error.InvalidDigitCharacterInNumberLiteral => {
                    const details = self.lexer.getErrorDetails(err);
                    try self.addErrorDetails(details);
                    return self.addErrorDetailsAndFail(.{
                        .err = details.err,
                        .type = .note,
                        .token = details.token,
                        .print_source_line = false,
                    });
                },
                else => return self.addErrorDetailsAndFail(self.lexer.getErrorDetails(err)),
            };
            break :token token;
        };
        // After every token, set the input code page for its line
        try self.state.input_code_page_lookup.setForToken(self.state.token, self.lexer.current_code_page);
        // But only set the output code page to the current code page if we are past the first code_page pragma in the file.
        // Otherwise, we want to fill the lookup using the default code page so that lookups still work for lines that
        // don't have an explicit output code page set.
        const output_code_page = if (self.lexer.seen_pragma_code_pages > 1) self.lexer.current_code_page else self.state.output_code_page_lookup.default_code_page;
        try self.state.output_code_page_lookup.setForToken(self.state.token, output_code_page);
    }

    fn lookaheadToken(self: *Self, comptime method: Lexer.LexMethod) Error!Token {
        self.state.lookahead_lexer = self.lexer.*;
        return token: while (true) {
            break :token self.state.lookahead_lexer.next(method) catch |err| switch (err) {
                // Ignore this error and get the next valid token, we'll deal with this
                // properly when getting the token for real
                error.CodePagePragmaInIncludedFile => continue,
                else => return self.addErrorDetailsAndFail(self.state.lookahead_lexer.getErrorDetails(err)),
            };
        };
    }

    fn tokenSlice(self: *Self) []const u8 {
        return self.state.token.slice(self.lexer.buffer);
    }

    /// Check that the current token is something that can be used as an ID
    fn checkId(self: *Self) !void {
        switch (self.state.token.id) {
            .literal => {},
            else => {
                return self.addErrorDetailsAndFail(ErrorDetails{
                    .err = .expected_token,
                    .token = self.state.token,
                    .extra = .{ .expected = .literal },
                });
            },
        }
    }

    fn check(self: *Self, expected_token_id: Token.Id) !void {
        if (self.state.token.id != expected_token_id) {
            return self.addErrorDetailsAndFail(ErrorDetails{
                .err = .expected_token,
                .token = self.state.token,
                .extra = .{ .expected = expected_token_id },
            });
        }
    }

    fn checkResource(self: *Self) !Resource {
        switch (self.state.token.id) {
            .literal => return Resource.fromString(.{
                .slice = self.state.token.slice(self.lexer.buffer),
                .code_page = self.lexer.current_code_page,
            }),
            else => {
                return self.addErrorDetailsAndFail(ErrorDetails{
                    .err = .expected_token,
                    .token = self.state.token,
                    .extra = .{ .expected = .literal },
                });
            },
        }
    }
};

fn testParse(source: []const u8, expected_ast_dump: []const u8) !void {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    // TODO: test different code pages
    var lexer = Lexer.init(source, .{});
    var parser = Parser.init(&lexer, .{});
    var tree = parser.parse(allocator, &diagnostics) catch |err| switch (err) {
        error.ParseError => {
            diagnostics.renderToStdErrDetectTTY(std.fs.cwd(), source, null);
            return err;
        },
        else => |e| return e,
    };
    defer tree.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try tree.dump(buf.writer());
    try std.testing.expectEqualStrings(expected_ast_dump, buf.items);
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
        \\  literal 1
        \\  literal 2
        \\  literal 3
        \\
    );
    try testParse("id RCDATA { L\"1\",\"2\",3 }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 3
        \\  literal L"1"
        \\  literal "2"
        \\  literal 3
        \\
    );
    try testParse("id RCDATA { 1\t,,  ,,,2,,  ,  3 ,,,  , }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 3
        \\  literal 1
        \\  literal 2
        \\  literal 3
        \\
    );
    try testParse("id RCDATA { 1 2 3 }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 3
        \\  literal 1
        \\  literal 2
        \\  literal 3
        \\
    );
}

test "number expressions" {
    try testParse("id RCDATA { 1-- }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 1
        \\  binary_expression -
        \\   literal 1
        \\   literal -
        \\
    );
    try testParse("id RCDATA { (1) }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 1
        \\  grouped_expression
        \\  (
        \\   literal 1
        \\  )
        \\
    );
    try testParse("id RCDATA { (1+-1) }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 1
        \\  grouped_expression
        \\  (
        \\   binary_expression +
        \\    literal 1
        \\    literal -1
        \\  )
        \\
    );
    // All operators have the same precedence, the result should be from left-to-right.
    // In C, this would evaluate as `7 | (7 + 1)`, but here it evaluates as `(7 | 7) + 1`.
    try testParse("id RCDATA { 7 | 7 + 1 }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 1
        \\  binary_expression +
        \\   binary_expression |
        \\    literal 7
        \\    literal 7
        \\   literal 1
        \\
    );
    // This looks like an invalid number expression, but it's interpreted as three separate data elements:
    // "str", - (evaluates to 0), and 1
    try testParse("id RCDATA { \"str\" - 1 }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 3
        \\  literal "str"
        \\  literal -
        \\  literal 1
        \\
    );
    // But this is an actual error since it tries to use a string as part of a number expression
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected number, number expression, or quoted string literal; got '&'" }},
        "1 RCDATA { \"str\" & 1 }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected number or number expression; got '\"str\"'" }},
        "1 RCDATA { (\"str\") }",
        null,
    );
}

test "STRINGTABLE" {
    try testParse("STRINGTABLE { 0 \"hello\" }",
        \\root
        \\ string_table STRINGTABLE [0 common_resource_attributes]
        \\ {
        \\  string_table_string
        \\   literal 0
        \\   "hello"
        \\ }
        \\
    );
    try testParse("STRINGTABLE { 0, \"hello\" }",
        \\root
        \\ string_table STRINGTABLE [0 common_resource_attributes]
        \\ {
        \\  string_table_string
        \\   literal 0
        \\   "hello"
        \\ }
        \\
    );
    try testParse(
        \\STRINGTABLE {
        \\  (0+1), "hello"
        \\  -1, L"hello"
        \\}
    ,
        \\root
        \\ string_table STRINGTABLE [0 common_resource_attributes]
        \\ {
        \\  string_table_string
        \\   grouped_expression
        \\   (
        \\    binary_expression +
        \\     literal 0
        \\     literal 1
        \\   )
        \\   "hello"
        \\  string_table_string
        \\   literal -1
        \\   L"hello"
        \\ }
        \\
    );

    try testParse("STRINGTABLE FIXED { 0 \"hello\" }",
        \\root
        \\ string_table STRINGTABLE [1 common_resource_attributes]
        \\ {
        \\  string_table_string
        \\   literal 0
        \\   "hello"
        \\ }
        \\
    );

    try testParse("STRINGTABLE { 1+1 \"hello\" }",
        \\root
        \\ string_table STRINGTABLE [0 common_resource_attributes]
        \\ {
        \\  string_table_string
        \\   binary_expression +
        \\    literal 1
        \\    literal 1
        \\   "hello"
        \\ }
        \\
    );

    // duplicate optional statements are preserved in the AST
    try testParse("STRINGTABLE LANGUAGE 1,1 LANGUAGE 1,2 { 0 \"hello\" }",
        \\root
        \\ string_table STRINGTABLE [0 common_resource_attributes]
        \\  language_statement LANGUAGE
        \\   literal 1
        \\   literal 1
        \\  language_statement LANGUAGE
        \\   literal 1
        \\   literal 2
        \\ {
        \\  string_table_string
        \\   literal 0
        \\   "hello"
        \\ }
        \\
    );

    try testParse("STRINGTABLE FIXED VERSION 1 CHARACTERISTICS (1+2) { 0 \"hello\" }",
        \\root
        \\ string_table STRINGTABLE [1 common_resource_attributes]
        \\  simple_statement VERSION
        \\   literal 1
        \\  simple_statement CHARACTERISTICS
        \\   grouped_expression
        \\   (
        \\    binary_expression +
        \\     literal 1
        \\     literal 2
        \\   )
        \\ {
        \\  string_table_string
        \\   literal 0
        \\   "hello"
        \\ }
        \\
    );
}

test "control characters as whitespace" {
    // any non-illegal control character is treated as whitespace
    try testParse("id RCDATA { 1\x052 }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 2
        \\  literal 1
        \\  literal 2
        \\
    );
    // some illegal control characters are legal inside of string literals
    try testParse("id RCDATA { \"\x01\" }",
        \\root
        \\ resource_raw_data id RCDATA [0 common_resource_attributes] raw data: 1
        \\
    ++ "  literal \"\x01\"\n"); // needed to get the actual byte \x01 in the expected output
}

test "top-level statements" {
    try testParse("LANGUAGE 0, 0",
        \\root
        \\ language_statement LANGUAGE
        \\  literal 0
        \\  literal 0
        \\
    );
    try testParse("VERSION 0",
        \\root
        \\ simple_statement VERSION
        \\  literal 0
        \\
    );
    try testParse("CHARACTERISTICS 0",
        \\root
        \\ simple_statement CHARACTERISTICS
        \\  literal 0
        \\
    );
    // dangling tokens should be an error if they are a the start of a valid top-level statement
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected number or number expression; got '<eof>'" }},
        "LANGUAGE",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected number or number expression; got '<eof>'" }},
        "VERSION",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected number or number expression; got '<eof>'" }},
        "LANGUAGE",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected '<'{' or BEGIN>', got '<eof>'" }},
        "STRINGTABLE",
        null,
    );
}

test "accelerators" {
    try testParse("1 ACCELERATORS FIXED VERSION 1 {}",
        \\root
        \\ accelerators 1 ACCELERATORS [1 common_resource_attributes]
        \\  simple_statement VERSION
        \\   literal 1
        \\ {
        \\ }
        \\
    );
    try testParse("1 ACCELERATORS { \"^C\", 1 L\"a\", 2 }",
        \\root
        \\ accelerators 1 ACCELERATORS [0 common_resource_attributes]
        \\ {
        \\  accelerator
        \\   literal "^C"
        \\   literal 1
        \\  accelerator
        \\   literal L"a"
        \\   literal 2
        \\ }
        \\
    );
    try testParse("1 ACCELERATORS { (1+1), -1+1, CONTROL, ASCII, VIRTKEY, ALT, SHIFT }",
        \\root
        \\ accelerators 1 ACCELERATORS [0 common_resource_attributes]
        \\ {
        \\  accelerator CONTROL, ASCII, VIRTKEY, ALT, SHIFT
        \\   grouped_expression
        \\   (
        \\    binary_expression +
        \\     literal 1
        \\     literal 1
        \\   )
        \\   binary_expression +
        \\    literal -1
        \\    literal 1
        \\ }
        \\
    );
}

test "dialogs" {
    try testParse("1 DIALOG FIXED 1, 2, 3, (3 - 1) LANGUAGE 1, 2 {}",
        \\root
        \\ dialog 1 DIALOG [1 common_resource_attributes]
        \\  x:
        \\   literal 1
        \\  y:
        \\   literal 2
        \\  width:
        \\   literal 3
        \\  height:
        \\   grouped_expression
        \\   (
        \\    binary_expression -
        \\     literal 3
        \\     literal 1
        \\   )
        \\  language_statement LANGUAGE
        \\   literal 1
        \\   literal 2
        \\ {
        \\ }
        \\
    );
    try testParse("1 DIALOGEX 1, 2, 3, 4, 5 {}",
        \\root
        \\ dialog 1 DIALOGEX [0 common_resource_attributes]
        \\  x:
        \\   literal 1
        \\  y:
        \\   literal 2
        \\  width:
        \\   literal 3
        \\  height:
        \\   literal 4
        \\  help_id:
        \\   literal 5
        \\ {
        \\ }
        \\
    );
    try testParse("1 DIALOG 1, 2, 3, 4 FONT 1 \"hello\" {}",
        \\root
        \\ dialog 1 DIALOG [0 common_resource_attributes]
        \\  x:
        \\   literal 1
        \\  y:
        \\   literal 2
        \\  width:
        \\   literal 3
        \\  height:
        \\   literal 4
        \\  font_statement FONT typeface: "hello"
        \\   point_size:
        \\    literal 1
        \\ {
        \\ }
        \\
    );
    // FONT allows empty values for weight and charset in DIALOGEX
    try testParse("1 DIALOGEX 1, 2, 3, 4 FONT 1,,, \"hello\", , 1, {}",
        \\root
        \\ dialog 1 DIALOGEX [0 common_resource_attributes]
        \\  x:
        \\   literal 1
        \\  y:
        \\   literal 2
        \\  width:
        \\   literal 3
        \\  height:
        \\   literal 4
        \\  font_statement FONT typeface: "hello"
        \\   point_size:
        \\    literal 1
        \\   italic:
        \\    literal 1
        \\ {
        \\ }
        \\
    );
    // but italic cannot be empty
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected number or number expression; got ','" }},
        "1 DIALOGEX 1, 2, 3, 4 FONT 1,,, \"hello\", 1, , 1 {}",
        null,
    );
    try testParse(
        \\1 DIALOGEX FIXED DISCARDABLE 1, 2, 3, 4
        \\STYLE 0x80000000L | 0x00800000L
        \\CAPTION "Error!"
        \\EXSTYLE 1
        \\CLASS "hello1"
        \\CLASS 2
        \\MENU 2+"4"
        \\MENU "1"
        \\FONT 12 "first", 1001-1, 65537L, 257-2
        \\FONT 8+2,, ,, "second", 0
        \\{}
    ,
        \\root
        \\ dialog 1 DIALOGEX [2 common_resource_attributes]
        \\  x:
        \\   literal 1
        \\  y:
        \\   literal 2
        \\  width:
        \\   literal 3
        \\  height:
        \\   literal 4
        \\  simple_statement STYLE
        \\   binary_expression |
        \\    literal 0x80000000L
        \\    literal 0x00800000L
        \\  simple_statement CAPTION
        \\   literal "Error!"
        \\  simple_statement EXSTYLE
        \\   literal 1
        \\  simple_statement CLASS
        \\   literal "hello1"
        \\  simple_statement CLASS
        \\   literal 2
        \\  simple_statement MENU
        \\   literal 2+"4"
        \\  simple_statement MENU
        \\   literal "1"
        \\  font_statement FONT typeface: "first"
        \\   point_size:
        \\    literal 12
        \\   weight:
        \\    binary_expression -
        \\     literal 1001
        \\     literal 1
        \\   italic:
        \\    literal 65537L
        \\   char_set:
        \\    binary_expression -
        \\     literal 257
        \\     literal 2
        \\  font_statement FONT typeface: "second"
        \\   point_size:
        \\    binary_expression +
        \\     literal 8
        \\     literal 2
        \\   weight:
        \\    literal 0
        \\ {
        \\ }
        \\
    );
}

test "dialog controls" {
    try testParse(
        \\1 DIALOGEX 1, 2, 3, 4
        \\{
        \\    AUTO3STATE,, "mytext",, 900,, 1 2 3 4, 0, 0, 100 { "AUTO3STATE" }
        \\    AUTOCHECKBOX "mytext", 901, 1, 2, 3, 4, 0, 0, 100 { "AUTOCHECKBOX" }
        \\    AUTORADIOBUTTON "mytext", 902, 1, 2, 3, 4, 0, 0, 100 { "AUTORADIOBUTTON" }
        \\    CHECKBOX "mytext", 903, 1, 2, 3, 4, 0, 0, 100 { "CHECKBOX" }
        \\    COMBOBOX 904,, 1 2 3 4, 0, 0, 100 { "COMBOBOX" }
        \\    CONTROL "mytext",, 905,, "\x42UTTON",, 1,, 2 3 4 0, 0, 100 { "CONTROL (BUTTON)" }
        \\    CONTROL 1,, 9051,, (0x80+1),, 1,, 2 3 4 0, 0, 100 { "CONTROL (0x80)" }
        \\    CONTROL 1,, 9052,, (0x80+1),, 1,, 2 3 4 0 { "CONTROL (0x80)" }
        \\    CTEXT "mytext", 906, 1, 2, 3, 4, 0, 0, 100 { "CTEXT" }
        \\    CTEXT "mytext", 9061, 1, 2, 3, 4 { "CTEXT" }
        \\    DEFPUSHBUTTON "mytext", 907, 1, 2, 3, 4, 0, 0, 100 { "DEFPUSHBUTTON" }
        \\    EDITTEXT 908, 1, 2, 3, 4, 0, 0, 100 { "EDITTEXT" }
        \\    HEDIT 9081, 1, 2, 3, 4, 0, 0, 100 { "HEDIT" }
        \\    IEDIT 9082, 1, 2, 3, 4, 0, 0, 100 { "IEDIT" }
        \\    GROUPBOX "mytext", 909, 1, 2, 3, 4, 0, 0, 100 { "GROUPBOX" }
        \\    ICON "mytext", 910, 1, 2, 3, 4, 0, 0, 100 { "ICON" }
        \\    LISTBOX 911, 1, 2, 3, 4, 0, 0, 100 { "LISTBOX" }
        \\    LTEXT "mytext", 912, 1, 2, 3, 4, 0, 0, 100 { "LTEXT" }
        \\    PUSHBOX "mytext", 913, 1, 2, 3, 4, 0, 0, 100 { "PUSHBOX" }
        \\    PUSHBUTTON "mytext", 914, 1, 2, 3, 4, 0, 0, 100 { "PUSHBUTTON" }
        \\    RADIOBUTTON "mytext", 915, 1, 2, 3, 4, 0, 0, 100 { "RADIOBUTTON" }
        \\    RTEXT "mytext", 916, 1, 2, 3, 4, 0, 0, 100 { "RTEXT" }
        \\    SCROLLBAR 917, 1, 2, 3, 4, 0, 0, 100 { "SCROLLBAR" }
        \\    STATE3 "mytext", 918, 1, 2, 3, 4, 0, 0, 100 { "STATE3" }
        \\    USERBUTTON "mytext", 919, 1, 2, 3, 4, 0, 0, 100 { "USERBUTTON" }
        \\}
    ,
        \\root
        \\ dialog 1 DIALOGEX [0 common_resource_attributes]
        \\  x:
        \\   literal 1
        \\  y:
        \\   literal 2
        \\  width:
        \\   literal 3
        \\  height:
        \\   literal 4
        \\ {
        \\  control_statement AUTO3STATE text: "mytext"
        \\   id:
        \\    literal 900
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "AUTO3STATE"
        \\  }
        \\  control_statement AUTOCHECKBOX text: "mytext"
        \\   id:
        \\    literal 901
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "AUTOCHECKBOX"
        \\  }
        \\  control_statement AUTORADIOBUTTON text: "mytext"
        \\   id:
        \\    literal 902
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "AUTORADIOBUTTON"
        \\  }
        \\  control_statement CHECKBOX text: "mytext"
        \\   id:
        \\    literal 903
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "CHECKBOX"
        \\  }
        \\  control_statement COMBOBOX
        \\   id:
        \\    literal 904
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "COMBOBOX"
        \\  }
        \\  control_statement CONTROL text: "mytext"
        \\   class:
        \\    literal "\x42UTTON"
        \\   id:
        \\    literal 905
        \\   x:
        \\    literal 2
        \\   y:
        \\    literal 3
        \\   width:
        \\    literal 4
        \\   height:
        \\    literal 0
        \\   style:
        \\    literal 1
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "CONTROL (BUTTON)"
        \\  }
        \\  control_statement CONTROL text: 1
        \\   class:
        \\    grouped_expression
        \\    (
        \\     binary_expression +
        \\      literal 0x80
        \\      literal 1
        \\    )
        \\   id:
        \\    literal 9051
        \\   x:
        \\    literal 2
        \\   y:
        \\    literal 3
        \\   width:
        \\    literal 4
        \\   height:
        \\    literal 0
        \\   style:
        \\    literal 1
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "CONTROL (0x80)"
        \\  }
        \\  control_statement CONTROL text: 1
        \\   class:
        \\    grouped_expression
        \\    (
        \\     binary_expression +
        \\      literal 0x80
        \\      literal 1
        \\    )
        \\   id:
        \\    literal 9052
        \\   x:
        \\    literal 2
        \\   y:
        \\    literal 3
        \\   width:
        \\    literal 4
        \\   height:
        \\    literal 0
        \\   style:
        \\    literal 1
        \\  {
        \\   literal "CONTROL (0x80)"
        \\  }
        \\  control_statement CTEXT text: "mytext"
        \\   id:
        \\    literal 906
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "CTEXT"
        \\  }
        \\  control_statement CTEXT text: "mytext"
        \\   id:
        \\    literal 9061
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\  {
        \\   literal "CTEXT"
        \\  }
        \\  control_statement DEFPUSHBUTTON text: "mytext"
        \\   id:
        \\    literal 907
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "DEFPUSHBUTTON"
        \\  }
        \\  control_statement EDITTEXT
        \\   id:
        \\    literal 908
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "EDITTEXT"
        \\  }
        \\  control_statement HEDIT
        \\   id:
        \\    literal 9081
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "HEDIT"
        \\  }
        \\  control_statement IEDIT
        \\   id:
        \\    literal 9082
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "IEDIT"
        \\  }
        \\  control_statement GROUPBOX text: "mytext"
        \\   id:
        \\    literal 909
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "GROUPBOX"
        \\  }
        \\  control_statement ICON text: "mytext"
        \\   id:
        \\    literal 910
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "ICON"
        \\  }
        \\  control_statement LISTBOX
        \\   id:
        \\    literal 911
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "LISTBOX"
        \\  }
        \\  control_statement LTEXT text: "mytext"
        \\   id:
        \\    literal 912
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "LTEXT"
        \\  }
        \\  control_statement PUSHBOX text: "mytext"
        \\   id:
        \\    literal 913
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "PUSHBOX"
        \\  }
        \\  control_statement PUSHBUTTON text: "mytext"
        \\   id:
        \\    literal 914
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "PUSHBUTTON"
        \\  }
        \\  control_statement RADIOBUTTON text: "mytext"
        \\   id:
        \\    literal 915
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "RADIOBUTTON"
        \\  }
        \\  control_statement RTEXT text: "mytext"
        \\   id:
        \\    literal 916
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "RTEXT"
        \\  }
        \\  control_statement SCROLLBAR
        \\   id:
        \\    literal 917
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "SCROLLBAR"
        \\  }
        \\  control_statement STATE3 text: "mytext"
        \\   id:
        \\    literal 918
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "STATE3"
        \\  }
        \\  control_statement USERBUTTON text: "mytext"
        \\   id:
        \\    literal 919
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 0
        \\   exstyle:
        \\    literal 0
        \\   help_id:
        \\    literal 100
        \\  {
        \\   literal "USERBUTTON"
        \\  }
        \\ }
        \\
    );

    // help_id param is not supported if the resource is DIALOG
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected '<'}' or END>', got ','" }},
        \\1 DIALOG 1, 2, 3, 4
        \\{
        \\    AUTO3STATE,, "mytext",, 900,, 1 2 3 4, 0, 0, 100 { "AUTO3STATE" }
        \\}
    ,
        null,
    );

    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected control class [BUTTON, EDIT, etc]; got 'SOMETHING'" }},
        \\1 DIALOG 1, 2, 3, 4
        \\{
        \\    CONTROL "", 900, SOMETHING, 0, 1, 2, 3, 4
        \\}
    ,
        null,
    );
}

test "optional parameters" {
    // Optional values (like style, exstyle, helpid) can be empty
    try testParse(
        \\1 DIALOGEX 1, 2, 3, 4,
        \\{
        \\    AUTO3STATE, "text", 900,, 1 2 3 4
        \\    AUTO3STATE, "text", 901,, 1 2 3 4,
        \\    AUTO3STATE, "text", 902,, 1 2 3 4, 1
        \\    AUTO3STATE, "text", 903,, 1 2 3 4, 1,
        \\    AUTO3STATE, "text", 904,, 1 2 3 4,  ,
        \\    AUTO3STATE, "text", 905,, 1 2 3 4, 1, 2
        \\    AUTO3STATE, "text", 906,, 1 2 3 4,  , 2
        \\    AUTO3STATE, "text", 907,, 1 2 3 4, 1, 2,
        \\    AUTO3STATE, "text", 908,, 1 2 3 4, 1,  ,
        \\    AUTO3STATE, "text", 909,, 1 2 3 4,  ,  ,
        \\    AUTO3STATE, "text", 910,, 1 2 3 4, 1, 2, 3
        \\    AUTO3STATE, "text", 911,, 1 2 3 4,  , 2, 3
        \\    AUTO3STATE, "text", 912,, 1 2 3 4,  ,  , 3
        \\    AUTO3STATE, "text", 913,, 1 2 3 4,  ,  ,
        \\}
    ,
        \\root
        \\ dialog 1 DIALOGEX [0 common_resource_attributes]
        \\  x:
        \\   literal 1
        \\  y:
        \\   literal 2
        \\  width:
        \\   literal 3
        \\  height:
        \\   literal 4
        \\ {
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 900
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 901
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 902
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 1
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 903
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 1
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 904
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 905
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 1
        \\   exstyle:
        \\    literal 2
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 906
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   exstyle:
        \\    literal 2
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 907
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 1
        \\   exstyle:
        \\    literal 2
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 908
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 1
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 909
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 910
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   style:
        \\    literal 1
        \\   exstyle:
        \\    literal 2
        \\   help_id:
        \\    literal 3
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 911
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   exstyle:
        \\    literal 2
        \\   help_id:
        \\    literal 3
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 912
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\   help_id:
        \\    literal 3
        \\  control_statement AUTO3STATE text: "text"
        \\   id:
        \\    literal 913
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 2
        \\   width:
        \\    literal 3
        \\   height:
        \\    literal 4
        \\ }
        \\
    );

    // Trailing comma after help_id is not allowed
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected '<'}' or END>', got ','" }},
        \\1 DIALOGEX 1, 2, 3, 4
        \\{
        \\    AUTO3STATE,, "mytext",, 900,, 1 2 3 4, , , ,
        \\}
    ,
        null,
    );
}

test "not expressions" {
    try testParse(
        \\1 DIALOGEX 1, 2, 3, 4
        \\{
        \\  AUTOCHECKBOX "", 0, 0, 0, 0, 0, NOT 1, NOT 2, 100
        \\  CONTROL "", 0, BUTTON, NOT 1 | 2, 0, 0, 0, 0, 1 | NOT 2, 100
        \\  AUTOCHECKBOX "",1,1,1,1,1,1 | NOT ~0 | 1
        \\}
    ,
        \\root
        \\ dialog 1 DIALOGEX [0 common_resource_attributes]
        \\  x:
        \\   literal 1
        \\  y:
        \\   literal 2
        \\  width:
        \\   literal 3
        \\  height:
        \\   literal 4
        \\ {
        \\  control_statement AUTOCHECKBOX text: ""
        \\   id:
        \\    literal 0
        \\   x:
        \\    literal 0
        \\   y:
        \\    literal 0
        \\   width:
        \\    literal 0
        \\   height:
        \\    literal 0
        \\   style:
        \\    not_expression NOT 1
        \\   exstyle:
        \\    not_expression NOT 2
        \\   help_id:
        \\    literal 100
        \\  control_statement CONTROL text: ""
        \\   class:
        \\    literal BUTTON
        \\   id:
        \\    literal 0
        \\   x:
        \\    literal 0
        \\   y:
        \\    literal 0
        \\   width:
        \\    literal 0
        \\   height:
        \\    literal 0
        \\   style:
        \\    binary_expression |
        \\     not_expression NOT 1
        \\     literal 2
        \\   exstyle:
        \\    binary_expression |
        \\     literal 1
        \\     not_expression NOT 2
        \\   help_id:
        \\    literal 100
        \\  control_statement AUTOCHECKBOX text: ""
        \\   id:
        \\    literal 1
        \\   x:
        \\    literal 1
        \\   y:
        \\    literal 1
        \\   width:
        \\    literal 1
        \\   height:
        \\    literal 1
        \\   style:
        \\    binary_expression |
        \\     binary_expression |
        \\      literal 1
        \\      not_expression NOT ~0
        \\     literal 1
        \\ }
        \\
    );
}

test "menus" {
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "empty menu of type 'MENU' not allowed" }},
        "1 MENU {}",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "empty menu of type 'MENUEX' not allowed" }},
        "1 MENUEX {}",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "empty menu of type 'POPUP' not allowed" }},
        "1 MENU { MENUITEM SEPARATOR POPUP \"\" {} }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected '<'}' or END>', got 'hello'" }},
        "1 MENU { hello }",
        null,
    );
    try testParse(
        \\1 MENU FIXED VERSION 1 CHARACTERISTICS (1+2) {
        \\    MENUITEM SEPARATOR,,
        \\    MENUITEM "HELLO",, 100, CHECKED,, GRAYED,,
        \\    MENUITEM "HELLO" 100 GRAYED INACTIVE
        \\    MENUITEM L"hello" (100+2)
        \\    POPUP "hello" {
        \\        MENUITEM "goodbye", 100
        \\        POPUP "goodbye",, GRAYED CHECKED
        \\        BEGIN
        \\            POPUP "" { MENUITEM SEPARATOR }
        \\        END
        \\    }
        \\}
    ,
        \\root
        \\ menu 1 MENU [1 common_resource_attributes]
        \\  simple_statement VERSION
        \\   literal 1
        \\  simple_statement CHARACTERISTICS
        \\   grouped_expression
        \\   (
        \\    binary_expression +
        \\     literal 1
        \\     literal 2
        \\   )
        \\ {
        \\  menu_item_separator MENUITEM SEPARATOR
        \\  menu_item MENUITEM "HELLO" [2 options]
        \\   literal 100
        \\  menu_item MENUITEM "HELLO" [2 options]
        \\   literal 100
        \\  menu_item MENUITEM L"hello" [0 options]
        \\   grouped_expression
        \\   (
        \\    binary_expression +
        \\     literal 100
        \\     literal 2
        \\   )
        \\  popup POPUP "hello" [0 options]
        \\  {
        \\   menu_item MENUITEM "goodbye" [0 options]
        \\    literal 100
        \\   popup POPUP "goodbye" [2 options]
        \\   BEGIN
        \\    popup POPUP "" [0 options]
        \\    {
        \\     menu_item_separator MENUITEM SEPARATOR
        \\    }
        \\   END
        \\  }
        \\ }
        \\
    );

    try testParse(
        \\1 MENUEX FIXED 1000 VERSION 1 CHARACTERISTICS (1+2) {
        \\    MENUITEM "", -1, 0x00000800L
        \\    MENUITEM ""
        \\    MENUITEM "hello",,,,
        \\    MENUITEM "hello",,,1,
        \\    POPUP "hello",,,,, {
        \\        POPUP "goodbye",,,,3,
        \\        BEGIN
        \\            POPUP "" { MENUITEM "" }
        \\        END
        \\    }
        \\    POPUP "blah", , , {
        \\        MENUITEM "blah", , ,
        \\    }
        \\}
    ,
        \\root
        \\ menu 1 MENUEX [1 common_resource_attributes]
        \\  simple_statement VERSION
        \\   literal 1
        \\  simple_statement CHARACTERISTICS
        \\   grouped_expression
        \\   (
        \\    binary_expression +
        \\     literal 1
        \\     literal 2
        \\   )
        \\  help_id:
        \\   literal 1000
        \\ {
        \\  menu_item_ex MENUITEM ""
        \\   id:
        \\    literal -1
        \\   type:
        \\    literal 0x00000800L
        \\  menu_item_ex MENUITEM ""
        \\  menu_item_ex MENUITEM "hello"
        \\  menu_item_ex MENUITEM "hello"
        \\   state:
        \\    literal 1
        \\  popup_ex POPUP "hello"
        \\  {
        \\   popup_ex POPUP "goodbye"
        \\    help_id:
        \\     literal 3
        \\   BEGIN
        \\    popup_ex POPUP ""
        \\    {
        \\     menu_item_ex MENUITEM ""
        \\    }
        \\   END
        \\  }
        \\  popup_ex POPUP "blah"
        \\  {
        \\   menu_item_ex MENUITEM "blah"
        \\  }
        \\ }
        \\
    );
}

test "versioninfo" {
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected '<'{' or BEGIN>', got ','" }},
        \\1 VERSIONINFO PRODUCTVERSION 1,2,3,4,5 {}
    ,
        null,
    );
    try testParseErrorDetails(
        &.{
            .{ .type = .warning, .str = "the padding before this quoted string value would be miscompiled by the Win32 RC compiler" },
            .{ .type = .note, .str = "to avoid the potential miscompilation, consider adding a comma between the key and the quoted string" },
        },
        \\1 VERSIONINFO { VALUE "key" "value" }
    ,
        null,
    );
    try testParseErrorDetails(
        &.{
            .{ .type = .warning, .str = "the byte count of this value would be miscompiled by the Win32 RC compiler" },
            .{ .type = .note, .str = "to avoid the potential miscompilation, do not mix numbers and strings within a value" },
        },
        \\1 VERSIONINFO { VALUE "key", "value" 1 }
    ,
        null,
    );
    try testParse(
        \\1 VERSIONINFO FIXED
        \\FILEVERSION 1
        \\PRODUCTVERSION 1,3-1,3,4
        \\FILEFLAGSMASK 1
        \\FILEFLAGS (1|2)
        \\FILEOS 2
        \\FILETYPE 3
        \\FILESUBTYPE 4
        \\{
        \\  VALUE "hello"
        \\  BLOCK "something",,
        \\  BEGIN
        \\      BLOCK "something else",, 1,, 2
        \\      BEGIN
        \\          VALUE "key",,
        \\          VALUE "key",, 1,, 2,, 3,,
        \\          VALUE "key" 1 2 3 "4"
        \\      END
        \\  END
        \\}
    ,
        \\root
        \\ version_info 1 VERSIONINFO [1 common_resource_attributes]
        \\  version_statement FILEVERSION
        \\   literal 1
        \\  version_statement PRODUCTVERSION
        \\   literal 1
        \\   binary_expression -
        \\    literal 3
        \\    literal 1
        \\   literal 3
        \\   literal 4
        \\  simple_statement FILEFLAGSMASK
        \\   literal 1
        \\  simple_statement FILEFLAGS
        \\   grouped_expression
        \\   (
        \\    binary_expression |
        \\     literal 1
        \\     literal 2
        \\   )
        \\  simple_statement FILEOS
        \\   literal 2
        \\  simple_statement FILETYPE
        \\   literal 3
        \\  simple_statement FILESUBTYPE
        \\   literal 4
        \\ {
        \\  block_value VALUE "hello"
        \\  block BLOCK "something"
        \\  BEGIN
        \\   block BLOCK "something else"
        \\    block_value_value ,
        \\     literal 1
        \\    block_value_value
        \\     literal 2
        \\   BEGIN
        \\    block_value VALUE "key"
        \\    block_value VALUE "key"
        \\     block_value_value ,
        \\      literal 1
        \\     block_value_value ,
        \\      literal 2
        \\     block_value_value ,
        \\      literal 3
        \\    block_value VALUE "key"
        \\     block_value_value
        \\      literal 1
        \\     block_value_value
        \\      literal 2
        \\     block_value_value
        \\      literal 3
        \\     block_value_value
        \\      literal "4"
        \\   END
        \\  END
        \\ }
        \\
    );
}

test "dangling id at end of file" {
    try testParse(
        \\1 RCDATA {}
        \\END
        \\
    ,
        \\root
        \\ resource_raw_data 1 RCDATA [0 common_resource_attributes] raw data: 0
        \\ invalid context.len: 2
        \\  literal:END
        \\  eof:
        \\
    );
}

test "dlginclude" {
    try testParse(
        \\1 DLGINCLUDE "something.h"
        \\2 DLGINCLUDE FIXED L"Something.h"
    ,
        \\root
        \\ resource_external 1 DLGINCLUDE [0 common_resource_attributes]
        \\  literal "something.h"
        \\ resource_external 2 DLGINCLUDE [1 common_resource_attributes]
        \\  literal L"Something.h"
        \\
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected quoted string literal; got 'something.h'" }},
        "1 DLGINCLUDE something.h",
        null,
    );
}

test "toolbar" {
    try testParse(
        \\1 TOOLBAR DISCARDABLE 16, 15
        \\BEGIN
        \\  BUTTON 1
        \\  SEPARATOR
        \\  BUTTON 2
        \\END
    ,
        \\root
        \\ toolbar 1 TOOLBAR [1 common_resource_attributes]
        \\  button_width:
        \\   literal 16
        \\  button_height:
        \\   literal 15
        \\ BEGIN
        \\  simple_statement BUTTON
        \\   literal 1
        \\  literal SEPARATOR
        \\  simple_statement BUTTON
        \\   literal 2
        \\ END
        \\
    );
}

test "semicolons" {
    try testParse(
        \\STRINGTABLE
        \\BEGIN
        \\  512; this is all ignored
        \\  "what"
        \\END
        \\1; RC;DATA {
        \\  1;100
        \\  2
        \\}
        \\; This is basically a comment
        \\
    ,
        \\root
        \\ string_table STRINGTABLE [0 common_resource_attributes]
        \\ BEGIN
        \\  string_table_string
        \\   literal 512
        \\   "what"
        \\ END
        \\ resource_raw_data 1; RC;DATA [0 common_resource_attributes] raw data: 2
        \\  literal 1
        \\  literal 2
        \\
    );
}

test "parse errors" {
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "unfinished raw data block at '<eof>', expected closing '}' or 'END'" }},
        "id RCDATA { 1",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "unfinished string literal at '<eof>', expected closing '\"'" }},
        "id RCDATA \"unfinished string",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected ')', got '}'" }},
        "id RCDATA { (1 }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "character '\\x1A' is not allowed" }},
        "id RCDATA { \"\x1A\" }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "character '\\x01' is not allowed outside of string literals" }},
        "id RCDATA { \x01 }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "character '@' is not allowed outside of string literals" }},
        // This @ is outside the string literal from the perspective of a C preprocessor
        // but inside the string literal from the perspective of the RC parser. We still
        // want to error to emulate the behavior of the Win32 RC preprocessor.
        "id RCDATA { \"hello\n@\" }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "escaping quotes with \\\" is not allowed (use \"\" instead)" }},
        "id RCDATA { \"\\\"\"\" }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected number or number expression; got '\"hello\"'" }},
        "STRINGTABLE { \"hello\" }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected quoted string literal; got '1'" }},
        "STRINGTABLE { 1, 1 }",
        null,
    );
    try testParseErrorDetails(
        &.{
            .{ .type = .err, .str = "expected '<filename>', found '{' (resource type 'icon' can't use raw data)" },
            .{ .type = .note, .str = "if '{' is intended to be a filename, it must be specified as a quoted string literal" },
        },
        "1 ICON {}",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "id of resource type 'font' must be an ordinal (u16), got 'string'" }},
        "string FONT filename",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected accelerator type or option [ASCII, VIRTKEY, etc]; got 'NOTANOPTIONORTYPE'" }},
        "1 ACCELERATORS { 1, 1, NOTANOPTIONORTYPE",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected number, number expression, or quoted string literal; got 'hello'" }},
        "1 ACCELERATORS { hello, 1 }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "expected number or number expression; got '\"hello\"'" }},
        "1 ACCELERATORS { 1, \"hello\" }",
        null,
    );
    try testParseErrorDetails(
        &.{
            .{ .type = .err, .str = "the number 6 (RT_STRING) cannot be used as a resource type" },
            .{ .type = .note, .str = "using RT_STRING directly likely results in an invalid .res file, use a STRINGTABLE instead" },
        },
        "1 6 {}",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "name or id is not allowed for resource type 'stringtable'" }},
        "1 STRINGTABLE { 1 \"\" }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "unsupported code page 'utf7 (id=65000)' in #pragma code_page" }},
        "#pragma code_page( 65000 )",
        null,
    );
    try testParseErrorDetails(
        &.{
            .{ .type = .err, .str = "expected quoted string literal or unquoted literal; got ')'" },
            .{ .type = .note, .str = "the Win32 RC compiler would accept ')' as a valid expression, but it would be skipped over and potentially lead to unexpected outcomes" },
        },
        "1 RCDATA )",
        null,
    );
    try testParseErrorDetails(
        &.{
            .{ .type = .err, .str = "expected number, number expression, or quoted string literal; got ')'" },
            .{ .type = .note, .str = "the Win32 RC compiler would accept ')' as a valid expression, but it would be skipped over and potentially lead to unexpected outcomes" },
        },
        "1 RCDATA { 1, ), 2 }",
        null,
    );
}

test "max nested menu level" {
    var source_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer source_buffer.deinit();

    try source_buffer.appendSlice("1 MENU {\n");
    for (0..max_nested_menu_level) |_| {
        try source_buffer.appendSlice("POPUP \"foo\" {\n");
    }
    for (0..max_nested_menu_level) |_| {
        try source_buffer.appendSlice("}\n");
    }
    try source_buffer.appendSlice("}");

    // Exactly hitting the nesting level is okay, but we still error
    // because the innermost nested POPUP is empty.
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "empty menu of type 'POPUP' not allowed" }},
        source_buffer.items,
        null,
    );

    // Now reset and nest until the nesting level is 1 more than the max
    source_buffer.clearRetainingCapacity();
    try source_buffer.appendSlice("1 MENU {\n");
    for (0..max_nested_menu_level + 1) |_| {
        try source_buffer.appendSlice("POPUP \"foo\" {\n");
    }
    for (0..max_nested_menu_level + 1) |_| {
        try source_buffer.appendSlice("}\n");
    }
    try source_buffer.appendSlice("}");

    // Now we should get the nesting level error.
    try testParseErrorDetails(
        &.{
            .{ .type = .err, .str = "menu contains too many nested children (max is 512)" },
            .{ .type = .note, .str = "max menu nesting level exceeded here" },
        },
        source_buffer.items,
        null,
    );
}

test "max nested versioninfo level" {
    var source_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer source_buffer.deinit();

    try source_buffer.appendSlice("1 VERSIONINFO {\n");
    for (0..max_nested_version_level) |_| {
        try source_buffer.appendSlice("BLOCK \"foo\" {\n");
    }
    for (0..max_nested_version_level) |_| {
        try source_buffer.appendSlice("}\n");
    }
    try source_buffer.appendSlice("}");

    // This should succeed, but we don't care about validating the tree since it's
    // just giant nested nonsense.
    try testParseErrorDetails(
        &.{},
        source_buffer.items,
        null,
    );

    // Now reset and nest until the nesting level is 1 more than the max
    source_buffer.clearRetainingCapacity();
    try source_buffer.appendSlice("1 VERSIONINFO {\n");
    for (0..max_nested_version_level + 1) |_| {
        try source_buffer.appendSlice("BLOCK \"foo\" {\n");
    }
    for (0..max_nested_version_level + 1) |_| {
        try source_buffer.appendSlice("}\n");
    }
    try source_buffer.appendSlice("}");

    // Now we should get the nesting level error.
    try testParseErrorDetails(
        &.{
            .{ .type = .err, .str = "versioninfo contains too many nested children (max is 512)" },
            .{ .type = .note, .str = "max versioninfo nesting level exceeded here" },
        },
        source_buffer.items,
        null,
    );
}

test "max dialog controls" {
    var source_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer source_buffer.deinit();

    const max_controls = std.math.maxInt(u16);

    try source_buffer.appendSlice("1 DIALOGEX 1, 2, 3, 4 {\n");
    for (0..max_controls) |_| {
        try source_buffer.appendSlice("CHECKBOX \"foo\", 1, 2, 3, 4, 5\n");
    }
    try source_buffer.appendSlice("}");

    // This should succeed, but we don't care about validating the tree since it's
    // just a dialog with a giant list of controls.
    try testParseErrorDetails(
        &.{},
        source_buffer.items,
        null,
    );

    // Now reset and add 1 more than the max number of controls.
    source_buffer.clearRetainingCapacity();
    try source_buffer.appendSlice("1 DIALOGEX 1, 2, 3, 4 {\n");
    for (0..max_controls + 1) |_| {
        try source_buffer.appendSlice("CHECKBOX \"foo\", 1, 2, 3, 4, 5\n");
    }
    try source_buffer.appendSlice("}");

    // Now we should get the 'too many controls' error.
    try testParseErrorDetails(
        &.{
            .{ .type = .err, .str = "dialogex contains too many controls (max is 65535)" },
            .{ .type = .note, .str = "maximum number of controls exceeded here" },
        },
        source_buffer.items,
        null,
    );
}

test "max expression level" {
    var source_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer source_buffer.deinit();

    try source_buffer.appendSlice("1 RCDATA {\n");
    for (0..max_nested_expression_level) |_| {
        try source_buffer.appendSlice("(\n");
    }
    try source_buffer.append('1');
    for (0..max_nested_expression_level) |_| {
        try source_buffer.appendSlice(")\n");
    }
    try source_buffer.appendSlice("}");

    // This should succeed, but we don't care about validating the tree since it's
    // just a raw data block with a 1 surrounded by a bunch of parens
    try testParseErrorDetails(
        &.{},
        source_buffer.items,
        null,
    );

    // Now reset and add 1 more than the max expression level.
    source_buffer.clearRetainingCapacity();
    try source_buffer.appendSlice("1 RCDATA {\n");
    for (0..max_nested_expression_level + 1) |_| {
        try source_buffer.appendSlice("(\n");
    }
    try source_buffer.append('1');
    for (0..max_nested_expression_level + 1) |_| {
        try source_buffer.appendSlice(")\n");
    }
    try source_buffer.appendSlice("}");

    // Now we should get the 'too many controls' error.
    try testParseErrorDetails(
        &.{
            .{ .type = .err, .str = "expression contains too many syntax levels (max is 200)" },
            .{ .type = .note, .str = "maximum expression level exceeded here" },
        },
        source_buffer.items,
        null,
    );
}

test "code page pragma" {
    try testParseErrorDetails(
        &.{},
        "#pragma code_page(1252)",
        null,
    );
    try testParseErrorDetails(
        &.{},
        "#pragma code_page(DEFAULT)",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "invalid or unknown code page in #pragma code_page" }},
        "#pragma code_page(12)",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "unsupported code page 'utf7 (id=65000)' in #pragma code_page" }},
        "#pragma code_page(65000)",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "code page is not a valid integer in #pragma code_page" }},
        "#pragma code_page(0)",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "code page is not a valid integer in #pragma code_page" }},
        "#pragma code_page(00)",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "code page is not a valid integer in #pragma code_page" }},
        "#pragma code_page(123abc)",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "invalid or unknown code page in #pragma code_page" }},
        "#pragma code_page(01252)",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "code page too large in #pragma code_page" }},
        "#pragma code_page(4294967333)",
        null,
    );
}

test "numbers with exponents" {
    // Compatibility with error RC2021: expected exponent value, not '1'
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "base 10 number literal with exponent is not allowed: -002e6" }},
        "1 RCDATA { -002e645 }",
        null,
    );
    try testParseErrorDetails(
        &.{.{ .type = .err, .str = "base 10 number literal with exponent is not allowed: ~2E1" }},
        "1 RCDATA { ~2E1 }",
        null,
    );
    try testParseErrorDetails(
        &.{},
        "1 RCDATA { 0x2e1 }",
        null,
    );
    try testParseErrorDetails(
        &.{},
        "1 RCDATA { 2eA }",
        null,
    );
    try testParseErrorDetails(
        &.{},
        "1 RCDATA { -002ea }",
        null,
    );
    try testParseErrorDetails(
        &.{},
        "1 RCDATA { -002e }",
        null,
    );
}

test "unary plus" {
    try testParseErrorDetails(
        &.{
            .{ .type = .err, .str = "expected number, number expression, or quoted string literal; got '+'" },
            .{ .type = .note, .str = "the Win32 RC compiler may accept '+' as a unary operator here, but it is not supported in this implementation; consider omitting the unary +" },
        },
        "1 RCDATA { +2 }",
        null,
    );
}

test "control style potential miscompilation" {
    try testParseErrorDetails(
        &.{
            .{ .type = .warning, .str = "this token could be erroneously skipped over by the Win32 RC compiler" },
            .{ .type = .note, .str = "to avoid the potential miscompilation, consider adding a comma after the style parameter" },
        },
        "1 DIALOGEX 1, 2, 3, 4 { CONTROL \"text\", 100, BUTTON, 3 1, 2, 3, 4, 100 }",
        null,
    );
}

test "language with L suffixed part" {
    // As a top-level statement
    try testParseErrorDetails(
        &.{
            .{ .type = .warning, .str = "this language parameter would be an error in the Win32 RC compiler" },
            .{ .type = .note, .str = "to avoid the error, remove any L suffixes from numbers within the parameter" },
        },
        \\LANGUAGE 1L, 2
    ,
        null,
    );
    // As an optional statement in a resource
    try testParseErrorDetails(
        &.{
            .{ .type = .warning, .str = "this language parameter would be an error in the Win32 RC compiler" },
            .{ .type = .note, .str = "to avoid the error, remove any L suffixes from numbers within the parameter" },
        },
        \\STRINGTABLE LANGUAGE (2-1L), 1 { 1, "" }
    ,
        null,
    );
}

const ExpectedErrorDetails = struct {
    str: []const u8,
    type: ErrorDetails.Type,
};

fn testParseErrorDetails(expected_details: []const ExpectedErrorDetails, source: []const u8, maybe_expected_output: ?[]const u8) !void {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();

    const expect_fail = for (expected_details) |details| {
        if (details.type == .err) break true;
    } else false;

    const tree: ?*Tree = tree: {
        var lexer = Lexer.init(source, .{});
        var parser = Parser.init(&lexer, .{});
        var tree = parser.parse(allocator, &diagnostics) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseError => {
                if (!expect_fail) {
                    diagnostics.renderToStdErrDetectTTY(std.fs.cwd(), source, null);
                    return err;
                }
                break :tree null;
            },
        };
        break :tree tree;
    };
    defer if (tree != null) tree.?.deinit();

    if (tree != null and expect_fail) {
        std.debug.print("expected parse error, got tree:\n", .{});
        try tree.?.dump(std.io.getStdErr().writer());
        return error.UnexpectedSuccess;
    }

    if (expected_details.len != diagnostics.errors.items.len) {
        std.debug.print("expected {} error details, got {}:\n", .{ expected_details.len, diagnostics.errors.items.len });
        diagnostics.renderToStdErrDetectTTY(std.fs.cwd(), source, null);
        return error.ErrorDetailMismatch;
    }
    for (diagnostics.errors.items, expected_details) |actual, expected| {
        std.testing.expectEqual(expected.type, actual.type) catch |e| {
            diagnostics.renderToStdErrDetectTTY(std.fs.cwd(), source, null);
            return e;
        };
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try actual.render(fbs.writer(), source, diagnostics.strings.items);
        try std.testing.expectEqualStrings(expected.str, fbs.getWritten());
    }

    if (maybe_expected_output) |expected_output| {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try tree.?.dump(buf.writer());
        try std.testing.expectEqualStrings(expected_output, buf.items);
    }
}
