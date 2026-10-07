//! Program Status Protocol (OSC 7501) reports for the interactive shell.
//!
//! fx tells the terminal whether it is idle, working, waiting on the user,
//! finished, or failed. Terminals that do not implement the protocol ignore
//! the sequence, so reports need no feature detection. Specification:
//! https://www.superlogical.com/rex/docs/build/program-status

const std = @import("std");
const text_utils = @import("../../core/shared/text_utils.zig");
const types = @import("../../core/shared/types.zig");

/// Removes every record fx reported. Written when fx exits or suspends.
pub const clear_sequence = prefix ++ "state=clear" ++ terminator;

const prefix = "\x1b]7501;";
const terminator = "\x1b\\";
const app_name = "fx";
/// Keeps `msg` to one short line. The protocol allows 2048 decoded bytes.
const max_message_bytes = 256;
const base64 = std.base64.standard.Encoder;
const max_report_bytes = prefix.len +
    "state=blocked:kind=permission:app=".len + app_name.len + ":msg=".len +
    base64.calcSize(max_message_bytes) + terminator.len;

pub const BlockedKind = enum { permission, question };

pub const Activity = union(enum) {
    /// Waiting on the user. `message` borrows untrusted text for this call
    /// and is reduced to one line without control characters before encoding.
    blocked: struct { kind: BlockedKind, message: []const u8 },
    working,
    /// Nothing is running; the last finished turn decides what to report.
    settled,
};

const Settled = enum { idle, done, @"error" };

/// Owned by the UI thread. Keeps the last report so unchanged activity is
/// not written to the terminal again on every loop iteration.
pub const Reporter = struct {
    settled: Settled = .idle,
    last: [max_report_bytes]u8 = undefined,
    last_len: usize = 0,

    /// A new turn must not report an earlier turn's result once it settles.
    pub fn noteTurnStarted(self: *Reporter) void {
        self.settled = .idle;
    }

    pub fn noteTurnFinished(self: *Reporter, outcome: types.TurnPresentationOutcome) void {
        self.settled = switch (outcome) {
            .completed => .done,
            // A paused turn stopped after its provider retries ran out.
            .failed, .paused => .@"error",
            // The protocol reports a cancelled program as idle.
            .interrupted => .idle,
        };
    }

    /// Records a request failure that ended without a turn outcome.
    pub fn noteFailure(self: *Reporter) void {
        self.settled = .@"error";
    }

    /// Sends the next report even when it matches the last one, for example
    /// after the terminal dropped fx's record while fx was suspended.
    pub fn invalidate(self: *Reporter) void {
        self.last_len = 0;
    }

    /// Returns the report to write when it differs from the last one. The
    /// slice borrows `self` until the next call.
    pub fn update(self: *Reporter, activity: Activity) ?[]const u8 {
        var buffer: [max_report_bytes]u8 = undefined;
        const report = encode(&buffer, activity, self.settled);
        if (std.mem.eql(u8, self.last[0..self.last_len], report)) return null;
        @memcpy(self.last[0..report.len], report);
        self.last_len = report.len;
        return self.last[0..self.last_len];
    }
};

fn encode(buffer: *[max_report_bytes]u8, activity: Activity, settled: Settled) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    // `max_report_bytes` covers the longest kind and a full message.
    writeReport(&writer, activity, settled) catch unreachable;
    return writer.buffered();
}

fn writeReport(w: *std.Io.Writer, activity: Activity, settled: Settled) std.Io.Writer.Error!void {
    try w.writeAll(prefix ++ "state=");
    switch (activity) {
        .blocked => |blocked| try w.print("blocked:kind={s}", .{@tagName(blocked.kind)}),
        .working => try w.writeAll("working"),
        .settled => try w.writeAll(@tagName(settled)),
    }
    // Each report replaces its record, so every report repeats `app`.
    try w.writeAll(":app=" ++ app_name);
    if (activity == .blocked) {
        var message_buffer: [max_message_bytes]u8 = undefined;
        const message = oneLineMessage(activity.blocked.message, &message_buffer);
        if (message.len > 0) {
            var encoded: [base64.calcSize(max_message_bytes)]u8 = undefined;
            try w.writeAll(":msg=");
            try w.writeAll(base64.encode(&encoded, message));
        }
    }
    try w.writeAll(terminator);
}

/// Terminals discard a report whose message contains a control character, so
/// whitespace and control runs collapse to one space and invalid UTF-8 is
/// dropped. Long text ends with "..." within `max_message_bytes`.
fn oneLineMessage(raw: []const u8, buffer: *[max_message_bytes]u8) []const u8 {
    const marker = "...";
    var written: usize = 0;
    var space_pending = false;
    var index: usize = 0;
    while (index < raw.len) {
        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(raw[index]) catch {
            index += 1;
            continue;
        };
        if (raw.len - index < sequence_len) break;
        const sequence = raw[index .. index + sequence_len];
        const codepoint = std.unicode.utf8Decode(sequence) catch {
            index += 1;
            continue;
        };
        index += sequence_len;
        if (codepoint <= ' ' or (codepoint >= 0x7f and codepoint <= 0x9f)) {
            space_pending = written > 0;
            continue;
        }
        const separator_len: usize = @intFromBool(space_pending);
        if (written + separator_len + sequence_len > buffer.len) {
            written = text_utils.utf8BackwardBoundary(buffer[0..written], buffer.len - marker.len);
            @memcpy(buffer[written .. written + marker.len], marker);
            written += marker.len;
            break;
        }
        if (space_pending) {
            buffer[written] = ' ';
            written += 1;
            space_pending = false;
        }
        @memcpy(buffer[written .. written + sequence_len], sequence);
        written += sequence_len;
    }
    return buffer[0..written];
}

