package main

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

Int_Or_Float :: enum {
    Int,
    Float,
}

Loaded_File :: struct {
    data:                  []f32,
    channel_count:         uint,
    channel_useful_length: uint,
    samplerate:            uint,
    original_path:         string,
    original_bit_depth:    uint,
    original_format:       Int_Or_Float,
    original_data_size:    uint,
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
    trace("Load File")

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

    file_size_i64, size_error := os.file_size(fd)
    file_size := uint(file_size_i64)
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
    assert(file_size == len(raw_file_bytes))
    defer unmap_file(raw_file_bytes)

    get_next_chunk_with_marker :: proc(data: []byte, previous_chunk_header: ^Wave_Chunk_Header, marker: string, $T: typeid, current_offset: ^uint) -> (chunk_data: ^T, chunk_found: bool) {
        previous_chunk_size: u32
        if string(previous_chunk_header.marker[:]) == "RIFF" {
            previous_chunk_size = 4
        } else {
            previous_chunk_size = previous_chunk_header.size
        }

        for {
            current_offset^ = current_offset^ + size_of(Wave_Chunk_Header) + uint(previous_chunk_size)

            if uint(len(data)) < current_offset^ + size_of(T) {
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

    current_offset: uint = 0
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

    if file_size < uint(riff_header_in_file.chunk_header.size) {
        return Loaded_File{}, .File_Early_EOF
    }

    if strict && file_size < size_of(Wave_Chunk_Header) + uint(riff_header_in_file.chunk_header.size) {
        return Loaded_File{}, .RIFF_Chunk_Invalid_Size
    }

    fmt_chunk_in_file, fmt_chunk_found := get_next_chunk_with_marker(raw_file_bytes, &riff_header_in_file.chunk_header, "fmt ", Wave_FMT_Chunk, &current_offset)
    fmt_chunk: ^Wave_FMT_Chunk = new(Wave_FMT_Chunk, allocator = context.temp_allocator)
    mem.copy(fmt_chunk, fmt_chunk_in_file, size_of(Wave_FMT_Chunk))

    if !fmt_chunk_found {
        return Loaded_File{}, .FMT_Chunk_Not_Found
    }

    // fmt.println(fmt_chunk^)

    loaded_file: Loaded_File

    if fmt_chunk.num_channels == 0 {
        return Loaded_File{}, .FMT_Chunk_Invalid_Channel_Count
    }
    loaded_file.channel_count = uint(fmt_chunk.num_channels)

    switch fmt_chunk.bits_per_sample {
    case 8, 16, 24, 32, 64:
        loaded_file.original_bit_depth = uint(fmt_chunk.bits_per_sample)
    case 0:
        return Loaded_File{}, .FMT_Chunk_Invalid_Bit_Depth
    case:
        return Loaded_File{}, .FMT_Chunk_Unsupported_Bit_Depth
    }

    if fmt_chunk.sample_rate == 0 {
        return Loaded_File{}, .FMT_Chunk_Invalid_Samplerate
    }
    loaded_file.samplerate = uint(fmt_chunk.sample_rate)

    if fmt_chunk.block_align != fmt_chunk.num_channels * fmt_chunk.bits_per_sample / 8 {
        return Loaded_File{}, .FMT_Chunk_Invalid_Block_Align
    }

    fmt_extended_chunk: ^Wave_FMT_Extended_Chunk
    switch fmt_chunk.audio_format {
    case .Int:
        loaded_file.original_format = .Int
    case .Float:
        loaded_file.original_format = .Float
    case .Extended:
        if file_size < current_offset + uint(size_of(Wave_FMT_Extended_Chunk)) {
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
            loaded_file.original_format = .Int
        case .Float:
            loaded_file.original_format = .Float
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

    if data_chunk_header.size == 0 {
        return Loaded_File{}, .DATA_Chunk_Empty
    }

    current_offset += size_of(Wave_Chunk_Header) // Actual data start offset

    if file_size < current_offset + uint(data_chunk_header.size) {
        return Loaded_File{}, .File_Early_EOF
    }

    if int(data_chunk_header.size) % int(fmt_chunk.block_align) != 0 {
        return Loaded_File{}, .DATA_Chunk_Invalid_Size
    }

    loaded_file.original_data_size = uint(data_chunk_header.size)

    // fmt.println(data_chunk_header^)

    deinterleaved_channel_size := uint(data_chunk_header.size) / uint(loaded_file.original_bit_depth / 8) * size_of(f32) / uint(loaded_file.channel_count)
    deinterleaved_channel_size_aligned := mem.align_forward_uint(deinterleaved_channel_size, mem.DEFAULT_PAGE_SIZE)
    deinterleaved_total_size := deinterleaved_channel_size_aligned * uint(loaded_file.channel_count)

    loaded_file.channel_useful_length = deinterleaved_channel_size / size_of(f32)

    // fmt.println(file.name)
    // fmt.printfln("Deinterleaved Data Size: %d", deinterleaved_total_size)

    deinterleaved_data_bytes, deinterleaved_data_allocator_error := virtual.reserve_and_commit(deinterleaved_total_size)
    if deinterleaved_data_allocator_error != .None {
        return Loaded_File{}, .Allocation_Failed
    }
    mem.zero_slice(deinterleaved_data_bytes)

    loaded_file.data = slice.reinterpret([]f32, deinterleaved_data_bytes)
    loaded_file.original_path = strings.clone(file.fullpath)

    loaded_file_validate(&loaded_file)

    trace("Read File")
    // Hot!
    current_channel: uint = 0
    current_sample: uint = 0
    data_length: uint = len(loaded_file.data)
    channel_count: uint = loaded_file.channel_count
    channel_length: uint = data_length / channel_count
    channel_useful_length: uint = loaded_file.channel_useful_length
    sample_size := loaded_file.original_bit_depth / 8
    data_in_file := raw_data(raw_file_bytes[current_offset:])
    data_size_in_file := channel_count * loaded_file.channel_useful_length * sample_size
    U8_TO_F32_MULTIPLIER :: 2.0 / 255.0 // Not 256 since it's unsigned!
    I16_TO_F32_MULTIPLIER :: 1.0 / 32768.0
    I24_TO_F32_MULTIPLIER :: 1.0 / 8388608.0
    I32_TO_F32_MULTIPLIER :: 1.0 / 2147483648.0
    switch loaded_file.original_bit_depth {
    // Int (but unsigned!)
    case 8:
        value: u8
        for index: uint = 0; current_sample < data_size_in_file; index = (current_sample / sample_size / channel_count) + (current_sample / sample_size) % channel_count * channel_length {
            mem.copy(&value, data_in_file[current_sample:], size_of(u8))

            loaded_file.data[index] = f32(value) * U8_TO_F32_MULTIPLIER - 1

            current_sample += sample_size
        }
    // Int
    case 16:
        value: i16le
        for index: uint = 0; current_sample < data_size_in_file; index = (current_sample / sample_size / channel_count) + (current_sample / sample_size) % channel_count * channel_length {
            mem.copy(&value, data_in_file[current_sample:], size_of(i16))

            loaded_file.data[index] = f32(value) * I16_TO_F32_MULTIPLIER

            current_sample += sample_size
        }
    // Int
    case 24:
        value: i32le
        for index: uint = 0; current_sample < data_size_in_file; index = (current_sample / sample_size / channel_count) + (current_sample / sample_size) % channel_count * channel_length {
            // Option A
            mem.copy(&value, data_in_file[current_sample:], 3) // Size of 24-bit integer!
            value = value << 8
            // Option B
            // value = i32le(data_in_file[current_sample]) << 8 | i32le(data_in_file[current_sample + 1]) << 16 | i32le(data_in_file[current_sample + 2]) << 24

            loaded_file.data[index] = f32(value) * I32_TO_F32_MULTIPLIER

            current_sample += sample_size
        }
    // Int or Float
    case 32:
        switch loaded_file.original_format {
        case .Int:
            value: i32le
            for index: uint = 0; current_sample < data_size_in_file; index = (current_sample / sample_size / channel_count) + (current_sample / sample_size) % channel_count * channel_length {
                mem.copy(&value, data_in_file[current_sample:], size_of(i32))

                loaded_file.data[index] = f32(value) * I32_TO_F32_MULTIPLIER

                current_sample += sample_size
            }
        case .Float:
            value: f32le
            for index: uint = 0; current_sample < data_size_in_file; index = (current_sample / sample_size / channel_count) + (current_sample / sample_size) % channel_count * channel_length {
                mem.copy(&value, data_in_file[current_sample:], size_of(f32))

                loaded_file.data[index] = f32(value)

                current_sample += sample_size
            }
        }
    // Float
    case 64:
        result: f64le
        for index: uint = 0; current_sample < data_size_in_file; index = (current_sample / sample_size / channel_count) + (current_sample / sample_size) % channel_count * channel_length {
            mem.copy(&result, data_in_file[current_sample:], size_of(f64))

            loaded_file.data[index] = f32(result)

            current_sample += sample_size
        }
    }
    // TODO: Check correctness!

    // fmt.println(loaded_file) // Prints the actual data (please no)
    // fmt.println()

    assert(loaded_file_validate(&loaded_file))

    return loaded_file, .None
}

loaded_file_validate :: proc(loaded_file: ^Loaded_File) -> (success: bool) {
    if loaded_file == nil || loaded_file.data == nil {
        return false
    }

    a := bool(loaded_file.channel_count)
    b := bool(loaded_file.channel_useful_length)
    c := bool(loaded_file.original_bit_depth)
    d := loaded_file.original_format == .Int || loaded_file.original_format == .Float
    e := bool(loaded_file.samplerate)
    f := bool(len(loaded_file.original_path))
    g := uint(len(loaded_file.data)) == loaded_file.channel_count * mem.align_forward_uint(loaded_file.channel_useful_length, mem.DEFAULT_PAGE_SIZE / size_of(f32))
    h := loaded_file.channel_count * loaded_file.channel_useful_length * (loaded_file.original_bit_depth / 8) <= loaded_file.original_data_size
    return a && b && c && d && e && f && g && h
}

loaded_file_unload :: proc(loaded_file: ^Loaded_File) -> (success: bool) {
    assert(loaded_file_validate(loaded_file))

    if loaded_file == nil || loaded_file.data == nil {
        return false
    }

    virtual.release(raw_data(loaded_file.data), len(loaded_file.data) * size_of(f32))
    delete_string(loaded_file.original_path)
    loaded_file^ = Loaded_File{}
    return true
}

loaded_file_get_channel :: proc(loaded_file: ^Loaded_File, channel_index: uint) -> (channel: []f32, success: bool) {
    assert(loaded_file_validate(loaded_file))

    if !loaded_file_validate(loaded_file) || !(channel_index < loaded_file.channel_count) {
        return nil, false
    }

    return loaded_file.data[channel_index * uint(len(loaded_file.data)) / loaded_file.channel_count:][:loaded_file.channel_useful_length], true
}
