# 插件系统完整方案

## 现状限制

| 限制 | 原因 | 影响 |
|------|------|------|
| **WASM 插件是桩实现** | `DescriptorPlugin` 只有 `id/version`，没有真正的 WASM 运行时 | 无法加载 `.wasm` 文件 |
| **脚本插件未实现** | `DisabledScriptHost` 全部返回 `Err` | 无法运行 `.lua` / `.js` 插件 |
| **热插拔不支持** | `PluginManager::enable_plugin()` 只在启动时调用 | 运行时启用/禁用后，已存在的 EventBus 实例不受影响 |
| **动态库 (.so) 未加载** | `LoadKind::DynamicLibrary` 只解析但没有实现 | 无法使用 `.so` / `.dll` / `.dylib` 插件 |

---

## 架构设计

### 新增模块树

```
crates/infra/src/
  ├── mod.rs
  ├── plugins.rs          ← 现有，扩展 Plugin trait
  ├── plugin_manager.rs   ← 现有，改造热插拔
  ├── discovery.rs        ← 现有
  ├── scripting.rs        ← 现有，改造
  ├── wasm_runtime.rs     ← 新增：WASM 运行时
  ├── script_runtime.rs   ← 新增：Lua/JS 运行时
  └── dynlib_loader.rs    ← 新增：动态库加载器
```

---

### 1. WASM 运行时（`wasm_runtime.rs`）

依赖选择：使用 `wasmtime` crate（成熟、安全、支持 WASI）

```rust
use wasmtime::{Engine, Module, Store, Linker, Func};
use sa_monopoly_application::event_bus::EventBus;

pub struct WasmPluginRuntime {
    engine: Engine,
}

impl WasmPluginRuntime {
    pub fn new() -> Result<Self, String> {
        let engine = Engine::default();
        Ok(Self { engine })
    }

    /// 从 .wasm 文件加载插件
    pub fn load_plugin(&self, wasm_path: &Path, bus: &mut EventBus) -> Result<WasmPluginInstance, String> {
        let module = Module::from_file(&self.engine, wasm_path)
            .map_err(|e| format!("加载 WASM 模块失败: {e}"))?;

        let mut linker = Linker::new(&self.engine);
        // 注册宿主函数（供 WASM 调用的 Rust 函数）
        linker.func_wrap("sa_monopoly", "subscribe_event", |...| { ... })?;
        linker.func_wrap("sa_monopoly", "publish_event", |...| { ... })?;
        linker.func_wrap("sa_monopoly", "get_state", |...| { ... })?;
        linker.func_wrap("sa_monopoly", "set_canceled", |...| { ... })?;

        let mut store = Store::new(&self.engine, WasmPluginState::new());
        let instance = linker.instantiate(&mut store, &module)
            .map_err(|e| format!("实例化 WASM 模块失败: {e}"))?;

        // 调用 WASM 插件的 init 函数
        let init = instance.get_typed_func::<(), ()>(&mut store, "init")
            .map_err(|_| "WASM 插件缺少 init 导出函数".to_string())?;
        init.call(&mut store, ())
            .map_err(|e| format!("WASM init 调用失败: {e}"))?;

        Ok(WasmPluginInstance { store, instance })
    }
}

/// WASM 插件可访问的宿主 API
impl WasmPluginRuntime {
    // 以下函数通过 linker 注册给 WASM 插件调用
    fn host_subscribe(bus: &mut EventBus, event_type: &str) { ... }
    fn host_publish(bus: &mut EventBus, event_type: &str, payload: &str) { ... }
    fn host_get_state(state: &GameState) -> String { ... }
    fn host_set_canceled(cancellable: &mut CancellableEvent) { ... }
}
```

**WASM 插件示例（用 Rust 编译到 WASM）：**

```rust
// 编译：cargo build --target wasm32-wasi
// 输出：my_plugin.wasm

#[no_mangle]
pub extern "C" fn init() {
    // 注册感兴趣的事件
    subscribe_event("core:rent_due");
}

#[no_mangle]
pub extern "C" fn on_event(event_ptr: *const u8, len: usize) -> i32 {
    let event_json = unsafe { std::slice::from_raw_parts(event_ptr, len) };
    let event: serde_json::Value = serde_json::from_slice(event_json).unwrap();

    if event["event_type"] == "core:rent_due" {
        // 取消租金
        set_canceled(true);
        return 1; // 已处理
    }
    0
}
```

---

### 2. 脚本运行时（`script_runtime.rs`）

选择 `mlua`（Lua）和 `boa_engine`（JavaScript）作为轻量级嵌入式引擎。