fn expectReport(reporter: *Reporter, activity: Activity, expected: []const u8) !void {
    const report = reporter.update(activity) orelse return error.TestExpectedReport;
    try std.testing.expectEqualStrings(expected, report);
}

fn decodedMessage(report: []const u8, buffer: []u8) ![]const u8 {
    const start = (std.mem.find(u8, report, ":msg=") orelse return error.TestExpectedMessage) + ":msg=".len;
    const encoded = report[start .. report.len - terminator.len];
    const decoder = std.base64.standard.Decoder;
    const len = try decoder.calcSizeForSlice(encoded);
    try decoder.decode(buffer[0..len], encoded);
    return buffer[0..len];
}

test "program status follows a turn from idle to its outcome" {
    var reporter = Reporter{};
    try expectReport(&reporter, .settled, "\x1b]7501;state=idle:app=fx\x1b\\");
    reporter.noteTurnStarted();
    try expectReport(&reporter, .working, "\x1b]7501;state=working:app=fx\x1b\\");
    try expectReport(
        &reporter,
        .{ .blocked = .{ .kind = .permission, .message = "shell.run git push" } },
        "\x1b]7501;state=blocked:kind=permission:app=fx:msg=c2hlbGwucnVuIGdpdCBwdXNo\x1b\\",
    );
    try expectReport(&reporter, .working, "\x1b]7501;state=working:app=fx\x1b\\");
    reporter.noteTurnFinished(.completed);
    try expectReport(&reporter, .settled, "\x1b]7501;state=done:app=fx\x1b\\");

    reporter.noteTurnStarted();
    try expectReport(&reporter, .{ .blocked = .{ .kind = .question, .message = "" } }, "\x1b]7501;state=blocked:kind=question:app=fx\x1b\\");
    reporter.noteTurnFinished(.interrupted);
    try expectReport(&reporter, .settled, "\x1b]7501;state=idle:app=fx\x1b\\");

    reporter.noteTurnStarted();
    reporter.noteTurnFinished(.paused);
    try expectReport(&reporter, .settled, "\x1b]7501;state=error:app=fx\x1b\\");
    reporter.noteTurnStarted();
    reporter.noteTurnFinished(.failed);
    try std.testing.expect(reporter.update(.settled) == null);
    reporter.noteTurnStarted();
    try expectReport(&reporter, .settled, "\x1b]7501;state=idle:app=fx\x1b\\");
    reporter.noteFailure();
    try expectReport(&reporter, .settled, "\x1b]7501;state=error:app=fx\x1b\\");
}

test "program status writes only changed reports until invalidated" {
    var reporter = Reporter{};
    try std.testing.expect(reporter.update(.working) != null);
    try std.testing.expect(reporter.update(.working) == null);
    reporter.invalidate();
    try expectReport(&reporter, .working, "\x1b]7501;state=working:app=fx\x1b\\");

    const question: Activity = .{ .blocked = .{ .kind = .question, .message = "First?" } };
    try std.testing.expect(reporter.update(question) != null);
    try std.testing.expect(reporter.update(question) == null);
    try std.testing.expect(reporter.update(.{ .blocked = .{ .kind = .question, .message = "Second?" } }) != null);
}

test "program status messages are one bounded line without control characters" {
    var reporter = Reporter{};
    var decoded: [max_message_bytes]u8 = undefined;

    const hostile = "  Run\n\ttests?\x1b]2;owned\x07 \xc2\x9b now\xff\xe2 ok  ";
    const report = reporter.update(.{ .blocked = .{ .kind = .question, .message = hostile } }).?;
    try std.testing.expectEqualStrings("Run tests? ]2;owned now ok", try decodedMessage(report, &decoded));
    // Only the OSC introducer and the string terminator carry ESC.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, report, "\x1b"));
    try std.testing.expect(std.mem.endsWith(u8, report, terminator));

    const long = "é" ** 200;
    const long_report = reporter.update(.{ .blocked = .{ .kind = .permission, .message = long } }).?;
    const message = try decodedMessage(long_report, &decoded);
    try std.testing.expect(message.len <= max_message_bytes);
    try std.testing.expect(std.mem.endsWith(u8, message, "..."));
    try std.testing.expect(std.unicode.utf8ValidateSlice(message));
    try std.testing.expect(long_report.len <= max_report_bytes);
}

test "program status clear removes every record" {
    try std.testing.expectEqualStrings("\x1b]7501;state=clear\x1b\\", clear_sequence);
}
