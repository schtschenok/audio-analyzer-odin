package main

import "core:mem"
import "core:mem/virtual"
import "core:os"

Process_File_Error :: enum {
    None,
    AllocationError,
}

process_file :: proc(file: os.File_Info) -> ([][]f32, Process_File_Error) {
    trace("Process File")

    frame_arena_data: []byte
    {
        trace("Process File - Alloc")
        frame_arena: mem.Arena
        frame_arena_size: uint = mem.Megabyte * 16
        frame_arena_data = make([]byte, frame_arena_size)
        mem.arena_init(&frame_arena, frame_arena_data)
        context.temp_allocator = mem.arena_allocator(&frame_arena)
    }

    when TRACKING_ALLOCATOR {
        tracking_temp_allocator: mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking_temp_allocator, context.temp_allocator)
        context.temp_allocator = mem.tracking_allocator(&tracking_temp_allocator)
        defer mem.tracking_allocator_destroy(&tracking_temp_allocator)
        defer print_tracking_allocator_results(&tracking_temp_allocator, "frame")
    }

    defer {
        trace("Process File - Dealloc")

        mem.free_all(context.temp_allocator)
        delete(frame_arena_data)
    }

    context.allocator = mem.panic_allocator()

    read_file(file) // TODO: Return some struct with data or something, maybe represent channel data as an array of structs wrapping an array (channel) with specified alignment?

    return nil, Process_File_Error.None
}