```rust
use mlua::{Lua, Value, Result as LuaResult};
use boa_engine::{Context, Source};

pub enum ScriptEngine {
    Lua(mlua::Lua),
    JavaScript(boa_engine::Context),
}

impl ScriptEngine {
    pub fn new(kind: ScriptEngineKind) -> Result<Self, String> {
        match kind {
            ScriptEngineKind::Lua => Ok(Self::Lua(Lua::new())),
            ScriptEngineKind::JavaScript => Ok(Self::JavaScript(Context::default())),
            _ => Err(format!("不支持的脚本引擎: {:?}", kind)),
        }
    }

    /// 注册宿主函数到脚本环境
    pub fn register_host_functions(&mut self, bus: &mut EventBus) {
        match self {
            ScriptEngine::Lua(lua) => {
                // 注册全局函数供 Lua 脚本调用
                let bus_ptr = bus as *mut EventBus as usize;
                lua.global().set("publish_event", lua.create_function(move |_, (event_type, payload): (String, String)| {
                    let bus = unsafe { &mut *(bus_ptr as *mut EventBus) };
                    let payload: serde_json::Value = serde_json::from_str(&payload).unwrap_or_default();
                    bus.publish_custom(&event_type, "lua_script", payload, &GameState::default());
                    Ok(())
                })).unwrap();
            }
            ScriptEngine::JavaScript(ctx) => {
                // 注册全局函数供 JS 脚本调用
                // ...
            }
        }
    }

    /// 执行脚本文件
    pub fn run_file(&mut self, path: &Path) -> Result<(), String> {
        let source = std::fs::read_to_string(path)
            .map_err(|e| format!("读取脚本文件失败: {e}"))?;
        self.run(&source)
    }

    pub fn run(&mut self, source: &str) -> Result<(), String> {
        match self {
            ScriptEngine::Lua(lua) => {
                lua.chunk(source).exec()
                    .map_err(|e| format!("Lua 执行错误: {e}"))?;
                Ok(())
            }
            ScriptEngine::JavaScript(ctx) => {
                ctx.eval(Source::from_bytes(source.as_bytes()))
                    .map_err(|e| format!("JS 执行错误: {e}"))?;
                Ok(())
            }
        }
    }
}
```

**Lua 插件示例：**

```lua
-- 免租插件：free_rent.lua
function on_pre_command(command_type, payload)
    if command_type == "core:rent_due" then
        print("[LuaPlugin] 取消租金!")
        return { action = "cancel", reason = "lua_free_rent" }
    end
    return { action = "continue" }
end
```

**JavaScript 插件示例：**

```js
// 双倍租金插件：double_rent.js
function on_pre_command(commandType, payload) {
    if (commandType === "core:rent_due") {
        let amount = payload.amount * 2;
        print("[JSPlugin] 租金翻倍: " + amount);
        return { action: "modify", payload: { amount: amount } };
    }
    return { action: "continue" };
}
```

---

### 3. 动态库加载器（`dynlib_loader.rs`）

使用 `libloading` crate。

```rust
use libloading::{Library, Symbol};
use sa_monopoly_application::event_bus::EventBus;

pub struct DynamicLibPlugin {
    lib: Library,
    plugin_id: String,
}

impl DynamicLibPlugin {
    /// 加载动态库并获取插件实例
    pub fn load(path: &Path) -> Result<Self, String> {
        unsafe {
            let lib = Library::new(path)
                .map_err(|e| format!("加载动态库失败: {e}"))?;

            // 调用插件的 create_plugin 函数获取 Box<dyn Plugin>
            let create_fn: Symbol<fn() -> Box<dyn Plugin>> = lib.get(b"create_plugin")
                .map_err(|_| "动态库缺少 create_plugin 导出符号".to_string())?;
            let plugin = create_fn();

            Ok(Self {
                lib,
                plugin_id: plugin.id().to_string(),
            })
        }
    }
}
```

动态库插件的 C 接口：

```rust
// 编译为 .so / .dll / .dylib
#[no_mangle]
pub extern "C" fn create_plugin() -> *mut dyn Plugin {
    Box::into_raw(Box::new(MyDynamicPlugin::new()))
}
```

---

### 4. 热插拔支持

#### 问题

当前 `EventBus` 在每个 FFI 调用时被**重新创建**（`bridge.rs:execute_json` 中的 `EventBus::new()`），所以插件注册只影响下一次 FFI 调用。

#### 方案

1. **插件注册时更新全局状态**：`PluginController` 跟踪插件的启用/禁用状态
2. **EventBus 创建时注入活跃插件**：在 `execute_json` 创建 EventBus 时，查询 `PluginController` 中的活跃插件列表，自动注册它们

