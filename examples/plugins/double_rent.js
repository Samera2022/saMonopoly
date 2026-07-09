// 双倍租金插件：所有租金翻倍
// 文件名：double_rent.js
// 功能：拦截 core:rent_due 事件，将金额翻倍

function on_pre_command(commandType, payload) {
    if (commandType === "core:rent_due") {
        var amount = payload["amount"] * 2;
        print("[JSPlugin] 租金翻倍: " + amount);
        return JSON.stringify({ action: "modify", payload: { amount: amount } });
    }
    return JSON.stringify({ action: "continue" });
}

print("[JSPlugin] double_rent.js loaded!");
