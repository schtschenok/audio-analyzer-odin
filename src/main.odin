package main

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:prof/spall"
import "core:sort"
import "core:strings"
import "core:sync"
import "core:time"

// TODO: Add timers and processed byte counters

Options :: struct {
    folder: string `args:"pos=0,required" usage:"Input directory."`,
}

main :: proc() {
    when PERF {
        perf.start_time = time.tick_now()
    }

    temp_allocator: mem.Dynamic_Arena
    mem.dynamic_arena_init(&temp_allocator, block_size = 1024 * 1024 * 16)
    context.temp_allocator = mem.dynamic_arena_allocator(&temp_allocator)
    defer mem.dynamic_arena_destroy(&temp_allocator)

    when TRACKING_ALLOCATOR {
        tracking_allocator: mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking_allocator, context.allocator)
        context.allocator = mem.tracking_allocator(&tracking_allocator)
        defer mem.tracking_allocator_destroy(&tracking_allocator)
        defer print_tracking_allocator_results(&tracking_allocator, "main")

        tracking_temp_allocator: mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking_temp_allocator, context.temp_allocator)
        context.temp_allocator = mem.tracking_allocator(&tracking_temp_allocator)
        defer mem.tracking_allocator_destroy(&tracking_temp_allocator)
        defer print_tracking_allocator_results(&tracking_temp_allocator, "temp")
    }

    defer free_all(context.temp_allocator)

    when SPALL {
        spall_ctx = spall.context_create("trace_test.spall")
        defer spall.context_destroy(&spall_ctx)
        buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
        defer delete(buffer_backing)
        spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
        defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
    }

    trace("Main")

    context.logger = log.create_console_logger(.Info, log.Default_Console_Logger_Opts, "Audio Analyzer")
    defer free(context.logger.data)

    opt: Options
    flags.parse_or_exit(&opt, os.args, allocator = context.temp_allocator)

    files := make([dynamic]os.File_Info, 0, 1024)
    defer os.file_info_slice_delete(files[:])
    error := list_files(opt, &files)

    free_all(context.temp_allocator)

    if (error == .None) {
        log.infof("Found %d files with \".wav\" extension", len(files))
    } else {
        log.error("Couldn't get .wav file list")
        return
    }

    {
        trace("Processing files")

        when PERF {
            perf.main_loop_start_time = time.tick_now()
        }

        for file in files {
            _, process_file_error := process_file(file)
            if process_file_error != .None {
                when PERF {
                    perf.files_failed = perf.files_failed + 1
                }
            } else {
                when PERF {
                    perf.files_processed = perf.files_processed + 1
                }
            }
        }
    }

    when PERF {
        perf.end_time = time.tick_now()

        spool_up_time := time.tick_diff(perf.start_time, perf.main_loop_start_time)
        loop_time := time.tick_diff(perf.main_loop_start_time, perf.end_time)
        megabyes_processed := perf.bytes_processed / 1024 / 1024

        fmt.println(perf)
    }
}
