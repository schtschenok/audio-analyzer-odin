package main

import "core:fmt"
import "core:mem"

print_tracking_allocator_results :: proc(allocator: ^mem.Tracking_Allocator, name: string) {
    for _, value in allocator.allocation_map {
        fmt.printf("%v: Leaked %v bytes by %s allocator\n", value.location, value.size, name)
    }
}
