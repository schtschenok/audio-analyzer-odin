package main

import "core:mem"
import "core:mem/virtual"
import "core:os"

Process_File_Error :: enum {
    None,
    AllocationError,
    Cant_Read_File,
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

    default_allocator := context.allocator
    context.allocator = mem.panic_allocator()

    prepared_file, read_file_error := read_file(file)

    if read_file_error != .None {
        panic("Wtf?")
    } else {
        // TODO: TEMPORARY, also this doesn't work btw
        perf.bytes_processed = perf.bytes_processed + u64(prepared_file.original_data_size)

    }

    context.allocator = default_allocator
    return nil, Process_File_Error.None
}
