const std = @import("std");
const RawTerm = @import("RawTerm");
const ansi = RawTerm.ansi;
const c = @import("./c.zig");
const Allocator = std.mem.Allocator;

const Filesystem = struct {
    filesystem: *c.UDisksFilesystem,
    block: *c.UDisksBlock,
    drive: *c.UDisksDrive,

    pub fn find(client: *c.UDisksClient, allocator: Allocator) ![]const Filesystem {
        const objects = c.g_dbus_object_manager_get_objects(c.udisks_client_get_object_manager(client));

        var filesystems = std.ArrayList(Filesystem).init(allocator);
        errdefer filesystems.deinit();

        var current_block_object = objects;
        while (current_block_object != null) : (current_block_object = current_block_object[0].next) {
            const object: *c.UDisksObject = @ptrCast(current_block_object[0].data);
            const block = c.udisks_object_peek_block(object) orelse continue;
            if (c.udisks_block_get_hint_ignore(block) == 1) {
                continue;
            }

            if (c.udisks_block_get_hint_system(block) == 1) {
                continue;
            }

            const drive = c.udisks_client_get_drive_for_block(client, block) orelse continue;
            if (c.udisks_drive_get_removable(drive) != 1) {
                continue;
            }

            if (c.udisks_object_peek_filesystem(object)) |fs| {
                try filesystems.append(.{ .block = block, .drive = drive, .filesystem = fs });
            }
        }

        return filesystems.toOwnedSlice();
    }
};

const State = struct {
    filesystems: []const Filesystem,
    selected_index: usize,
    size: RawTerm.Size,
};

fn render(state: *const State, raw_term: *RawTerm) !void {
    try raw_term.out.writeAll(ansi.clear.screen ++ ansi.cursor.goto_top_left);

    try raw_term.out.writer().print("{[title]s:^[width]}\n\n\r", .{
        .title = "Mountui",
        .width = state.size.width,
    });

    if (state.filesystems.len == 0) {
        try raw_term.out.writer().print("No devices found!\n\r", .{});
    }

    for (state.filesystems, 0..) |fs, i| {
        var name = c.udisks_block_get_hint_name(fs.block);
        if (name[0] == 0) {
            name = c.udisks_block_get_preferred_device(fs.block);
        }

        if (i == state.selected_index) {
            try raw_term.out.writeAll(ansi.style.reverse.enable);
        }

        try raw_term.out.writer().print("{s} ({s} {s})\n\r", .{
            name,
            c.udisks_drive_get_vendor(fs.drive),
            c.udisks_drive_get_model(fs.drive),
        });

        try raw_term.out.writeAll(ansi.style.reverse.disable);

        const mount_points = c.udisks_filesystem_get_mount_points(fs.filesystem);
        var mount_index: usize = 0;
        while (mount_points[mount_index]) |point| : (mount_index += 1) {
            try raw_term.out.writer().print("\t@ {s}\n\r", .{point});
        }
    }

    try raw_term.out.writeAll("\x1b[1000B");
    try raw_term.out.writer().print("Down/Up: {0s}j/k{1s} Rescan: {0s}r{1s} Mount/Unmount: {0s}m/u{1s} Quit: {0s}q{1s}", .{ ansi.style.bold.enable, ansi.style.bold.disable });
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var raw_term = try RawTerm.enable(std.io.getStdIn(), std.io.getStdOut(), false);
    defer raw_term.disable() catch {};

    var listener = try raw_term.eventListener(allocator);
    defer listener.deinit();

    try raw_term.out.writeAll(ansi.alternate_screen.enable ++ ansi.cursor.hide);
    defer raw_term.out.writeAll(ansi.alternate_screen.disable ++ ansi.cursor.show) catch {};

    const client: *c.UDisksClient = c.udisks_client_new_sync(null, null) orelse return error.CreateClient;
    defer c.g_object_unref(client);

    var state = State{
        .filesystems = try Filesystem.find(client, allocator),
        .selected_index = 0,
        .size = try raw_term.size(),
    };
    defer allocator.free(state.filesystems);

    try render(&state, &raw_term);

    while (true) {
        const event = try listener.queue.wait();
        switch (event) {
            .resize => {
                state.size = try raw_term.size();
                try render(&state, &raw_term);
            },
            .char => |char| switch (char.value) {
                'r' => {
                    c.udisks_client_settle(client);
                    allocator.free(state.filesystems);
                    state.filesystems = try Filesystem.find(client, allocator);
                    state.selected_index = @min(state.selected_index, state.filesystems.len -| 1);
                    try render(&state, &raw_term);
                },
                'j' => {
                    state.selected_index = @min(state.selected_index + 1, state.filesystems.len -| 1);
                    try render(&state, &raw_term);
                },
                'k' => {
                    state.selected_index -|= 1;
                    try render(&state, &raw_term);
                },
                'm' => if (state.filesystems.len != 0) {
                    const fs = state.filesystems[state.selected_index];
                    _ = c.udisks_filesystem_call_mount_sync(
                        fs.filesystem,
                        c.g_variant_new_array(c.g_variant_type_checked_("{sv}"), null, 0),
                        null,
                        null,
                        null,
                    );

                    c.udisks_client_settle(client);
                    allocator.free(state.filesystems);
                    state.filesystems = try Filesystem.find(client, allocator);
                    try render(&state, &raw_term);
                },
                'u' => if (state.filesystems.len != 0) {
                    const fs = state.filesystems[state.selected_index];
                    _ = c.udisks_filesystem_call_unmount_sync(
                        fs.filesystem,
                        c.g_variant_new_array(c.g_variant_type_checked_("{sv}"), null, 0),
                        null,
                        null,
                    );

                    c.udisks_client_settle(client);
                    allocator.free(state.filesystems);
                    state.filesystems = try Filesystem.find(client, allocator);
                    try render(&state, &raw_term);
                },
                'q' => break,
                else => {},
            },
            else => {},
        }
    }
}
