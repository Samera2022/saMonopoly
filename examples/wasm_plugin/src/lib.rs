//! 免租 WASM 插件
//!
//! 编译方法：
//!   cargo build -p wasm-rent-free --target wasm32-wasip1 --release
//!
//! 输出：target/wasm32-wasip1/release/wasm_rent_free.wasm
//!
//! 将此 .wasm 文件复制到 plugins/ 目录后，引擎会自动加载。
//! 引擎通过 wasmtime linker 在 "env" 模块中注册宿主函数。
//!
//! 插件功能：订阅 core:rent_due 事件，取消所有租金支付。

// ─── 宿主函数（由引擎在 "env" 模块中注册）───────────────────────────

#[link(wasm_import_module = "env")]
extern "C" {
    fn subscribe_event(event_type_ptr: *const u8, event_type_len: i32) -> i32;
    fn publish_event(
        event_type_ptr: *const u8,
        event_type_len: i32,
        payload_ptr: *const u8,
        payload_len: i32,
    ) -> i32;
    fn get_state(
        key_ptr: *const u8,
        key_len: i32,
        out_ptr: *mut u8,
        out_max_len: i32,
    ) -> u32;
    fn set_canceled(canceled: i32);
}

// ─── 辅助函数 ─────────────────────────────────────────────────────────

fn subscribe(event_type: &str) {
    unsafe {
        subscribe_event(event_type.as_ptr(), event_type.len() as i32);
    }
}

#[allow(dead_code)]
fn publish(event_type: &str, payload: &str) {
    unsafe {
        publish_event(
            event_type.as_ptr(),
            event_type.len() as i32,
            payload.as_ptr(),
            payload.len() as i32,
        );
    }
}

// ─── 导出函数（引擎调用）──────────────────────────────────────────────

/// 插件初始化：注册感兴趣的事件
#[no_mangle]
pub extern "C" fn init() {
    subscribe("core:rent_due");
}

/// 事件处理入口
///
/// 返回值：
/// - 0: 事件未处理（继续传播）
/// - 1: 事件已处理
#[no_mangle]
pub extern "C" fn on_event(
    event_type_ptr: *const u8,
    event_type_len: i32,
    _payload_ptr: *const u8,
    _payload_len: i32,
) -> i32 {
    let event_type = if event_type_len > 0 {
        let slice = unsafe { std::slice::from_raw_parts(event_type_ptr, event_type_len as usize) };
        String::from_utf8_lossy(slice).to_string()
    } else {
        return 0;
    };

    if event_type == "core:rent_due" {
        // 取消租金支付
        unsafe { set_canceled(1); }
        return 1;
    }

    0
}
