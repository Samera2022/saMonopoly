-- 免租插件：拦截 core:rent_due 事件，取消租金支付
-- 文件名：free_rent.lua

local function parse_json(str)
    -- 简单的 JSON 解析（仅用于检查 tile_id）
    -- 在实际插件中应使用真正的 JSON 库
    return str
end

function on_pre_command(command_type, payload_json)
    if command_type == "core:rent_due" then
        -- 检查 payload 是否包含 prop_1（通过字符串匹配）
        if string.find(payload_json, "prop_1") then
            print("[LuaPlugin] 在 prop_1 上免租!")
            return '{"action":"cancel","reason":"lua_free_rent"}'
        end
    end
    return '{"action":"continue"}'
end

print("[LuaPlugin] free_rent.lua 已加载!")
