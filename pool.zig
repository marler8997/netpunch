const std = @import("std");
const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

/// Maintains a pool of objects.  Objects created by this pool are never moved.
/// It will re-use memory that has been freed, but will not try to release
/// memory back to the underlying allocator.
pub fn Pool(comptime T: type, chunkSize: usize) type {
    // TODO: assert if chunkSize < 1

    const Chunk = struct {
        array: [chunkSize]T,
        // TODO: this isn't necessary if T has in invalid bit pattern
        allocated: [chunkSize]bool,
    };

    return struct {
        allocator: *Allocator,
        chunks: ArrayList(*Chunk),
        pub fn init(allocator: *Allocator) @This() {
            return @This() {
                .allocator = allocator,
                .chunks = ArrayList(*Chunk).init(allocator),
            };
        }
        pub fn create(self: *@This()) Allocator.Error!*T {
            for (self.chunks.span()) |chunk| {
                var i: usize = 0;
                while (i < chunkSize) : (i += 1) {
                    if (!chunk.allocated[i]) {
                        chunk.allocated[i] = true;
                        //std.debug.warn("[DEBUG] returning existing chunk 0x{x} index {}\n", .{@ptrToInt(&chunk.array[i]), i});
                        return &chunk.array[i];
                    }
                }
            }
            var newChunk = try self.allocator.create(Chunk);
            @memset(@ptrCast([*]u8, &newChunk.allocated), 0, @sizeOf(@TypeOf(newChunk.allocated)));
            try self.chunks.append(newChunk);
            newChunk.allocated[0] = true;
            //std.debug.warn("[DEBUG] returning new chunk 0x{x}\n", .{@ptrToInt(&newChunk.array[0])});
            return &newChunk.array[0];
        }

        pub fn destroy(self: *@This(), ptr: *T) void {
            for (self.chunks.span()) |chunk| {
                if (@ptrToInt(ptr) <= @ptrToInt(&chunk.array[chunkSize-1]) and
                    @ptrToInt(ptr) >= @ptrToInt(&chunk.array[0])) {
                    const diff = @ptrToInt(ptr) - @ptrToInt(&chunk.array[0]);
                    const index = diff / @sizeOf(T);
                    std.debug.assert(chunk.allocated[index]); // freed non-allocated pointer
                    chunk.allocated[index] = false;
                    // TODO: zero the memory?
                    return;
                }
            }
            //std.debug.warn("destroy got invalid address 0x{x}\n", .{@ptrToInt(ptr)});
            std.debug.assert(false);
        }
        pub fn range(self: *@This()) PoolRange(T, chunkSize) {
            return PoolRange(T, chunkSize) { .pool = self, .nextChunkIndex = 0, .nextElementIndex = 0 };
        }
    };
}

pub fn PoolRange(comptime T: type, chunkSize: usize) type {
    return struct {
        pool: *Pool(T, chunkSize),
        nextChunkIndex: usize,
        nextElementIndex: usize,
        fn inc(self: *@This()) void {
            self.nextElementIndex += 1;
            if (self.nextElementIndex == chunkSize) {
                self.nextChunkIndex += 1;
                self.nextElementIndex = 0;
            }
        }
        pub fn next(self: *@This()) ?*T {
            while (true) : (self.inc()) {
                if (self.nextChunkIndex >= self.pool.chunks.len)
                    return null;
                var chunk = self.pool.chunks.span()[self.nextChunkIndex];
                if (chunk.allocated[self.nextElementIndex]) {
                    var result = &chunk.array[self.nextElementIndex];
                    self.inc();
                    return result;
                }
            }
        }
    };
}
