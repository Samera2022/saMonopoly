//! 免租动态库插件
//!
//! 编译方法：
//!   cargo build -p dynlib-rent-free --release
//!
//! 输出：target/release/libdynlib_rent_free.so（Linux）
//!       target/release/dynlib_rent_free.dll（Windows）
//!       target/release/libdynlib_rent_free.dylib（macOS）
//!
//! 将此 .so/.dll/.dylib 文件复制到 plugins/ 目录后，引擎会自动加载。
//!
//! 插件功能：注册 PreEventHook，拦截 core:rent_due 事件，取消租金支付。

use sa_monopoly_application::event_bus::{EventBus, PreEventHook, PreEventAction, SubscriberPriority};
use sa_monopoly_domain::GameState;

struct RentFreeHook;

impl PreEventHook for RentFreeHook {
    fn id(&self) -> &str {
        "dynlib:rent_free"
    }

    fn priority(&self) -> SubscriberPriority {
        SubscriberPriority::First
    }

    fn on_pre_command(
        &mut self,
        command_type: &str,
        _payload: &serde_json::Value,
        _state: &GameState,
    ) -> PreEventAction {
        if command_type == "core:rent_due" {
            log::info!("[DynLibPlugin] 取消了租金支付!");
            return PreEventAction::Cancel("dynlib_free_rent".to_string());
        }
        PreEventAction::Continue
    }
}

struct RentFreePlugin;

impl sa_monopoly_infra::plugins::Plugin for RentFreePlugin {
    fn id(&self) -> &str { "dynlib:rent_free_plugin" }
    fn name(&self) -> &str { "动态库免租插件" }
    fn version(&self) -> &str { "1.0.0" }

    fn register_pre_hooks(&mut self, bus: &mut EventBus) {
        bus.register_pre_hook(Box::new(RentFreeHook));
        log::info!("[DynLibPlugin] 已注册免租 pre-hook");
    }
}

/// 导出函数：引擎通过此函数获取插件实例
#[no_mangle]
pub extern "C" fn create_plugin() -> *mut dyn sa_monopoly_infra::plugins::Plugin {
    Box::into_raw(Box::new(RentFreePlugin))
}
