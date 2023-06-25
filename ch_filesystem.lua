local filesystem = memory.create_interface("filesystem_stdio.dll", "VBaseFileSystem011")
local filesystem_class = ffi.cast(ffi.typeof("void***"), filesystem)
local filesystem_vftbl = filesystem_class[0]
local func_read_file = ffi.cast("int (__thiscall*)(void*, void*, int, void*)", filesystem_vftbl[0])
local func_write_file = ffi.cast("int (__thiscall*)(void*, void const*, int, void*)", filesystem_vftbl[1])
local func_open_file = ffi.cast("void* (__thiscall*)(void*, const char*, const char*, const char*)", filesystem_vftbl[2])
local func_close_file = ffi.cast("void (__thiscall*)(void*, void*)", filesystem_vftbl[3])
local func_get_file_size = ffi.cast("unsigned int (__thiscall*)(void*, void*)", filesystem_vftbl[7])
local func_file_exists = ffi.cast("bool (__thiscall*)(void*, const char*, const char*)", filesystem_vftbl[10])
local full_filesystem = memory.create_interface("filesystem_stdio.dll", "VFileSystem017")
local full_filesystem_class = ffi.cast(ffi.typeof("void***"), full_filesystem)
local full_filesystem_vftbl = full_filesystem_class[0]
local func_create_dir_hierarchy = ffi.cast("void (__thiscall*)(void*, const char*, const char*)", full_filesystem_vftbl[22])
local MODES = {
    ["r"] = "r",
    ["w"] = "w",
    ["a"] = "a",
    ["r+"] = "r+",
    ["w+"] = "w+",
    ["a+"] = "a+",
    ["rb"] = "rb",
    ["wb"] = "wb",
    ["ab"] = "ab",
    ["rb+"] = "rb+",
    ["wb+"] = "wb+",
    ["ab+"] = "ab+",
}
local FileSystem = {}
FileSystem.__index = FileSystem
function FileSystem.exists(file, path_id)
    return func_file_exists(filesystem_class, file, path_id)
end
function FileSystem.create_directory(path, path_id)
    func_create_dir_hierarchy(full_filesystem_class, path, path_id)
end
function FileSystem.open(file, mode, path_id)
    if not MODES[mode] then error("Invalid mode!") end
    local self = setmetatable({
        file = file,
        mode = mode,
        path_id = path_id,
        handle = func_open_file(filesystem_class, file, mode, path_id)
    }, FileSystem)
    return self
end
function FileSystem:get_size()
    return func_get_file_size(filesystem_class, self.handle)
end
function FileSystem:write(buffer)
    func_write_file(filesystem_class, buffer, #buffer, self.handle)
end
function FileSystem:read()
    local size = self:get_size()
    local output = ffi.new("char[?]", size + 1)
    func_read_file(filesystem_class, output, size, self.handle)
    return ffi.string(output)
end
function FileSystem:close()
    func_close_file(filesystem_class, self.handle)
end

return FileSystem
