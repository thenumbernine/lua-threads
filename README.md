POSIX multithreading in LuaJIT.

Using a unique `lua_State` per thread (via [lua-lua](https://github.com/thenumbernine/lua-lua) ).

I spun this off of [CapsAdmin luajit-pureffi/threads.lua](https://github.com/CapsAdmin/luajit-pureffi/blob/main/threads.lua)
but moved the Lua calls into their own [library](https://github.com/thenumbernine/lua-lua),
and replaced the convenience of function-serialization and error-handling with code-injection,
which probably makes the result of this a lot more like [LuaLanes](https://github.com/LuaLanes/lanes).

Uses my [lua-ffi-bindings](https://github.com/thenumbernine/lua-ffi-bindings) for `unistd.h`, `pthread.h`, and `errno.h`.
