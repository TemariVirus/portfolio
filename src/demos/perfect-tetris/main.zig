const std = @import("std");
const assert = std.debug.assert;

const perfect_tetris = @import("perfect-tetris");
const Placement = perfect_tetris.Placement;
const engine = @import("engine");
const PieceKind = engine.pieces.PieceKind;

const allocator = std.heap.wasm_allocator;
const ROWS = 6;
const COLUMNS = 10;
const MAX_SOL_LEN = ROWS * COLUMNS / 4;

const JS = struct {
    extern fn _consoleLog([*]const u8, usize) void;
    extern fn _consoleError([*]const u8, usize) void;

    var console_buffer: ?[]u8 = null;

    pub fn consoleLog(comptime fmt: []const u8, args: anytype) void {
        const buf = if (console_buffer) |b| b else blk: {
            @branchHint(.cold);
            console_buffer = allocator.alloc(u8, 64 * 1024) catch {
                consoleError("Failed to allocate console buffer, using stack");
                var _buf: [1024]u8 = undefined;
                break :blk &_buf;
            };
            break :blk console_buffer.?;
        };

        var fbs = std.io.fixedBufferStream(buf);
        std.fmt.format(fbs.writer().any(), fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => consoleError("consolePrint: string too long, truncating."),
            else => unreachable,
        };
        _consoleLog(fbs.getWritten().ptr, fbs.getWritten().len);
    }

    pub fn consoleError(str: []const u8) void {
        _consoleError(str.ptr, str.len);
    }
};

const Cell = struct { x: u8, y: u8 };

fn growLen(current: usize, target: usize) usize {
    var size = @max(8, current);
    while (size < target) {
        if (size > std.math.maxInt(usize) / 2) return target;
        size *= 2;
    }
    return size;
}

var input_buf: ?[]u8 = null;
export fn ensureBufferSize(len: usize) ?[*]u8 {
    if (input_buf) |buf| {
        if (len <= buf.len) return buf.ptr;
    }

    input_buf = blk: {
        break :blk if (input_buf) |buf|
            allocator.realloc(buf, growLen(buf.len, len))
        else
            allocator.alloc(u8, len);
    } catch {
        JS.consoleError("Wasm: OOM");
        return null;
    };
    return input_buf.?.ptr;
}

fn charToPiece(c: u8) PieceKind {
    return switch (c) {
        'I' => .i,
        'O' => .o,
        'T' => .t,
        'S' => .s,
        'Z' => .z,
        'L' => .l,
        'J' => .j,
        else => unreachable,
    };
}

fn pieceToChar(p: PieceKind) u8 {
    return switch (p) {
        .i => 'I',
        .o => 'O',
        .t => 'T',
        .s => 'S',
        .z => 'Z',
        .l => 'L',
        .j => 'J',
    };
}

fn updateLineYs(board: *const [ROWS * COLUMNS]u8, line_ys: []u8) void {
    var y: i8 = ROWS - 1;
    while (y >= 0) : (y -= 1) {
        const lines_above = line_ys[@intCast(y)..];
        if (!std.mem.containsAtLeastScalar(u8, board[lines_above[0] * COLUMNS ..][0..COLUMNS], 1, 'N')) {
            std.mem.copyForwards(u8, lines_above, lines_above[1..]);
        }
    }
}

fn placementCells(placement: Placement) [4]Cell {
    var cells: std.BoundedArray(Cell, 4) = .{};
    const mask = placement.piece.mask();
    for (placement.piece.bottom()..placement.piece.top()) |y| {
        for (placement.piece.left()..placement.piece.right()) |x| {
            if (!mask.get(x, y)) {
                continue;
            }
            cells.appendAssumeCapacity(.{
                .x = @intCast(placement.pos.x + @as(i8, @intCast(x))),
                .y = @intCast(placement.pos.y + @as(i8, @intCast(y))),
            });
        }
    }
    assert(cells.len == 4);
    return cells.buffer;
}

fn clearLines(frame: *[ROWS * COLUMNS]u8) void {
    var y: u8 = 0;
    var cleared: u8 = 0;
    while (y + cleared < ROWS) {
        if (cleared > 0) {
            @memcpy(frame[y * COLUMNS ..][0..COLUMNS], frame[(y + cleared) * COLUMNS ..][0..COLUMNS]);
        }
        if (std.mem.containsAtLeastScalar(u8, frame[y * COLUMNS ..][0..COLUMNS], 1, 'N')) {
            y += 1;
        } else {
            cleared += 1;
        }
    }
    @memset(frame[y * COLUMNS ..], 'N');
}

fn formatSolution(
    frames: [][ROWS * COLUMNS]u8,
    board: [ROWS * COLUMNS]u8,
    solution: []const Placement,
) void {
    // 1st frame is complete solution
    @memcpy(&frames[0], &board);
    var line_ys: [ROWS]u8 = .{ 0, 1, 2, 3, 4, 5 };
    for (solution) |place| {
        const cells = placementCells(place);
        for (cells) |c| {
            const cy = line_ys[c.y];
            frames[0][cy * COLUMNS + c.x] = pieceToChar(place.piece.kind);
        }

        updateLineYs(&frames[0], &line_ys);
    }

    // Do placements in order from 2nd frame onwards
    @memcpy(&frames[1], &board);
    for (solution, 1..) |place, i| {
        if (i > 1) {
            @memcpy(&frames[i], &frames[i - 1]);
            clearLines(&frames[i]);
        }

        const cells = placementCells(place);
        for (cells) |c| {
            frames[i][c.y * COLUMNS + c.x] = pieceToChar(place.piece.kind);
        }
    }
}

var nn: ?perfect_tetris.NN = null;
var findPc_result: extern struct {
    frames_len: u8,
    _padding1: [7]u8,
    frames: [MAX_SOL_LEN + 1][ROWS * COLUMNS]u8,
} = undefined;
export fn findPc(_data: [*]const u8, len: usize) ?[*]const u8 {
    const data = _data[0..len];
    const board = data[0 .. ROWS * COLUMNS];
    const queue = data[ROWS * COLUMNS ..];

    if (nn == null) {
        @branchHint(.cold);
        nn = perfect_tetris.defaultNN(allocator) catch {
            JS.consoleError("Failed to allocate NN");
            return null;
        };
    }

    var playfield: engine.bit_masks.BoardMask = .{};
    for (0..ROWS) |y| {
        for (0..COLUMNS) |x| {
            if (board[y * COLUMNS + x] != 'N') {
                playfield.set(x, y, true);
            }
        }
    }

    var pieces_buf: [MAX_SOL_LEN + 1]PieceKind = undefined;
    const pieces = pieces_buf[0..@min(queue.len, pieces_buf.len)];
    for (0..pieces.len) |i| {
        pieces[i] = charToPiece(queue[i]);
    }

    var placements_buf: [MAX_SOL_LEN]perfect_tetris.Placement = undefined;
    const solution = perfect_tetris.pc.findPc(
        .{
            .allocator = allocator,
            .playfield = playfield,
            .pieces = pieces,
            .kicks = engine.kicks.srs,
            .nn = nn.?,
        },
        &placements_buf,
    ) catch |err| switch (err) {
        error.ImpossibleSaveHold => unreachable,
        error.NoPcExists, error.OutOfMemory, error.SolutionTooLong => return null,
    };

    findPc_result.frames_len = @intCast(solution.len + 1);
    formatSolution(&findPc_result.frames, board.*, solution);
    return @ptrCast(&findPc_result);
}
