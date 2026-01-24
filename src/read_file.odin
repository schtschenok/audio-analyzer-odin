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

Prepared_File :: struct {
    data:                virtual.Memory_Block,
    channels:            i64,
    name:                string,
    original_samplerate: i64,
    original_bit_depth:  i64,
    original_format:     Int_Or_Float,
    original_data_size:  i64,
}

Read_File_Error :: enum {
    None,
    File_Open_Error,
    File_Too_Small_To_Be_Valid,
    File_Map_Error,
    File_Early_EOF,
    RIFF_RIFX_Unsupported,
    RIFF_RF64_Unsupported,
    RIFF_Invalid_Header,
    FMT_Not_Found,
    FMT_Invalid_Bit_Depth,
    FMT_Unsupported_Bit_Depth,
    FMT_Invalid_Channel_Count,
    FMT_Invalid_Samplerate,
    FMT_Invalid_Block_Align,
    FMT_Extended_Unsupported_Extra_Param_Size,
    FMT_Extended_Invalid_Valid_Bits_Per_Sample,
    FMT_Extended_Unsupported_Valid_Bits_Per_Sample,
    FMT_Unsupported_Format,
    DATA_Not_Found,
    DATA_Empty,
    DATA_Invalid_Size,
    Memory_Allocation_Failed,
}

