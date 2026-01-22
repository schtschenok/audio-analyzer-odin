package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:prof/spall"
import "core:time"

TRACKING_ALLOCATOR :: #config(TRACKING_ALLOCATOR, false)
SPALL :: #config(SPALL, false)
PERF :: #config(PERF, false)

when TRACKING_ALLOCATOR {
    print_tracking_allocator_results :: proc(allocator: ^mem.Tracking_Allocator, name: string) {
        for _, value in allocator.allocation_map {
            fmt.printf("%v: Leaked %v bytes by %s allocator\n", value.location, value.size, name)
        }
    }
}

when SPALL {
    SPALL_EVERYTHING :: false

    spall_ctx: spall.Context
    @(thread_local)
    spall_buffer: spall.Buffer

    when SPALL_EVERYTHING {
        @(instrumentation_enter)
        spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
            spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
        }

        @(instrumentation_exit)
        spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
            spall._buffer_end(&spall_ctx, &spall_buffer)
        }

        trace :: proc "contextless" (name: string) {  }
    } else {
        @(deferred_in = _scoped_buffer_end)
        @(no_instrumentation)
        trace :: proc(name: string, location := #caller_location) -> bool {
            spall._buffer_begin(&spall_ctx, &spall_buffer, name, "", location)
            return true
        }

        @(private)
        @(no_instrumentation)
        _scoped_buffer_end :: proc(_: string, _ := #caller_location) {
            spall._buffer_end(&spall_ctx, &spall_buffer)
        }
    }
} else {
    trace :: proc "contextless" (name: string) {  }
}

when PERF {
    Perf :: struct {
        start_time:           time.Tick,
        main_loop_start_time: time.Tick,
        end_time:             time.Tick,
        files_processed:      u64,
        files_failed:         u64,
        bytes_processed:      u64,
    }

    perf: Perf
}