```rust
// bridge.rs
pub fn execute_json(input: &str) -> Result<String, String> {
    let request: BridgeRequest = serde_json::from_str(input).map_err(|err| err.to_string())?;
    let mut bus = EventBus::new();
    register_core_commands(&mut bus.command_handlers);
    register_core_tile_behaviors(&mut bus.tile_behaviors);
    register_core_subscribers(&mut bus);

    // ★ 加载活跃的本地/WASM/脚本插件 ★
    PluginManager::global_active().register_into_bus(&mut bus);

    let response = Self::execute(request, &mut bus);
    serde_json::to_string_pretty(&response).map_err(|err| err.to_string())
}
```

`PluginManager` 改造：

```rust
impl PluginManager {
    /// 全局单例（用于 FFI 路径）
    pub fn global_active() -> &'static PluginManager {
        static INSTANCE: once_cell::sync::Lazy<PluginManager> = once_cell::sync::Lazy::new(|| {
            let mut pm = PluginManager::new(PathBuf::from("plugins"));
            pm.discover_local().ok();
            pm
        });
        &INSTANCE
    }

    /// 将所有活跃插件的 hooks/subscribers 注册到指定的 EventBus
    pub fn register_into_bus(&self, bus: &mut EventBus) {
        for id in &self.active_plugins {
            if let Some(managed) = self.get_plugin(id) {
                managed.plugin.register_subscribers(bus);
                managed.plugin.register_pre_hooks(bus);
                managed.plugin.register_post_hooks(bus);
            }
        }
    }
}
```

---

### 5. 插件加载流程（完整）

```
应用启动
  │
  ├─ PluginManager::new(plugins_dir)
  │   ├─ discover_local() → 扫描目录
  │   │   ├─ 子目录 → meta.json → DescriptorPlugin
  │   │   ├─ *.wasm  → WasmPluginRuntime::load()
  │   │   ├─ *.lua   → ScriptEngine::new(Lua) + run_file()
  │   │   ├─ *.js    → ScriptEngine::new(JS) + run_file()
  │   │   └─ *.so    → DynamicLibPlugin::load()
  │   │
  │   └─ 默认启用所有插件（除被禁用的）
  │
  ├─ 每次 FFI 调用 execute_json():
  │   ├─ 创建 EventBus
  │   └─ PluginManager::global_active().register_into_bus(bus)
  │
  └─ Flutter 通过 sa_engine_plugin_ctl 启用/禁用插件
      └─ PluginController::enable/disable → 更新 active_plugins
```

---

### 6. DescriptorPlugin 改造

```rust
pub struct DescriptorPlugin {
    pub id: String,
    pub version: String,
    pub load_config: Option<DynamicLoadConfig>,
    // 新增：运行时组件
    pub wasm_instance: Option<WasmPluginInstance>,
    pub script_engine: Option<ScriptEngine>,
    pub dynamic_lib: Option<DynamicLibPlugin>,
}

impl Plugin for DescriptorPlugin {
    fn register_pre_hooks(&mut self, bus: &mut EventBus) {
        if let Some(ref wasm) = self.wasm_instance {
            // WASM 插件的 on_pre_command 逻辑
            bus.register_pre_hook(Box::new(WasmPreHook {
                instance: wasm.clone(),
            }));
        }
        if let Some(ref engine) = self.script_engine {
            // 脚本插件的 on_pre_command 逻辑
            bus.register_pre_hook(Box::new(ScriptPreHook {
                engine: engine.clone(),
            }));
        }
    }
}
```

---

## 实施步骤

| 阶段 | 内容 | 核心文件 | 依赖 |
|------|------|---------|------|
| **1** | 新增 `wasm_runtime.rs` + `wasmtime` 依赖 | `Cargo.toml`, 新文件 | `wasmtime` crate |
| **2** | 新增 `script_runtime.rs` + `mlua`/`boa_engine` 依赖 | `Cargo.toml`, 新文件 | `mlua`, `boa_engine` |
| **3** | 新增 `dynlib_loader.rs` + `libloading` 依赖 | `Cargo.toml`, 新文件 | `libloading` crate |
| **4** | 改造 `DescriptorPlugin` 集成三种运行时 | `plugins.rs` | 1-3 完成 |
| **5** | 改造 `PluginManager` 支持热插拔 + `register_into_bus` | `plugin_manager.rs` |  |
| **6** | 改造 `bridge.rs` 的 `execute_json` 注入活跃插件 | `bridge.rs` | 5 完成 |
| **7** | 示例 WASM 插件 | `examples/` | 1 完成 |
| **8** | 示例 Lua/JS 插件 | `examples/` | 2 完成 |

---

## 不改变的原则

1. **EventBus 每次 FFI 调用创建** — 插件注册通过 `register_into_bus` 注入，不依赖全局 EventBus
2. **权限系统保留** — WASM/脚本插件通过 linker 限制可调用的宿主 API
3. **性能优先** — WASM 编译为原生代码后性能接近原生；脚本引擎只在插件启用时初始化
4. **沙箱安全** — WASM 天然沙箱；Lua/JS 引擎限制文件系统/网络访问
