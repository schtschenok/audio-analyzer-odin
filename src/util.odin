package main

import "core:mem/virtual"

when ODIN_OS == .Windows {
    foreign import Kernel32 "system:Kernel32.lib"

    @(default_calling_convention = "system")
    foreign Kernel32 {
        UnmapViewOfFile :: proc(lpBaseAddress: rawptr) -> b32 ---
    }

    @(no_sanitize_address)
    unmap_file :: proc "contextless" (data: []byte) {
        UnmapViewOfFile(raw_data(data))
    }
} else {
    @(no_sanitize_address)
    unmap_file :: proc "contextless" (data: []byte) {
        virtual.release(raw_data(data), len(data))
    }
}
