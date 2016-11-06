local enumerable = {}

local enumerator_cache = setmetatable({}, {__mode = 'k'})

local no_args = function(...)
    return select('#', ...) == 0
end

local true_fn = function(...)
    return true
end

enumerable.enumerate = function(t)
    local iterator, table, key = pairs(t)
    return function(t, k)
        local key, value = iterator(t, k)
        return value, key
    end, table, key
end

enumerable.count = function(t, fn)
    local count = 0

    -- The == t is there because Lua, for some reason, passes the table twice when using __len
    if fn == nil or fn == t then
        fn = true_fn
    end

    for _, v in pairs(t) do
        if fn(v) == true then
            count = count + 1
        end
    end

    return count
end

enumerable.any = function(t, fn)
    fn = fn or true_fn

    for _, v in pairs(t) do
        if fn(v) == true then
            return true
        end
    end

    return false
end

enumerable.all = function(t, fn)
    fn = fn or true_fn

    for _, v in pairs(t) do
        if fn(v) == false then
            return false
        end
    end

    return true
end

enumerable.contains = function(t, search)
    for _, el in pairs(t) do
        if el == search then
            return true
        end
    end

    return false
end

enumerable.first = function(t, fn)
    fn = fn or true_fn

    for k, v in pairs(t) do
        if fn(v, k, t) then
            return v
        end
    end

    return nil
end

enumerable.single = function(t, fn)
    fn = fn or true_fn

    for k, v in pairs(t) do
        if fn(v, k, t) then
            if res ~= nil then
                return nil
            else
                res = v
            end
        end
    end

    return nil
end

enumerable.aggregate = function(t, fn, ...)
    local initialized = not no_args(...)
    local res = ...

    for key, el in pairs(t) do
        if not initialized then
            res = el
            initialized = true
        else
            res = fn(res, el, key, t)
        end
    end

    return res
end


enumerable.totable = function(t)
    local arr = {}
    local key = 0
    for _, el in pairs(t) do
        key = key + 1
        arr[key] = el
    end

    return arr
end

local lazy_functions = {
    select = function(constructor, original, fn)
        local res = constructor()

        enumerator_cache[res] = function(res)
            local iterator, table, key = pairs(original)
            return function(t, k)
                local key, value = iterator(t, k)
                if key == nil then
                    return nil, nil
                end

                return key, fn(value, key, original)
            end, table, key
        end

        return res
    end,
    where = function(constructor, original, fn)
        local res = constructor()

        enumerator_cache[res] = function(res)
            local iterator, table, key = pairs(original)
            return function(t, k)
                local key, value = iterator(t, k)
                while key ~= nil and not fn(value, key, original) do
                    key, value = iterator(t, key)
                end

                return key, value
            end, table, key
        end

        return res
    end,
    take = function(constructor, original, max)
        local res = constructor()

        enumerator_cache[res] = function(res)
            local iterator, table, key = pairs(original)
            local count = 0
            return function(t, k)
                count = count + 1
                if count > max then
                    return nil, nil
                end

                return iterator(t, k)
            end, table, key
        end

        return res
    end,
    skip = function(constructor, original, count)
        local res = constructor()

        enumerator_cache[res] = function(res)
            local iterator, table, key = pairs(original)
            local count = count
            return function(t, k)
                local key, value = iterator(t, k)
                while key ~= nil and count > 0 do
                    count = count - 1
                    key, value = iterator(t, key)
                end

                return key, value
            end, table, key
        end

        return res
    end,
}

local dependent_functions = {
    add = {
        copy = function(constructor, add, original)
            local res = constructor()
            for key, el in pairs(original) do
                add(res, el, key)
            end

            return res
        end,
    },
    remove = {
        clear = function(constructor, remove, t)
            for key in pairs(t) do
                remove(t, key)
            end

            return t
        end,
    },
}

local build_index = function(constructor, proxies)
    local index = {}

    for name, fn in pairs(proxies) do
        index[name] = fn
    end

    for name, fn in pairs(enumerable) do
        index[name] = fn
    end

    if constructor ~= nil then
        for name, fn in pairs(lazy_functions) do
            index[name] = function(...)
                return fn(constructor, ...)
            end
        end

        for proxy_name, proxy in pairs(proxies) do
            for name, fn in pairs(dependent_functions[proxy_name]) do
                index[name] = function(...)
                    return fn(constructor, proxy, ...)
                end
            end
        end
    end

    return index
end

local find_index = function(t, k, index, original, constructor)
    if original == nil then
        return index[k]
    end

    if enumerator_cache[t] == nil or type(original) ~= 'function' then
        return original
    end

    return function(discard, ...)
        return original(constructor(t), ...)
    end
end

local index_cache = {}
return function(meta, name)
    -- Create default/copy constructor if none available
    if meta.__create == nil then
        meta.__create = function(t)
            local res = {}
            local key = 0
            for _, el in pairs(t or {}) do
                key = key + 1
                res[key] = el
            end
            return setmetatable(res, meta)
        end
    end

    -- Create default addition function
    if meta.__add_element == nil then
        meta.__add_element = function(t, v, k)
            rawset(t, k, v)
        end
    end

    -- Create default removal function
    if meta.__remove_key == nil then
        meta.__remove_key = function(t, k)
            rawset(t, k, nil)
        end
    end

    local constructor = meta.__create
    local add = meta.__add_element
    local remove = meta.__remove_key

    local index = build_index(constructor, {
        add = add,
        remove = remove,
    })
    index_cache[#index_cache + 1] = index

    -- __index
    local original = meta.__index
    local index_type = type(original)
    if index_type == 'nil' then
        meta.__index = index
    elseif index_type == 'table' then
        meta.__index = function(t, k)
            return find_index(t, k, index, original[k], constructor)
        end
    elseif index_type == 'function' then
        meta.__index = function(t, k)
            return find_index(t, k, index, original(t, k), constructor)
        end
    else
        error(('Unknown indexing index_type: %s'):format(type))
    end

    local get_index = function(key)
        return type(meta.__index) == 'table' and meta.__index[key] or meta.__index(nil, key)
    end

    -- __len
    if meta.__len == nil then
        meta.__len = get_index('count')
    end

    -- Lazy evaluation
    -- If __pairs is not provided, it should default to pairs, but we can't use pairs itself
    -- or it will go to the __pairs metamethod again and infinitely recurse, so we provide a
    -- custom pairs implementation
    local enumerator = meta.__pairs or function(t)
        return next, t, nil
    end
    meta.__pairs = function(original)
        return (enumerator_cache[original] or enumerator)(original)
    end

    -- Implement toX function as a constructor call
    if name ~= nil then
        local key = 'to' .. name
        enumerable[key] = constructor
        for _, index in pairs(index_cache) do
            index[key] = constructor
        end
    end

    return meta.__create
end

--[[
Copyright © 2016, Windower
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
    * Neither the name of Windower nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL Windower BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]

