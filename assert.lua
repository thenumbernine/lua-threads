local errno = require 'ffi.req' 'c.errno'
local function thread_assert(err, msg)
	if err == 0 then return end
	error(ffi.string(ffi.C.strerror(err))..(msg and ' '..msg or ''))
end
return thread_assert
