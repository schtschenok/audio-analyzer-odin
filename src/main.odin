package main

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strings"

Options :: struct {
    folder: string `args:"pos=0,required" usage:"Input directory."`,
}

main :: proc() {
    // TODO: Set default block size for temp_allocator to a slightly larger value?
    // TODO: Use "when" for tracking allocators?
    tracking_allocator: mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking_allocator, context.allocator)
    defer mem.tracking_allocator_destroy(&tracking_allocator)
    defer print_tracking_allocator_results(&tracking_allocator, "default")
    context.allocator = mem.tracking_allocator(&tracking_allocator)

    tracking_temp_allocator: mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking_temp_allocator, context.temp_allocator)
    defer mem.tracking_allocator_destroy(&tracking_temp_allocator)
    defer print_tracking_allocator_results(&tracking_temp_allocator, "temp")
    context.temp_allocator = mem.tracking_allocator(&tracking_temp_allocator)
    defer free_all(context.temp_allocator)

    context.logger = log.create_console_logger(.Info, log.Default_Console_Logger_Opts, "Audio Analyzer")
    defer free(context.logger.data)

    opt: Options
    flags.parse_or_exit(&opt, os.args, allocator = context.temp_allocator)

    files := make([dynamic]os.File_Info, 0, 1024)
    defer delete(files)
    error := list_files(opt, &files)
    free_all(context.temp_allocator)

    if (error == .None) {
        log.infof("Found %d files with \".wav\" extension", len(files))
    } else {
        log.error("Couldn't get .wav file list")
        return
    }

    {
        frame_arena: mem.Dynamic_Arena
        mem.dynamic_arena_init(&frame_arena, block_size = 1024 * 1024)
        frame_allocator := mem.dynamic_arena_allocator(&frame_arena)
        defer mem.dynamic_arena_destroy(&frame_arena)
        context.temp_allocator = frame_allocator

        tracking_temp_allocator: mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking_temp_allocator, context.temp_allocator)
        defer mem.tracking_allocator_destroy(&tracking_temp_allocator)
        context.temp_allocator = mem.tracking_allocator(&tracking_temp_allocator)

        for file in files {
            read_file(file) // TODO: Return some struct with data or something, maybe represent channel data as an array of structs wrapping an array (channel) with specified alignment?
            free_all(frame_allocator)
        }
    }
}
