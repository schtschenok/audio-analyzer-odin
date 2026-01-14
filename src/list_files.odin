package main

import "base:runtime"
import "core:log"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strings"

List_Files_Error :: enum {
    None,
    Cant_Open_Root_Dir,
    Cant_Stat_Root_Dir,
    Cant_Read_Root_Dir,
    Root_Dir_Is_Not_Dir,
    No_Wav_Files_In_Root_Dir,
    Recursion_Too_Deep,
}

list_files :: proc(opt: Options, files: ^[dynamic]os.File_Info) -> List_Files_Error {
    trace("List Files")

    root_handle, root_open_error := os.open(opt.folder)

    if (root_open_error != 0) {
        log.errorf("Unable to open folder \"%s\"", opt.folder)
        return .Cant_Open_Root_Dir
    }

    defer os.close(root_handle)

    root_fileinfo, root_stat_error := os.fstat(root_handle, context.temp_allocator)

    if (root_stat_error != 0) {
        log.errorf("Unable to stat folder \"%s\"", opt.folder)
        return .Cant_Stat_Root_Dir
    }

    if !root_fileinfo.is_dir {
        log.errorf("\"%s\" not a dir", root_fileinfo.fullpath)
        return .Root_Dir_Is_Not_Dir
    }

    Recurse_Folder_Error :: enum {
        None,
        Cant_Read_Dir,
        Recursion_Too_Deep,
    }

    MAX_RECURSION_DEPTH :: 128

    recurse_folder :: proc(folder: os.Handle, files: ^[dynamic]os.File_Info, recursion_depth_counter: ^int) -> Recurse_Folder_Error {
        recursion_depth_counter^ = recursion_depth_counter^ + 1

        if (recursion_depth_counter^ > MAX_RECURSION_DEPTH) {
            return .Recursion_Too_Deep
        }

        entries, readdir_error := os.read_dir(folder, -1, allocator = context.temp_allocator)
        if (readdir_error != 0) {
            return .Cant_Read_Dir
        }

        for entry in entries {
            if entry.is_dir {
                entry_handle, entry_open_error := os.open(entry.fullpath)
                defer os.close(entry_handle)

                if (entry_open_error == 0) {
                    recurse_error := recurse_folder(entry_handle, files, recursion_depth_counter)
                    recursion_depth_counter^ = recursion_depth_counter^ - 1

                    switch recurse_error {
                    case .None:
                        continue
                    case .Cant_Read_Dir:
                        log.warnf("Can't read subdirectory, skipping: \"%s\"", entry.fullpath)
                        continue
                    case .Recursion_Too_Deep:
                        return .Recursion_Too_Deep
                    }
                } else {
                    log.warnf("Can't open subdirectory, skipping: \"%s\"", entry.fullpath)
                    continue
                }
            } else {
                if (!strings.ends_with(entry.name, ".wav")) {
                    // log.infof("File with different extension than \".wav\" encountered, skipping: \"%s\"", entry.fullpath)
                    continue
                }

                entry_handle, entry_open_error := os.open(entry.fullpath)
                defer os.close(entry_handle)

                if (entry_open_error != 0) {
                    log.warnf("Can't open file, skipping: \"%s\"", entry.fullpath)
                    continue
                }

                fullpath := strings.clone_from(entry.fullpath, allocator = context.allocator) // Allocates on  main allocator
                valid_entry := entry
                valid_entry.fullpath = fullpath
                append(files, valid_entry)
            }
        }

        return .None
    }

    recursion_depth_counter: int = 0
    recurse_error := recurse_folder(root_handle, files, &recursion_depth_counter)

    if (recurse_error == .Cant_Read_Dir) {
        log.errorf("Unable to read folder \"%s\"", root_fileinfo.fullpath)
        return .Cant_Read_Root_Dir
    } else if (recurse_error == .Recursion_Too_Deep) {
        log.errorf("Recursion is too deep (>%d) in folder \"%s\"", MAX_RECURSION_DEPTH, root_fileinfo.fullpath)
        return .Recursion_Too_Deep
    }

    if len(files) == 0 {
        log.errorf("No files with \".wav\" extension in folder \"%s\"", root_fileinfo.fullpath)
        return .No_Wav_Files_In_Root_Dir
    }

    {
        trace("Sort")

        sort.quick_sort_proc(files[:], proc(a, b: os.File_Info) -> int { return int(a.size - b.size) })     // Ascending
        // sort.quick_sort_proc(files[:], proc(a, b: os.File_Info) -> int { return int(b.size - a.size) })     // Descending
    }

    return .None
}
