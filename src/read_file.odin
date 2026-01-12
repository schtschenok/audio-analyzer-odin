package main

import "base:runtime"
import "core:bytes"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:sort"
import "core:strings"

Read_File_Error :: enum {
    None,
    Cant_Open_File,
    File_Too_Small,
    Cant_Map_File,
}

read_file :: proc(file: os.File_Info) -> ([][]f32, Read_File_Error) {
    Wave_Chunk_Header :: struct {
        marker: [4]u8,
        size:   u32,
    }

    Wave_RIFF_Chunk :: struct {
        chunk_header: Wave_Chunk_Header,
        format:       [4]u8,
    }

    Wave_Format_Type :: enum u16 {
        Int      = 1,
        Float    = 3,
        Extended = 65534,
    }

    Wave_FMT_Subchunk_Basic :: struct {
        chunk_header:    Wave_Chunk_Header,
        audio_format:    Wave_Format_Type,
        num_channels:    u16,
        sample_rate:     u32,
        byte_rate:       u32,
        block_align:     u16,
        bits_per_sample: u16,
    }

    Wave_Format_Type_In_Subformat_GUID :: enum u32 {
        Int   = 1,
        Float = 3,
    }

    Wave_Subformat_GUID :: struct {
        audio_format: Wave_Format_Type_In_Subformat_GUID,
        data_2:       u16,
        data_3:       u16,
        data_4:       [8]u8,
    }

    Wave_FMT_Subchunk_Extended :: struct {
        basic_chunk:           Wave_FMT_Subchunk_Basic,
        extra_param_size:      u16,
        valid_bits_per_sample: u16,
        channel_mask:          u32,
        sub_format:            Wave_Subformat_GUID,
    }

    Wave_DATA_Subchunk :: struct {
        chunk_header: Wave_Chunk_Header,
        data:         []u8,
    }

    WAVE_MIN_FILE_SIZE :: size_of(Wave_RIFF_Chunk) + size_of(Wave_FMT_Subchunk_Basic) + size_of(Wave_DATA_Subchunk)

    // TODO: Process error https://github.com/pbremondFR/scop/blob/c7af2d6ecc4436d3e5a957b0bd78ba78543abe26/src/textures.odin#L62
    fd, open_error := os.open(file.fullpath, os.O_RDONLY)
    if open_error != nil {
        return nil, .Cant_Open_File
    }
    defer os.close(fd)

    file_size, size_error := os.file_size(fd)
    if size_error != nil {
        return nil, .Cant_Open_File
    }

    if file_size <= WAVE_MIN_FILE_SIZE {
        return nil, .File_Too_Small
    }

    data, map_error := virtual.map_file_from_file_descriptor(uintptr(fd), {.Read})
    if map_error != nil {
        return nil, .Cant_Map_File
    }
    defer virtual.release(raw_data(data), len(data))

    get_next_subchunk_with_marker :: proc(data: []byte, previous_chunk_header: Wave_Chunk_Header, marker: string, $T: typeid, current_offset: ^int) -> (subchunk_data: ^T, subchunk_found: bool) {
        current_offset_was_zero: bool = current_offset^ == 0 // Can this be done better?
        for {
            if current_offset_was_zero {
                current_offset^ = current_offset^ + size_of(Wave_Chunk_Header) + 4 // Fixed 4-byte offset for RIFF header's "WAVE"
            } else {
                current_offset^ = current_offset^ + size_of(Wave_Chunk_Header) + int(previous_chunk_header.size)
            }
            if (len(data) < current_offset^ + size_of(Wave_Chunk_Header)) {
                return nil, false
            }
            left := raw_data(marker)[:4]
            right := raw_data(data[current_offset^:])[:4]
            if mem.compare(left, right) == 0 {
                break
            }
        }
        return (^T)(raw_data(data[current_offset^:])), true
    }

    current_offset: int = 0
    riff_header_in_file := (^Wave_RIFF_Chunk)(raw_data(data))
    // fmt.println(riff_header_in_file.chunk_header.marker) // Chack marker
    // fmt.println(riff_header_in_file.chunk_header.size) // Check size against actual file size
    // fmt.println(riff_header_in_file.format) // Check format
    // fmt.println()

    fmt.printfln("Size: %d", len(data))

    fmt_chunk_in_file, fmt_chunk_found := get_next_subchunk_with_marker(data, riff_header_in_file.chunk_header, "fmt ", Wave_FMT_Subchunk_Basic, &current_offset)

    fmt.println(fmt_chunk_found)
    fmt.println(fmt_chunk_in_file^)
    fmt.println()

    // for {

    // }
    // next_chunk_header_in_file := (^Wave_Chunk_Header)(get_next_chunk_raw_data(data, riff_header_in_file.chunk_header, &current_offset))
    // // fmt.println(next_chunk_header_in_file.marker) // Check marker
    // // fmt.println(next_chunk_header_in_file.size) // Check if size is at least >= size_of(Wave_FMT_Subchunk_Basic) - size_of(Wave_Chunk_Header)
    // // fmt.println()

    // fmt_chunk_in_file := (^Wave_FMT_Subchunk_Basic)(raw_data(data[current_offset:]))

    // current_offset = current_offset + size_of(Wave_Chunk_Header) + fmt_chunk_in_file.chunk_header.size
    // next_chunk_header_in_file = (^Wave_Chunk_Header)(raw_data(data[current_offset:]))

    // fmt.println(fmt_chunk_in_file)

    // if next_chunk_header_in_file.marker[0] != 100 {
    //     current_offset = current_offset + size_of(Wave_Chunk_Header) + next_chunk_header_in_file.size
    //     next_chunk_header_in_file = (^Wave_Chunk_Header)(raw_data(data[current_offset:]))
    // }

    // if next_chunk_header_in_file.marker[0] != 100 {
    //     current_offset = current_offset + size_of(Wave_Chunk_Header) + next_chunk_header_in_file.size
    //     next_chunk_header_in_file = (^Wave_Chunk_Header)(raw_data(data[current_offset:]))
    // }

    // fmt.println(next_chunk_header_in_file.marker) // Check marker
    // fmt.println(next_chunk_header_in_file.size) // Check if size is at least >= size_of(Wave_FMT_Subchunk_Basic) - size_of(Wave_Chunk_Header)
    // fmt.println()


    return nil, .None
}
