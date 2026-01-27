package main

import "base:runtime"
import "core:bytes"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:sort"
import "core:strings"

Int_Or_Float :: enum {
    Int,
    Float,
}

Loaded_File :: struct {
    data:                  []f32,
    channel_count:         u64,
    challen_length_useful: u64,
    original_path:         string,
    original_samplerate:   u64,
    original_bit_depth:    u64,
    original_format:       Int_Or_Float,
    original_data_size:    u64,
}

Load_File_Error :: enum {
    None,
    File_Open_Error,
    File_Too_Small_To_Be_Valid,
    File_Map_Error,
    File_Early_EOF,
    RIFF_Chunk_RIFX_Unsupported,
    RIFF_Chunk_RF64_Unsupported,
    RIFF_Chunk_BW64_Unsupported,
    RIFF_Chunk_Invalid_Header,
    RIFF_Chunk_Invalid_Size,
    FMT_Chunk_Not_Found,
    FMT_Chunk_Invalid_Bit_Depth,
    FMT_Chunk_Unsupported_Bit_Depth,
    FMT_Chunk_Invalid_Channel_Count,
    FMT_Chunk_Invalid_Samplerate,
    FMT_Chunk_Invalid_Block_Align,
    FMT_Chunk_Unsupported_Format,
    FMT_Extended_Chunk_Invalid_Extra_Param_Size,
    FMT_Extended_Chunk_Unsupported_Extra_Param_Size,
    FMT_Extended_Chunk_Unsupported_Valid_Bits_Per_Sample,
    DATA_Chunk_Not_Found,
    DATA_Chunk_Empty,
    DATA_Chunk_Invalid_Size,
    Allocation_Failed,
}

