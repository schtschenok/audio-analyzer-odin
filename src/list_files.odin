package main

import "base:runtime"
import "core:log"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strings"

List_Files_Error :: enum {
    None,
    CantOpenRootDir,
    CantStatRootDir,
    CantReadRootDir,
    RootDirIsNotDir,
    NoWavFilesInRootDir,
    RecursionTooDeep,
}

list_files :: proc(opt: Options, files: ^[dynamic]os.File_Info) -> List_Files_Error {
    context.allocator = mem.panic_allocator()

    root_handle, root_open_error := os.open(opt.folder)

    if (root_open_error != 0) {
        log.errorf("Unable to open folder \"%s\"", opt.folder)
        return .CantOpenRootDir
    }

    defer os.close(root_handle)

    root_fileinfo, root_stat_error := os.fstat(root_handle, context.temp_allocator)

    if (root_stat_error != 0) {
        log.errorf("Unable to stat folder \"%s\"", opt.folder)
        return .CantStatRootDir
    }

    if !root_fileinfo.is_dir {
        log.errorf("\"%s\" not a dir", root_fileinfo.fullpath)
        return .RootDirIsNotDir
    }

    Recurse_Folder_Error :: enum {
        None,
        CantReadDir,
        RecursionTooDeep,
    }

    MAX_RECURSION_DEPTH :: 128

    recurse_folder :: proc(folder: os.Handle, files: ^[dynamic]os.File_Info, recursion_depth_counter: ^int) -> Recurse_Folder_Error {
        recursion_depth_counter^ = recursion_depth_counter^ + 1

        if (recursion_depth_counter^ > MAX_RECURSION_DEPTH) {
            return .RecursionTooDeep
        }

        entries, readdir_error := os.read_dir(folder, -1, allocator = context.temp_allocator)

        if (readdir_error != 0) {
            return .CantReadDir
        }

        for entry in entries {
            if entry.is_dir {
                entry_handle, entry_open_error := os.open(entry.fullpath)
                defer os.close(entry_handle)
                if (entry_open_error == 0) {
                    recurse_error := recurse_folder(entry_handle, files, recursion_depth_counter)
                    recursion_depth_counter^ = recursion_depth_counter^ - 1
                    #partial switch recurse_error {
                    case .None:
                        continue
                    case .CantReadDir:
                        log.warnf("Can't read subdirectory, skipping: \"%s\"", entry.fullpath)
                        continue
                    case .RecursionTooDeep:
                        return .RecursionTooDeep
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
                append(files, entry)
            }
        }

        return .None
    }

    recursion_depth_counter: int = 0
    recurse_error := recurse_folder(root_handle, files, &recursion_depth_counter)

    if (recurse_error == .CantReadDir) {
        log.errorf("Unable to read folder \"%s\"", root_fileinfo.fullpath)
        return .CantReadRootDir
    } else if (recurse_error == .RecursionTooDeep) {
        log.errorf("Recursion is too deep (>%d) in folder \"%s\"", MAX_RECURSION_DEPTH, root_fileinfo.fullpath)
        return .RecursionTooDeep
    }

    if len(files) == 0 {
        log.errorf("No files with \".wav\" extension in folder \"%s\"", root_fileinfo.fullpath)
        return .NoWavFilesInRootDir
    }

    // sort.quick_sort_proc(files[:], proc(a, b: os.File_Info) -> int { return int(a.size - b.size) }) // Ascending
    sort.quick_sort_proc(files[:], proc(a, b: os.File_Info) -> int { return int(b.size - a.size) })     // Descending

    return .None
}
