local Png = {}
Png.__index = Png

local charbuffer = ffi.typeof("unsigned char[?]")
local uintbuffer = ffi.typeof("unsigned int[?]")

local DEFLATE_MAX_BLOCK_SIZE = 65535

local function putBigUint32(val, tbl, index)
    for i=0,3 do
        tbl[index + i] = bit.band(bit.rshift(val, (3 - i) * 8), 0xFF)
    end
end

function Png:writeBytes(data, index, len)
    index = index or 1
    len = len or #data
    for i=index,index+len-1 do
        table.insert(self.output, string.char(data[i]))
    end
end

function Png:write(pixels)
    local count = #pixels  -- Byte count
    local pixelPointer = 1
    while count > 0 do
        if self.positionY >= self.height then
            error("All image pixels already written")
        end

        if self.deflateFilled == 0 then -- Start DEFLATE block
            local size = DEFLATE_MAX_BLOCK_SIZE;
            if (self.uncompRemain < size) then
                size = self.uncompRemain
            end
            local header = {  -- 5 bytes long
                bit.band((self.uncompRemain <= DEFLATE_MAX_BLOCK_SIZE and 1 or 0), 0xFF),
                bit.band(bit.rshift(size, 0), 0xFF),
                bit.band(bit.rshift(size, 8), 0xFF),
                bit.band(bit.bxor(bit.rshift(size, 0), 0xFF), 0xFF),
                bit.band(bit.bxor(bit.rshift(size, 8), 0xFF), 0xFF),
            }
            self:writeBytes(header)
            self:crc32(header, 1, #header)
        end
        assert(self.positionX < self.lineSize and self.deflateFilled < DEFLATE_MAX_BLOCK_SIZE);

        if (self.positionX == 0) then  -- Beginning of line - write filter method byte
            local b = {0}
            self:writeBytes(b)
            self:crc32(b, 1, 1)
            self:adler32(b, 1, 1)
            self.positionX = self.positionX + 1
            self.uncompRemain = self.uncompRemain - 1
            self.deflateFilled = self.deflateFilled + 1
        else -- Write some pixel bytes for current line
            local n = DEFLATE_MAX_BLOCK_SIZE - self.deflateFilled;
            if (self.lineSize - self.positionX < n) then
                n = self.lineSize - self.positionX
            end
            if (count < n) then
                n = count;
            end
            assert(n > 0);

            self:writeBytes(pixels, pixelPointer, n)

            -- Update checksums
            self:crc32(pixels, pixelPointer, n);
            self:adler32(pixels, pixelPointer, n);

            -- Increment positions
            count = count - n;
            pixelPointer = pixelPointer + n;
            self.positionX = self.positionX + n;
            self.uncompRemain = self.uncompRemain - n;
            self.deflateFilled = self.deflateFilled + n;
        end

        if (self.deflateFilled >= DEFLATE_MAX_BLOCK_SIZE) then
            self.deflateFilled = 0; -- End current block
        end

        if (self.positionX == self.lineSize) then  -- Increment line
            self.positionX = 0;
            self.positionY = self.positionY + 1;
            if (self.positionY == self.height) then -- Reached end of pixels
                local footer = {  -- 20 bytes long
                    0, 0, 0, 0,  -- DEFLATE Adler-32 placeholder
                    0, 0, 0, 0,  -- IDAT CRC-32 placeholder
                    -- IEND chunk
                    0x00, 0x00, 0x00, 0x00,
                    0x49, 0x45, 0x4E, 0x44,
                    0xAE, 0x42, 0x60, 0x82,
                }
                putBigUint32(self.adler, footer, 1)
                self:crc32(footer, 1, 4)
                putBigUint32(self.crc, footer, 5)
                self:writeBytes(footer)
                self.done = true
            end
        end
    end
end

function Png:crc32(data, index, len)
    self.crc = bit.bnot(self.crc)
    for i=index,index+len-1 do
        local byte = data[i]
        for j=0,7 do  -- Inefficient bitwise implementation, instead of table-based
            local nbit = bit.band(bit.bxor(self.crc, bit.rshift(byte, j)), 1);
            self.crc = bit.bxor(bit.rshift(self.crc, 1), bit.band((-nbit), 0xEDB88320));
        end
    end
    self.crc = bit.bnot(self.crc)
end
function Png:adler32(data, index, len)
    local s1 = bit.band(self.adler, 0xFFFF)
    local s2 = bit.rshift(self.adler, 16)
    for i=index,index+len-1 do
        s1 = (s1 + data[i]) % 65521
        s2 = (s2 + s1) % 65521
    end
    self.adler = bit.bor(bit.lshift(s2, 16), s1)
end

local function begin(width, height, colorMode)
    -- Default to rgb
    colorMode = colorMode or "rgb"

    -- Determine bytes per pixel and the PNG internal color type
    local bytesPerPixel, colorType
    if colorMode == "rgb" then
        bytesPerPixel, colorType = 3, 2
    elseif colorMode == "rgba" then
        bytesPerPixel, colorType = 4, 6
    else
        error("Invalid colorMode")
    end

    local state = setmetatable({ width = width, height = height, done = false, output = {} }, Png)

    -- Compute and check data siezs
    state.lineSize = width * bytesPerPixel + 1
    -- TODO: check if lineSize too big

    state.uncompRemain = state.lineSize * height

    local numBlocks = math.ceil(state.uncompRemain / DEFLATE_MAX_BLOCK_SIZE)

    -- 5 bytes per DEFLATE uncompressed block header, 2 bytes for zlib header, 4 bytes for zlib Adler-32 footer
    local idatSize = numBlocks * 5 + 6
    idatSize = idatSize + state.uncompRemain;

    -- TODO check if idatSize too big

    local header = {  -- 43 bytes long
        -- PNG header
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        -- IHDR chunk
        0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52,
        0, 0, 0, 0,  -- 'width' placeholder
        0, 0, 0, 0,  -- 'height' placeholder
        0x08, colorType, 0x00, 0x00, 0x00,
        0, 0, 0, 0,  -- IHDR CRC-32 placeholder
        -- IDAT chunk
        0, 0, 0, 0,  -- 'idatSize' placeholder
        0x49, 0x44, 0x41, 0x54,
        -- DEFLATE data
        0x08, 0x1D,
    }
    putBigUint32(width, header, 17)
    putBigUint32(height, header, 21)
    putBigUint32(idatSize, header, 34)

    state.crc = 0
    state:crc32(header, 13, 17)
    putBigUint32(state.crc, header, 30)
    state:writeBytes(header)

    state.crc = 0
    state:crc32(header, 38, 6);  -- 0xD7245B6B
    state.adler = 1

    state.positionX = 0
    state.positionY = 0
    state.deflateFilled = 0

    return state
end

ffi.cdef([[
	typedef struct
	{
		void* steam_client;
		void* steam_user;
		void* steam_friends;
		void* steam_utils;
		void* steam_matchmaking;
		void* steam_user_stats;
		void* steam_apps;
		void* steam_matchmakingservers;
		void* steam_networking;
		void* steam_remotestorage;
		void* steam_screenshots;
		void* steam_http;
		void* steam_unidentifiedmessages;
		void* steam_controller;
		void* steam_ugc;
		void* steam_applist;
		void* steam_music;
		void* steam_musicremote;
		void* steam_htmlsurface;
		void* steam_inventory;
		void* steam_video;
	} S_steamApiCtx_t;
]])

local pS_SteamApiCtx = ffi.cast(
	"S_steamApiCtx_t**", ffi.cast(
		"char*",
		memory.find_pattern(
			"client.dll",
			"FF 15 ?? ?? ?? ?? B9 ?? ?? ?? ?? E8 ?? ?? ?? ?? 6A"
		)
	) + 7
)[0] or error("invalid interface", 2)

local native_ISteamFriends = ffi.cast("void***", pS_SteamApiCtx.steam_friends)
local native_ISteamUtils = ffi.cast("void***", pS_SteamApiCtx.steam_utils)
local native_ISteamFriends_GetSmallFriendAvatar = ffi.cast("int(__thiscall*)(void*, uint64_t)" ,native_ISteamFriends[0][34] )
local native_ISteamUtils_GetImageSize = ffi.cast("bool(__thiscall*)(void*, int, uint32_t*, uint32_t*)" , native_ISteamUtils[0][5])
local native_ISteamUtils_GetImageRGBA =  ffi.cast("bool(__thiscall*)(void*, int, unsigned char*, int)" , native_ISteamUtils[0][6])

local get_avatar = function(steamid)
    local penis = nil
    local handle = native_ISteamFriends_GetSmallFriendAvatar( native_ISteamFriends , tonumber(steamid:sub(4, -1)) + 76500000000000000ULL)

    local image_bytes = ""

    if handle > 0 then
        local width = uintbuffer(1)
        local height = uintbuffer(1)
        if native_ISteamUtils_GetImageSize(native_ISteamUtils, handle, width, height) then
            if width[0] > 0 and height[0] > 0 then
                local rgba_buffer_size = width[0]*height[0]*4
                local rgba_buffer = charbuffer(rgba_buffer_size)
                if native_ISteamUtils_GetImageRGBA(native_ISteamUtils, handle, rgba_buffer, rgba_buffer_size) then
                    local png = begin(width[0], height[0], "rgba")
                    for x =0 , width[0]-1 do
                        for y =0, height[0]-1 do
                            local sub_penis = x*(height[0]*4) + y*4
                            png:write { rgba_buffer[sub_penis], rgba_buffer[sub_penis+1], rgba_buffer[sub_penis+2], rgba_buffer[sub_penis+3]}
                        end
                    end
                    penis = png.output
                end
            end
        end
    elseif handle ~= -1 then
        penis = nil
    end

    if not penis then return end
    for i=1 ,#penis do
        image_bytes = image_bytes..penis[i]
    end

    local image_loaded = render.load_image_buffer(image_bytes)

    return image_loaded
end

local avatars = {}
avatars.data = {}
avatars.default_image = render.load_image_buffer("\xFF\xD8\xFF\xE0\x00\x10\x4A\x46\x49\x46\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xFE\x00\x3B\x43\x52\x45\x41\x54\x4F\x52\x3A\x20\x67\x64\x2D\x6A\x70\x65\x67\x20\x76\x31\x2E\x30\x20\x28\x75\x73\x69\x6E\x67\x20\x49\x4A\x47\x20\x4A\x50\x45\x47\x20\x76\x36\x32\x29\x2C\x20\x71\x75\x61\x6C\x69\x74\x79\x20\x3D\x20\x38\x30\x0A\xFF\xDB\x00\x43\x00\x06\x04\x05\x06\x05\x04\x06\x06\x05\x06\x07\x07\x06\x08\x0A\x10\x0A\x0A\x09\x09\x0A\x14\x0E\x0F\x0C\x10\x17\x14\x18\x18\x17\x14\x16\x16\x1A\x1D\x25\x1F\x1A\x1B\x23\x1C\x16\x16\x20\x2C\x20\x23\x26\x27\x29\x2A\x29\x19\x1F\x2D\x30\x2D\x28\x30\x25\x28\x29\x28\xFF\xDB\x00\x43\x01\x07\x07\x07\x0A\x08\x0A\x13\x0A\x0A\x13\x28\x1A\x16\x1A\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\x28\xFF\xC0\x00\x11\x08\x00\x40\x00\x40\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01\xFF\xC4\x00\x1F\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\xFF\xC4\x00\xB5\x10\x00\x02\x01\x03\x03\x02\x04\x03\x05\x05\x04\x04\x00\x00\x01\x7D\x01\x02\x03\x00\x04\x11\x05\x12\x21\x31\x41\x06\x13\x51\x61\x07\x22\x71\x14\x32\x81\x91\xA1\x08\x23\x42\xB1\xC1\x15\x52\xD1\xF0\x24\x33\x62\x72\x82\x09\x0A\x16\x17\x18\x19\x1A\x25\x26\x27\x28\x29\x2A\x34\x35\x36\x37\x38\x39\x3A\x43\x44\x45\x46\x47\x48\x49\x4A\x53\x54\x55\x56\x57\x58\x59\x5A\x63\x64\x65\x66\x67\x68\x69\x6A\x73\x74\x75\x76\x77\x78\x79\x7A\x83\x84\x85\x86\x87\x88\x89\x8A\x92\x93\x94\x95\x96\x97\x98\x99\x9A\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xD2\xD3\xD4\xD5\xD6\xD7\xD8\xD9\xDA\xE1\xE2\xE3\xE4\xE5\xE6\xE7\xE8\xE9\xEA\xF1\xF2\xF3\xF4\xF5\xF6\xF7\xF8\xF9\xFA\xFF\xC4\x00\x1F\x01\x00\x03\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\xFF\xC4\x00\xB5\x11\x00\x02\x01\x02\x04\x04\x03\x04\x07\x05\x04\x04\x00\x01\x02\x77\x00\x01\x02\x03\x11\x04\x05\x21\x31\x06\x12\x41\x51\x07\x61\x71\x13\x22\x32\x81\x08\x14\x42\x91\xA1\xB1\xC1\x09\x23\x33\x52\xF0\x15\x62\x72\xD1\x0A\x16\x24\x34\xE1\x25\xF1\x17\x18\x19\x1A\x26\x27\x28\x29\x2A\x35\x36\x37\x38\x39\x3A\x43\x44\x45\x46\x47\x48\x49\x4A\x53\x54\x55\x56\x57\x58\x59\x5A\x63\x64\x65\x66\x67\x68\x69\x6A\x73\x74\x75\x76\x77\x78\x79\x7A\x82\x83\x84\x85\x86\x87\x88\x89\x8A\x92\x93\x94\x95\x96\x97\x98\x99\x9A\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xD2\xD3\xD4\xD5\xD6\xD7\xD8\xD9\xDA\xE2\xE3\xE4\xE5\xE6\xE7\xE8\xE9\xEA\xF2\xF3\xF4\xF5\xF6\xF7\xF8\xF9\xFA\xFF\xDA\x00\x0C\x03\x01\x00\x02\x11\x03\x11\x00\x3F\x00\xF0\x89\xE6\x93\xCF\x93\xF7\x8F\xF7\x8F\xF1\x1F\x5A\x67\x9D\x27\xFC\xF4\x7F\xFB\xE8\xD1\x3F\xFA\xF9\x3F\xDE\x3F\xCE\x99\x40\x0F\xF3\xA4\xFF\x00\x9E\x8F\xFF\x00\x7D\x1A\x3C\xE9\x3F\xE7\xA3\xFF\x00\xDF\x46\x99\x5A\x3A\x2E\x87\xAA\xEB\x93\x34\x5A\x3E\x9D\x75\x7A\xEB\xF7\x84\x11\x17\xDB\xF5\x23\xA7\xE3\x40\x14\x7C\xE9\x3F\xE7\xA3\xFF\x00\xDF\x46\x8F\x3A\x4F\xF9\xE8\xFF\x00\xF7\xD1\xAD\x1D\x6F\xC3\xBA\xCE\x86\x57\xFB\x63\x4B\xBC\xB2\x0F\xC2\xB4\xD1\x15\x56\xFA\x1E\x86\xB2\xE8\x01\xFE\x74\x9F\xF3\xD1\xFF\x00\xEF\xA3\x4F\x82\x69\x3C\xF8\xFF\x00\x78\xFF\x00\x78\x7F\x11\xF5\xA8\x69\xF0\x7F\xAF\x8F\xFD\xE1\xFC\xE8\x00\x9F\xFD\x7C\x9F\xEF\x1F\xE7\x4C\xA7\xCF\xFE\xBE\x4F\xF7\x8F\xF3\xA6\x50\x05\xDD\x13\x4F\x7D\x5B\x59\xB0\xD3\xA2\x60\xB2\x5D\xCF\x1C\x0A\x4F\x62\xCC\x14\x1F\xD6\xBE\xA8\xF1\x77\x88\x74\x8F\x84\x5E\x12\xD3\xED\x34\xDD\x3C\x4A\xD2\x13\x1C\x10\x06\xD9\xBC\x80\x37\x48\xED\x8E\xBC\x8C\xFA\x93\x5F\x27\x5B\xCF\x2D\xB5\xC4\x73\xDB\xC8\xF1\x4D\x13\x07\x49\x11\x8A\xB2\xB0\x39\x04\x11\xD0\x83\x56\xF5\x4D\x67\x53\xD5\xFC\xBF\xED\x5D\x46\xF2\xF7\xCB\xCE\xCF\xB4\x4C\xD2\x6D\xCF\x5C\x64\x9C\x74\x14\x01\xF5\x17\xC3\xEF\x1C\xE9\x9F\x14\x74\xDD\x47\x4B\xD5\x74\xC4\x8A\x54\x4C\xCD\x6C\xED\xE6\x24\x88\x4E\x37\x29\xC0\x20\x83\xF9\x71\x83\x5F\x34\xF8\xDB\x44\x1E\x1C\xF1\x66\xA9\xA4\xAB\x17\x4B\x59\xCA\x23\x1E\xA5\x0F\x2B\x9F\x7C\x11\x5F\x42\x7C\x16\xF0\xA4\x5E\x06\xF0\x9D\xDF\x88\xBC\x40\xE2\xDA\xE6\xE6\x11\x2C\x9E\x67\x1E\x44\x23\x90\x0F\xFB\x47\xA9\x1F\x41\xD6\xBE\x7A\xF1\xAE\xB7\xFF\x00\x09\x1F\x8A\xF5\x4D\x58\x21\x44\xBA\x98\xBA\x29\xEA\x13\xA2\x83\xEF\x80\x28\x03\x16\x9F\x07\xFA\xF8\xFF\x00\xDE\x1F\xCE\x99\x4F\x83\xFD\x7C\x7F\xEF\x0F\xE7\x40\x04\xFF\x00\xEB\xE4\xFF\x00\x78\xFF\x00\x3A\x65\x3E\x7F\xF5\xF2\x7F\xBC\x7F\x9D\x32\x80\x0A\xED\xFE\x0B\x69\x96\xDA\xBF\xC4\xAD\x1E\xDA\xF6\x31\x24\x0A\xCF\x31\x46\x19\x0C\x51\x19\x86\x7D\xB2\x05\x71\x15\xD3\xFC\x36\xD3\x75\x4D\x5F\xC6\x16\x76\x5A\x0E\xA0\x74\xED\x42\x45\x90\xC7\x72\x19\x97\x68\x08\x49\xE5\x79\xE4\x02\x3F\x1A\x00\xF5\x1F\xDA\x6F\xC4\xF7\x62\xFE\xCF\xC3\x70\x31\x8E\xCF\xCA\x5B\xA9\xF1\xD6\x46\x2C\xC1\x41\xF6\x1B\x73\xF5\x3E\xD5\xE0\xF5\xD8\xFC\x56\xD1\xF5\xAD\x13\xC4\xE9\x6B\xE2\x3D\x50\xEA\x97\xA6\xDD\x1C\x4E\x5D\x9B\x08\x4B\x61\x72\xDC\xF5\x07\xF3\xAE\x3A\x80\x0A\x7C\x1F\xEB\xE3\xFF\x00\x78\x7F\x3A\x65\x3E\x0F\xF5\xF1\xFF\x00\xBC\x3F\x9D\x00\x13\xFF\x00\xAF\x93\xFD\xE3\xFC\xE9\x95\x34\xF0\xC9\xE7\xC9\xFB\xB7\xFB\xC7\xF8\x4F\xAD\x33\xC9\x93\xFE\x79\xBF\xFD\xF2\x68\x01\x95\x7B\x43\xD5\xEF\xF4\x2D\x4A\x2D\x43\x49\xB8\x6B\x6B\xC8\xC1\x09\x22\x80\x48\xC8\x20\xF5\x04\x74\x26\xAA\x79\x32\x7F\xCF\x37\xFF\x00\xBE\x4D\x1E\x4C\x9F\xF3\xCD\xFF\x00\xEF\x93\x40\x1A\x1E\x21\xD7\xB5\x3F\x11\x5F\x8B\xDD\x6A\xED\xAE\xEE\x82\x08\xC4\x8C\xA0\x1D\xA0\x92\x07\x00\x7A\x9A\xCC\xA7\xF9\x32\x7F\xCF\x37\xFF\x00\xBE\x4D\x1E\x4C\x9F\xF3\xCD\xFF\x00\xEF\x93\x40\x0C\xA7\xC1\xFE\xBE\x3F\xF7\x87\xF3\xA3\xC9\x93\xFE\x79\xBF\xFD\xF2\x69\xF0\x43\x27\x9F\x1F\xEE\xDF\xEF\x0F\xE1\x3E\xB4\x01\xFF\xD9")
avatars.fn_create_item = function(name)
    avatars.data[name] = {}
    avatars.data[name].url = nil
    avatars.data[name].image = nil
    avatars.data[name].loaded = false
    avatars.data[name].loading = false
end
avatars.fn_get_avatar = function(name, entindex)
    if avatars.data[name] and avatars.data[name].loaded then
        return avatars.data[name].image
    end

    if avatars.data[name] == nil then
        avatars.fn_create_item(name)
        local _, steam_id = entity_list.get_entity(name):get_steamids()

        if #steam_id<5 then return end
        if steam_id == nil or avatars.default_image == nil then
            return nil
        end
        avatars.data[name].image = get_avatar(steam_id)
        avatars.data[name].loaded = true
    end
    return avatars.default_image
end

return avatars
