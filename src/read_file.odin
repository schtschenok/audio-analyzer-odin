package main

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:sort"
import "core:strings"

Data_Type :: enum {
    Int,
    Float,
}

Int_Or_Float :: union {
    i32,
    f32,
}

Read_File_Error :: enum {
    None,
    Open_Failure,
}

read_file :: proc(file: os.File_Info) -> ([][]Int_Or_Float, Read_File_Error) {
    Wave_Generic_Chunk :: struct {
        marker: [4]u8,
        size:   u32,
    }

    Wave_RIFF_Chunk :: struct {
        chunk_id:   [4]u8,
        chunk_size: u32,
        format:     [4]u8,
    }

    Wave_Format_Type :: enum u16 {
        Int      = 1,
        Float    = 3,
        Extended = 65534,
    }

    Wave_FMT_Subchunk_Basic :: struct {
        subchunk_id:     [4]u8,
        subchunk_size:   u32,
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
        subchunk_id:   [4]u8,
        subchunk_size: u32,
        data:          []u8,
    }

    WAVE_MIN_FILE_SIZE :: size_of(Wave_RIFF_Chunk) + size_of(Wave_FMT_Subchunk_Basic) + size_of(Wave_DATA_Subchunk)

    // TODO: Process error https://github.com/pbremondFR/scop/blob/c7af2d6ecc4436d3e5a957b0bd78ba78543abe26/src/textures.odin#L62
    fd, err := os.open(file.fullpath, os.O_RDONLY)
    if err != nil {
        return nil, .Open_Failure
    }
    defer os.close(fd)

    data, error := virtual.map_file_from_file_descriptor(uintptr(fd), {.Read})
    defer virtual.release(raw_data(data), len(data))


    return nil, .None
}
