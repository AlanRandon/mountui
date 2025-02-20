const std = @import("std");
const mibu = @import("mibu");
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
    size: mibu.term.TermSize,
};

fn render(state: *const State, out: anytype) !void {
    try mibu.clear.all(out);
    try mibu.cursor.goTo(out, 0, 0);

    try out.print("{[title]s:^[width]}\n\n\r", .{
        .title = "Mountui",
        .width = state.size.width,
    });

    if (state.filesystems.len == 0) {
        try out.print("No devices found!\n\r", .{});
    }

    for (state.filesystems, 0..) |fs, i| {
        var name = c.udisks_block_get_hint_name(fs.block);
        if (name[0] == 0) {
            name = c.udisks_block_get_preferred_device(fs.block);
        }

        if (i == state.selected_index) {
            try mibu.style.reverse(out);
        }

        try out.print("{s} ({s} {s})\n\r", .{
            name,
            c.udisks_drive_get_vendor(fs.drive),
            c.udisks_drive_get_model(fs.drive),
        });

        try mibu.style.noReverse(out);

        const mount_points = c.udisks_filesystem_get_mount_points(fs.filesystem);
        var mount_index: usize = 0;
        while (mount_points[mount_index]) |point| : (mount_index += 1) {
            try out.print("\t@ {s}\n\r", .{point});
        }
    }

    try mibu.cursor.goDown(out, 1000);
    try out.print("Down/Up: {0s}j/k{1s} Rescan: {0s}r{1s} Mount/Unmount: {0s}m/u{1s} Quit: {0s}q{1s}", .{ mibu.style.print.bold, mibu.style.print.no_bold });
}

pub fn main() !void {
    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();

    var raw_term = try mibu.term.enableRawMode(stdin.handle);
    defer raw_term.disableRawMode() catch {};

    try mibu.term.enterAlternateScreen(stdout.writer());
    defer mibu.term.exitAlternateScreen(stdout.writer()) catch {};

    try mibu.cursor.hide(stdout.writer());
    defer mibu.cursor.show(stdout.writer()) catch {};

    const allocator = std.heap.c_allocator;
    const client: *c.UDisksClient = c.udisks_client_new_sync(null, null) orelse return error.CreateClient;
    defer c.g_object_unref(client);

    var state = State{
        .filesystems = try Filesystem.find(client, allocator),
        .selected_index = 0,
        .size = try mibu.term.getSize(stdin.handle),
    };
    defer allocator.free(state.filesystems);

    try render(&state, stdout.writer());

    while (true) {
        const event = try mibu.events.next(stdin.reader());
        // Event.resize does not actually exist (yet?)
        state.size = try mibu.term.getSize(stdin.handle);
        switch (event) {
            .key => |key| switch (key) {
                .char => |char| switch (char) {
                    'r' => {
                        c.udisks_client_settle(client);
                        allocator.free(state.filesystems);
                        state.filesystems = try Filesystem.find(client, allocator);
                        state.selected_index = @min(state.selected_index, state.filesystems.len -| 1);
                        try render(&state, stdout.writer());
                    },
                    'j' => {
                        state.selected_index = @min(state.selected_index + 1, state.filesystems.len -| 1);
                        try render(&state, stdout.writer());
                    },
                    'k' => {
                        state.selected_index -|= 1;
                        try render(&state, stdout.writer());
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
                        try render(&state, stdout.writer());
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
                        try render(&state, stdout.writer());
                    },
                    'q' => break,
                    else => {},
                },
                else => {},
            },
            else => {},
        }
    }
}