load_file :: proc(file: os.File_Info, strict: bool = false) -> (Loaded_File, Load_File_Error) {
    trace("Read File")

    Wave_Chunk_Header :: struct #packed {
        marker: [4]byte,
        size:   u32,
    }

    Wave_RIFF_Chunk :: struct #packed {
        chunk_header: Wave_Chunk_Header,
        format:       [4]byte,
    }

    Wave_FMT_Chunk :: struct #packed {
        chunk_header:    Wave_Chunk_Header,
        audio_format:    Wave_Format_Type,
        num_channels:    u16,
        sample_rate:     u32,
        byte_rate:       u32,
        block_align:     u16,
        bits_per_sample: u16,
    }

    Wave_FMT_Extended_Chunk :: struct #packed {
        basic_chunk:           Wave_FMT_Chunk,
        extra_param_size:      u16,
        valid_bits_per_sample: u16,
        channel_mask:          u32,
        sub_format:            Wave_Subformat_GUID,
    }

    Wave_Format_Type :: enum u16 {
        Int      = 1,
        Float    = 3,
        Extended = 65534,
    }

    Wave_Format_Type_In_Subformat_GUID :: enum u32 {
        Int   = 1,
        Float = 3,
    }

    Wave_Subformat_GUID :: struct #packed {
        audio_format: Wave_Format_Type_In_Subformat_GUID,
        data_2:       u16,
        data_3:       u16,
        data_4:       [8]byte,
    }

    WAVE_MIN_FILE_SIZE :: size_of(Wave_RIFF_Chunk) + size_of(Wave_FMT_Chunk) + size_of(Wave_Chunk_Header)

    fd, open_error := os.open(file.fullpath, os.O_RDONLY)
    if open_error != nil {
        return Loaded_File{}, .File_Open_Error
    }
    defer os.close(fd)

    file_size, size_error := os.file_size(fd)
    if size_error != nil {
        return Loaded_File{}, .File_Open_Error
    }

    if file_size <= WAVE_MIN_FILE_SIZE {
        return Loaded_File{}, .File_Too_Small_To_Be_Valid
    }

    raw_file_bytes, map_error := virtual.map_file_from_file_descriptor(uintptr(fd), {.Read})
    if map_error != nil {
        return Loaded_File{}, .File_Map_Error
    }
    defer virtual.release(raw_data(raw_file_bytes), len(raw_file_bytes))

    get_next_chunk_with_marker :: proc(data: []byte, previous_chunk_header: ^Wave_Chunk_Header, marker: string, $T: typeid, current_offset: ^i64) -> (chunk_data: ^T, chunk_found: bool) {
        previous_chunk_size: u32
        if string(previous_chunk_header.marker[:]) == "RIFF" {
            previous_chunk_size = 4
        } else {
            previous_chunk_size = previous_chunk_header.size
        }

        for {
            current_offset^ = current_offset^ + size_of(Wave_Chunk_Header) + i64(previous_chunk_size)

            if i64(len(data)) < current_offset^ + size_of(T) {
                return nil, false
            }
            if string(marker[:]) == string(data[current_offset^:current_offset^ + 4]) {
                break
            } else {
                mem.copy(&previous_chunk_size, raw_data(data[current_offset^ + 4:]), 4)
                if previous_chunk_size % 2 != 0 {
                    previous_chunk_size += 1
                }
            }
        }
        return (^T)(raw_data(data[current_offset^:])), true
    }

    current_offset: i64 = 0
    riff_header_in_file := (^Wave_RIFF_Chunk)(raw_data(raw_file_bytes))

    switch string(riff_header_in_file.chunk_header.marker[:]) {
    // Maybe support all this stuff? Don't forget to update get_next_chunk_with_marker() if I ever do.
    case "RIFX":
        return Loaded_File{}, .RIFF_Chunk_RIFX_Unsupported
    case "RF64":
        return Loaded_File{}, .RIFF_Chunk_RF64_Unsupported
    case "BW64":
        return Loaded_File{}, .RIFF_Chunk_BW64_Unsupported
    case "RIFF":
        if string(riff_header_in_file.format[:]) != "WAVE" {
            return Loaded_File{}, .RIFF_Chunk_Invalid_Header
        }
    case:
        return Loaded_File{}, .RIFF_Chunk_Invalid_Header
    }

    if file_size < i64(riff_header_in_file.chunk_header.size) {
        return Loaded_File{}, .File_Early_EOF
    }

    if strict && file_size < size_of(Wave_Chunk_Header) + i64(riff_header_in_file.chunk_header.size) {
        return Loaded_File{}, .RIFF_Chunk_Invalid_Size
    }

    fmt_chunk_in_file, fmt_chunk_found := get_next_chunk_with_marker(raw_file_bytes, &riff_header_in_file.chunk_header, "fmt ", Wave_FMT_Chunk, &current_offset)
    fmt_chunk: ^Wave_FMT_Chunk = new(Wave_FMT_Chunk, allocator = context.temp_allocator)
    mem.copy(fmt_chunk, fmt_chunk_in_file, size_of(Wave_FMT_Chunk))

    if !fmt_chunk_found {
        return Loaded_File{}, .FMT_Chunk_Not_Found
    }

    fmt.println(fmt_chunk^)

    prepared_file: Loaded_File

    if fmt_chunk.num_channels == 0 {
        return Loaded_File{}, .FMT_Chunk_Invalid_Channel_Count
    }
    prepared_file.channel_count = u64(fmt_chunk.num_channels)

    switch fmt_chunk.bits_per_sample {
    case 8, 16, 24, 32, 64:
        prepared_file.original_bit_depth = u64(fmt_chunk.bits_per_sample)
    case 0:
        return Loaded_File{}, .FMT_Chunk_Invalid_Bit_Depth
    case:
        return Loaded_File{}, .FMT_Chunk_Unsupported_Bit_Depth
    }

    if fmt_chunk.sample_rate == 0 {
        return Loaded_File{}, .FMT_Chunk_Invalid_Samplerate
    }
    prepared_file.original_samplerate = u64(fmt_chunk.sample_rate)

    if fmt_chunk.block_align != fmt_chunk.num_channels * fmt_chunk.bits_per_sample / 8 {
        return Loaded_File{}, .FMT_Chunk_Invalid_Block_Align
    }

    fmt_extended_chunk: ^Wave_FMT_Extended_Chunk // Declare it here so I can see it in the debugger
    switch fmt_chunk.audio_format {
    case .Int:
        prepared_file.original_format = .Int
    case .Float:
        prepared_file.original_format = .Float
    case .Extended:
        if file_size < current_offset + i64(size_of(Wave_FMT_Extended_Chunk)) {
            return Loaded_File{}, .File_Early_EOF
        }
        fmt_extended_chunk_in_file := (^Wave_FMT_Extended_Chunk)(fmt_chunk_in_file)
        fmt_extended_chunk = new(Wave_FMT_Extended_Chunk, allocator = context.temp_allocator)
        mem.copy(fmt_extended_chunk, fmt_extended_chunk_in_file, size_of(Wave_FMT_Extended_Chunk))

        if fmt_extended_chunk.extra_param_size < 22 {
            return Loaded_File{}, .FMT_Extended_Chunk_Invalid_Extra_Param_Size
        }

        if fmt_extended_chunk.extra_param_size != 22 {
            return Loaded_File{}, .FMT_Extended_Chunk_Unsupported_Extra_Param_Size
        }

        // Maybe I'll support this in the future? I've never seen such cases in the wild though.
        if fmt_extended_chunk.valid_bits_per_sample != 0 && fmt_extended_chunk.valid_bits_per_sample != fmt_chunk.bits_per_sample {
            return Loaded_File{}, .FMT_Extended_Chunk_Unsupported_Valid_Bits_Per_Sample
        }

        switch fmt_extended_chunk.sub_format.audio_format {
        case .Int:
            prepared_file.original_format = .Int
        case .Float:
            prepared_file.original_format = .Float
        case:
            return Loaded_File{}, .FMT_Chunk_Unsupported_Format
        }
    case:
        return Loaded_File{}, .FMT_Chunk_Unsupported_Format
    }

    data_chunk_header_in_file, data_chunk_found := get_next_chunk_with_marker(raw_file_bytes, &fmt_chunk.chunk_header, "data", Wave_Chunk_Header, &current_offset)
    data_chunk_header: ^Wave_Chunk_Header = new(Wave_Chunk_Header, allocator = context.temp_allocator)
    mem.copy(data_chunk_header, data_chunk_header_in_file, size_of(Wave_Chunk_Header))

    if !data_chunk_found {
        return Loaded_File{}, .DATA_Chunk_Not_Found
    }

    if data_chunk_header^.size == 0 {
        return Loaded_File{}, .DATA_Chunk_Empty
    }

    current_offset += size_of(Wave_Chunk_Header) // Actual data start

    if file_size < current_offset + i64(data_chunk_header.size) {
        return Loaded_File{}, .File_Early_EOF
    }

    if int(data_chunk_header.size) % int(fmt_chunk.block_align) != 0 {
        return Loaded_File{}, .DATA_Chunk_Invalid_Size
    }

    fmt.println(data_chunk_header^)

    prepared_file.original_data_size = u64(data_chunk_header.size)

    // WILD WEST STARTS HERE

    deinterleaved_channel_data_size := uint(data_chunk_header.size) / uint(prepared_file.original_bit_depth) * 32 / uint(prepared_file.channel_count)
    deinterleaved_channel_data_size_aligned := mem.align_forward_uint(deinterleaved_channel_data_size, 64)
    deinterleaved_data_size := uint(deinterleaved_channel_data_size_aligned * uint(prepared_file.channel_count))

    prepared_file.challen_length_useful = u64(deinterleaved_channel_data_size) / 4 // Bytes in 32 bits

    fmt.println(file.name)
    fmt.printfln("Deinterleaved Data Size: %d", deinterleaved_data_size)

    // TODO: Represent channels somehow? Change the struct to only hold a single memory block and then represent the channels as slices or whatever?

    deinterleaved_data_bytes, deinterleaved_data_allocator_error := virtual.reserve_and_commit(deinterleaved_data_size)
    if deinterleaved_data_allocator_error != .None {
        return Loaded_File{}, .Allocation_Failed
    }
    mem.zero_slice(deinterleaved_data_bytes)

    prepared_file.data = mem.slice_data_cast([]f32, deinterleaved_data_bytes)

    // FOR TESTING
    defer virtual.release(raw_data(deinterleaved_data_bytes), deinterleaved_data_size)

    // fmt.println(deinterleaved_data_bytes)
    fmt.println()

    return prepared_file, .None
}
