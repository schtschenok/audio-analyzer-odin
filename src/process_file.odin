package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:reflect"

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

    loaded_file, read_file_error := load_file(file)

    if read_file_error != .None {
        fmt.printfln("File: %s, error: %s", file.fullpath, reflect.enum_string(read_file_error))
        return nil, .Cant_Read_File
    } else {
        perf.bytes_processed += u64(loaded_file.original_data_size)
    }

    loaded_file_unload(&loaded_file)

    return nil, .None
}
