const std = @import("std");
const resinator = @import("resinator");

pub const log_level: std.log.Level = .warn;

pub export fn main() void {
    zigMain() catch unreachable;
}

pub fn zigMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const stdin = std.io.getStdIn();
    var data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    const dummy_filename = "fuzz.rc";

    var mapping_results = try resinator.source_mapping.parseAndRemoveLineCommands(allocator, data, data, .{ .initial_filename = dummy_filename });
    defer mapping_results.mappings.deinit(allocator);

    var final_input = resinator.comments.removeComments(mapping_results.result, mapping_results.result, &mapping_results.mappings);

    var diagnostics = resinator.errors.Diagnostics.init(allocator);
    defer diagnostics.deinit();

    var output_buf = std.ArrayList(u8).init(allocator);
    defer output_buf.deinit();

    // TODO: Better seed, maybe taking the first few bytes and interpretting as u64
    const prng_seed = data.len;
    var prng = std.rand.DefaultPrng.init(prng_seed);
    const rand = prng.random();

    const stderr_config = std.io.tty.detectConfig(std.io.getStdErr());

    resinator.compile.compile(allocator, final_input, output_buf.writer(), .{
        .cwd = std.fs.cwd(),
        .diagnostics = &diagnostics,
        .source_mappings = &mapping_results.mappings,
        .ignore_include_env_var = true,
        .default_language_id = rand.int(u16),
        .default_code_page = if (rand.boolean()) .utf8 else .windows1252,
        .null_terminate_string_table_strings = rand.boolean(),
        .max_string_literal_codepoints = rand.int(u15),
        .warn_instead_of_error_on_invalid_code_page = rand.boolean(),
    }) catch |err| switch (err) {
        error.ParseError, error.CompileError => {
            diagnostics.renderToStdErr(std.fs.cwd(), final_input, stderr_config, mapping_results.mappings);
            return;
        },
        else => |e| return e,
    };

    // print any warnings/notes
    diagnostics.renderToStdErr(std.fs.cwd(), final_input, stderr_config, mapping_results.mappings);
}