read_file :: proc(file: os.File_Info) -> (Prepared_File, Read_File_Error) {
    trace("Read File")

    Wave_Chunk_Header :: struct #packed {
        marker: [4]byte,
        size:   u32,
    }

    Wave_RIFF_Chunk :: struct #packed {
        chunk_header: Wave_Chunk_Header,
        format:       [4]byte,
    }

    Wave_Format_Type :: enum u16 {
        Int      = 1,
        Float    = 3,
        Extended = 65534,
    }

    Wave_FMT_Subchunk_Basic :: struct #packed {
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

    Wave_Subformat_GUID :: struct #packed {
        audio_format: Wave_Format_Type_In_Subformat_GUID,
        data_2:       u16,
        data_3:       u16,
        data_4:       [8]byte,
    }

    Wave_FMT_Subchunk_Extended :: struct #packed {
        basic_chunk:           Wave_FMT_Subchunk_Basic,
        extra_param_size:      u16,
        valid_bits_per_sample: u16,
        channel_mask:          u32,
        sub_format:            Wave_Subformat_GUID,
    }

    WAVE_MIN_FILE_SIZE :: size_of(Wave_RIFF_Chunk) + size_of(Wave_FMT_Subchunk_Basic) + size_of(Wave_Chunk_Header)

    fd, open_error := os.open(file.fullpath, os.O_RDONLY)
    if open_error != nil {
        return Prepared_File{}, .File_Open_Error
    }
    defer os.close(fd)

    file_size, size_error := os.file_size(fd)
    if size_error != nil {
        return Prepared_File{}, .File_Open_Error
    }

    if file_size <= WAVE_MIN_FILE_SIZE {
        return Prepared_File{}, .File_Too_Small_To_Be_Valid
    }

    raw_file_bytes, map_error := virtual.map_file_from_file_descriptor(uintptr(fd), {.Read})
    if map_error != nil {
        return Prepared_File{}, .File_Map_Error
    }
    defer virtual.release(raw_data(raw_file_bytes), len(raw_file_bytes))

    get_next_subchunk_with_marker :: proc(data: []byte, previous_chunk_header: ^Wave_Chunk_Header, marker: string, $T: typeid, current_offset: ^i64) -> (subchunk_data: ^T, subchunk_found: bool) {
        previous_chunk_size: u32
        switch string(previous_chunk_header.marker[:]) {
        case "RIFF", "RIFX", "RF64":
            previous_chunk_size = 4
        case:
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

    if string(riff_header_in_file.chunk_header.marker[:]) != "RIFF" || string(riff_header_in_file.format[:]) != "WAVE" {
        if string(riff_header_in_file.chunk_header.marker[:]) == "RIFX" {
            return Prepared_File{}, .RIFF_RIFX_Unsupported
        }
        if string(riff_header_in_file.chunk_header.marker[:]) == "RF64" {
            return Prepared_File{}, .RIFF_RF64_Unsupported
        }
        return Prepared_File{}, .RIFF_Invalid_Header
    }

    if (file_size < size_of(Wave_Chunk_Header) + i64(riff_header_in_file.chunk_header.size)) {
        return Prepared_File{}, .File_Early_EOF
    }

    fmt_chunk_in_file, fmt_chunk_found := get_next_subchunk_with_marker(raw_file_bytes, &riff_header_in_file.chunk_header, "fmt ", Wave_FMT_Subchunk_Basic, &current_offset)
    fmt_chunk: ^Wave_FMT_Subchunk_Basic = new(Wave_FMT_Subchunk_Basic, allocator = context.temp_allocator)
    mem.copy(fmt_chunk, fmt_chunk_in_file, size_of(Wave_FMT_Subchunk_Basic))

    if !fmt_chunk_found {
        return Prepared_File{}, .FMT_Not_Found
    }

    // fmt.println(fmt_chunk^)

    prepared_file: Prepared_File

    if (fmt_chunk.num_channels == 0) {
        return Prepared_File{}, .FMT_Invalid_Channel_Count
    }
    prepared_file.channels = i64(fmt_chunk.num_channels)

    switch fmt_chunk.bits_per_sample {
    case 16, 24, 32, 64:
        prepared_file.original_bit_depth = i64(fmt_chunk.bits_per_sample)
    case 0:
        return Prepared_File{}, .FMT_Invalid_Bit_Depth
    case:
        return Prepared_File{}, .FMT_Unsupported_Bit_Depth
    }

    if (fmt_chunk.sample_rate == 0) {
        return Prepared_File{}, .FMT_Invalid_Samplerate
    }
    prepared_file.original_samplerate = i64(fmt_chunk.sample_rate)

    if (fmt_chunk.block_align != fmt_chunk.num_channels * fmt_chunk.bits_per_sample / 8) {
        return Prepared_File{}, .FMT_Invalid_Block_Align
    }

    fmt_extended_chunk: ^Wave_FMT_Subchunk_Extended // Declare it here so I can see it in the debugger

    switch fmt_chunk.audio_format {
    case .Int:
        prepared_file.original_format = .Int
    case .Float:
        prepared_file.original_format = .Float
    case .Extended:
        if file_size < current_offset + i64(size_of(Wave_FMT_Subchunk_Extended)) {
            return Prepared_File{}, .File_Early_EOF
        }
        fmt_extended_chunk_in_file := (^Wave_FMT_Subchunk_Extended)(fmt_chunk_in_file)
        fmt_extended_chunk = new(Wave_FMT_Subchunk_Extended, allocator = context.temp_allocator)
        mem.copy(fmt_extended_chunk, fmt_extended_chunk_in_file, size_of(Wave_FMT_Subchunk_Extended))

        if fmt_extended_chunk.extra_param_size != 22 {
            return Prepared_File{}, .FMT_Extended_Unsupported_Extra_Param_Size
        }

        if fmt_extended_chunk.valid_bits_per_sample != fmt_chunk.bits_per_sample {
            if (fmt_extended_chunk.valid_bits_per_sample == 0) {
                // return Prepared_File{}, .FMT_Extended_Invalid_Valid_Bits_Per_Sample // This isn't very valid but should I treat this as an error? Some files just end up like this.
            } else {
                return Prepared_File{}, .FMT_Extended_Unsupported_Valid_Bits_Per_Sample // Maybe I'll support this in the future? I've never seen such cases in the wild though.
            }
        }

        switch fmt_extended_chunk.sub_format.audio_format {
        case .Int:
            prepared_file.original_format = .Int
        case .Float:
            prepared_file.original_format = .Float
        case:
            return Prepared_File{}, .FMT_Unsupported_Format
        }
    case:
        return Prepared_File{}, .FMT_Unsupported_Format
    }

    data_chunk_header_in_file, data_chunk_found := get_next_subchunk_with_marker(raw_file_bytes, &fmt_chunk.chunk_header, "data", Wave_Chunk_Header, &current_offset)
    data_chunk_header: ^Wave_Chunk_Header = new(Wave_Chunk_Header, allocator = context.temp_allocator)
    mem.copy(data_chunk_header, data_chunk_header_in_file, size_of(Wave_Chunk_Header))

    if !data_chunk_found {
        return Prepared_File{}, .DATA_Not_Found
    }

    if (data_chunk_header^.size == 0) {
        return Prepared_File{}, .DATA_Empty
    }

    current_offset += size_of(Wave_Chunk_Header) // Actual data start

    if (file_size < current_offset + i64(data_chunk_header.size)) {
        return Prepared_File{}, .File_Early_EOF
    }

    if (int(data_chunk_header.size) % int(fmt_chunk.block_align) != 0) {
        return Prepared_File{}, .DATA_Invalid_Size
    }

    // fmt.println(data_chunk_header^)

    prepared_file.original_data_size = i64(data_chunk_header.size)

    deinterleaved_channel_data_size := int(data_chunk_header.size) / int(prepared_file.original_bit_depth) * 32 / int(prepared_file.channels)
    deinterleaved_channel_data_size_aligned := mem.align_formula(deinterleaved_channel_data_size, 64)
    deinterleaved_data_size := uint(deinterleaved_channel_data_size_aligned * int(prepared_file.channels))
    assert(int(deinterleaved_data_size) == mem.align_formula(int(deinterleaved_data_size), 64))
    // fmt.printfln("Deinterleaved Data Size: %d", deinterleaved_data_size)

    // TODO: Represent channels somehow? Change the struct to only hold a single memory block and then represent the channels as slices or whatever?

    deinterleaved_data_memory_block, deinterleaved_data_memory_block_error := virtual.memory_block_alloc(deinterleaved_data_size, deinterleaved_data_size)
    if deinterleaved_data_memory_block_error != nil {
        return Prepared_File{}, .Memory_Allocation_Failed
    }
    mem.zero_slice(deinterleaved_data_memory_block.base[:deinterleaved_data_memory_block.committed])
    defer virtual.memory_block_dealloc(deinterleaved_data_memory_block)

    // fmt.println(deinterleaved_data_memory_block)

    deinterleaved_data_memory_block.used = deinterleaved_data_size
    mem.zero_slice(deinterleaved_data_memory_block.base[deinterleaved_data_memory_block.used:deinterleaved_data_memory_block.committed])

    // fmt.println()

    return prepared_file, .None
}

// TODO: WHAT'S GOING ON WITH THE FILE NAME SLICE???
//
