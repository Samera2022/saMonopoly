# 插件管理系统 — 完整设计方案

## 1. 问题域分析

### 1.1 插件来源

| 来源 | 位置 | 发现方式 | 生命周期 |
|------|------|----------|----------|
| **本地插件** (User-Installed) | `{app_data}/plugins/` | 程序启动时扫描 `plugins/` 目录 | 持久存在，跨地图可用 |
| **地图捆绑插件** (Map-Bundled) | 地图文件内部（`.smap` 包内 `plugins/`） | 加载地图时发现 | 随地图存在 |

### 1.2 插件必要性

| 必要性 | 定义 | 用户控制权 |
|--------|------|-----------|
| **可选** (Optional) | 无此插件地图仍可正常玩 | 用户可以启用/禁用 |
| **必选** (Mandatory) | 无此插件地图无法正常工作 | 用户无法禁用，自动启用 |

### 1.3 交互场景

```
场景 A: 地图管理器
  ┌────────────────────────────────────────────┐
  │ 选择地图 → 查看详情                         │
  │   → 地图自带插件列表（可选/必选）             │
  │   → 本地插件启停                            │
  │   → 点击"开始游戏"时检查必选插件是否就绪      │
  └────────────────────────────────────────────┘

场景 B: 游戏大厅（联机）
  ┌────────────────────────────────────────────┐
  │ 主机选择地图 → 大厅界面                     │
  │   → 左侧: 玩家列表                         │
  │   → 右侧: 上方地图信息 + 下方插件管理面板     │
  │     ├─ 地图自带插件（必选 / 可选）           │
  │     └─ 本地插件（玩家额外添加）              │
  │   → 主机启停插件 → 广播给所有客户端          │
  │   → 客户端同步插件状态                      │
  │   → 开始游戏时检查所有客户端插件一致性        │
  └────────────────────────────────────────────┘

场景 C: 插件安装
  ┌────────────────────────────────────────────┐
  │ 主菜单 → 插件管理                          │
  │   → 已安装插件列表                         │
  │   → 导入插件（从 .wasm/.smap 提取）         │
  │   → 启用/禁用本地插件                      │
  │   → 查看插件权限                           │
  └────────────────────────────────────────────┘
```

---

## 2. 数据模型设计

### 2.1 Rust 侧数据结构

#### 2.1.1 插件元信息扩展

```rust
// crates/infra/src/plugins.rs (扩展)

/// 插件来源
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum PluginOrigin {
    /// 用户从外部安装到本地的插件
    Local {
        /// 安装路径
        install_path: PathBuf,
        /// 安装时间
        installed_at: u64,
    },
    /// 地图自带的捆绑插件
    Bundled {
        /// 所属地图 ID
        map_id: String,
        /// 在地图包内的路径
        bundle_path: String,
        /// 是否是必选插件
        mandatory: bool,
    },
    /// 内置插件（编译到二进制中）
    BuiltIn,
}

/// 插件元信息（扩展）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PluginInfo {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    pub required_permissions: PermissionSet,
    pub load_config: Option<DynamicLoadConfig>,
    pub enabled: bool,

    // ── 新增字段 ──
    /// 插件来源
    pub origin: PluginOrigin,
    /// 插件依赖的其他插件 ID（用于加载顺序）
    pub dependencies: Vec<String>,
    /// 支持的引擎版本范围（语义化版本约束）
    pub engine_compat: String,
}

/// 插件运行时状态
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PluginStatus {
    /// 已加载并启用
    Active,
    /// 已注册但禁用
    Disabled,
    /// 加载失败（附错误信息）
    Error(String),
    /// 依赖未满足
    MissingDependencies(Vec<String>),
}
```

#### 2.1.2 地图定义扩展插件声明

```rust
// crates/infra/src/map.rs (扩展)

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MapDefinition {
    pub id: String,
    pub version: String,
    pub name_key: String,
    pub tiles: Vec<MapTile>,
    pub rules: MapRules,

    // ── 新增：插件依赖声明 ──
    /// 地图自带的插件列表
    pub plugins: Vec<MapPluginRef>,
}

/// 地图对插件的引用声明
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MapPluginRef {
    /// 插件 ID（用于匹配本地已安装的插件）
    pub id: String,
    /// 插件名称（显示用）
    pub name: String,
    /// 最小版本要求
    pub min_version: String,
    /// 是否是必选插件
    pub mandatory: bool,
    /// 插件位置：
    ///   - "bundled" = 在地图包内部
    ///   - "external" = 需要用户自行安装
    pub source: MapPluginSource,
    /// 如果 source="bundled"，这里存储插件数据
    /// （在解析 .smap 时填充）
    #[serde(skip)]
    pub bundled_data: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum MapPluginSource {
    /// 插件打包在地图文件内部
    Bundled,
    /// 插件需要用户从外部安装
    External,
}
```

#### 2.1.3 地图捆绑插件的文件布局

```
经典地图.smap
├── map.json              # MapDefinition (含 plugins 声明)
├── thumbnail.png
├── tilesets/
│   └── ...
└── plugins/               # ← 地图自带的插件
    ├── my_mod.wasm        # 捆绑的 WASM 插件
    ├── my_mod.meta.json   # 插件元信息（PluginInfo）
    └── extra_mod/
        ├── script.lua
        └── meta.json
```

### 2.2 PluginManager

```rust
// crates/application/src/plugin_manager.rs (新文件)

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::event_bus::EventBus;
use crate::command_handler::CommandHandlerRegistry;
use crate::tile_behavior::TileBehaviorRegistry;

/// 插件管理器 — 统一管理本地插件和地图捆绑插件
pub struct PluginManager {
    /// 本地已安装的插件
    local_plugins: HashMap<String, ManagedPlugin>,
    /// 当前地图的捆绑插件
    bundled_plugins: HashMap<String, ManagedPlugin>,
    /// 必选插件 ID 列表（来自当前地图）
    mandatory_plugins: Vec<String>,
    /// 当前已加载到 EventBus 的插件
    active_plugins: Vec<String>,
}

struct ManagedPlugin {
    info: PluginInfo,
    plugin: Box<dyn Plugin>,
    status: PluginStatus,
}

impl PluginManager {
    pub fn new() -> Self { /* ... */ }

    // ─── 本地插件管理 ───

    /// 从插件目录扫描并加载所有本地插件
    pub fn discover_local(&mut self, plugins_dir: &Path) -> Result<Vec<String>, String> {
        // 扫描 plugins_dir 下的所有 .wasm / 子目录
        // 对每个发现调用 install_local()
    }

    /// 安装一个本地插件（从文件路径）
    pub fn install_local(&mut self, path: &Path) -> Result<String, String> {
        // 1. 读取 meta.json 或解析 WASM 头部获取 PluginInfo
        // 2. 复制到 plugins_dir
        // 3. 注册到内部 map
        // 4. 返回 plugin_id
    }

    /// 卸载一个本地插件
    pub fn uninstall_local(&mut self, plugin_id: &str) -> Result<(), String> {
        // 1. 如果已激活，停用
        // 2. 从磁盘删除
        // 3. 从 map 移除
    }

    // ─── 地图捆绑插件管理 ───

    /// 加载地图的插件声明
    pub fn load_map_plugins(&mut self, map: &MapDefinition) -> Vec<MapPluginRef> {
        // 1. 清空 bundled_plugins
        // 2. 遍历 map.plugins
        // 3. 对于 Bundled 类型的：从 bundled_data 加载
        // 4. 对于 External 类型的：检查 local_plugins 是否有匹配
        // 5. 记录 mandatory_plugins
    }

    // ─── 启停控制 ───

    /// 启用一个插件（本地或地图捆绑）
    pub fn enable_plugin(&mut self, plugin_id: &str, bus: &mut EventBus) -> Result<(), String> {
        // 1. 检查是否为必选（必选不能禁用，但启用是自动的）
        // 2. 调用 plugin.register_subscribers(bus)
        // 3. 调用 plugin.register_commands(&mut bus.command_handlers)
        // 4. 调用 plugin.register_tile_behaviors(&mut bus.tile_behaviors)
        // 5. 标记为 Active
    }

    /// 禁用一个插件（可选插件）
    pub fn disable_plugin(&mut self, plugin_id: &str, bus: &mut EventBus) -> Result<(), String> {
        // 1. 检查是否为必选 — 必选不可禁用
        if self.mandatory_plugins.contains(&plugin_id.to_string()) {
            return Err("Cannot disable mandatory plugin".to_string());
        }
        // 2. bus.unregister_plugin(plugin_id)
        // 3. bus.command_handlers.unregister_plugin(plugin_id)
        // 4. bus.tile_behaviors.unregister_plugin(plugin_id)
        // 5. 标记为 Disabled
    }

    // ─── 查询 ───

    /// 获取所有本地插件（含状态）
    pub fn list_local(&self) -> Vec<&ManagedPlugin> { /* ... */ }

    /// 获取当前地图的捆绑插件（含状态）
    pub fn list_bundled(&self) -> Vec<&ManagedPlugin> { /* ... */ }

    /// 获取必选插件 ID 列表
    pub fn mandatory_ids(&self) -> &[String] { &self.mandatory_plugins }

    /// 检查必选插件是否都已激活
    pub fn all_mandatory_active(&self) -> bool {
        self.mandatory_plugins.iter().all(|id| {
            self.active_plugins.contains(id)
        })
    }
}
```

---

## 3. Flutter UI 设计

### 3.1 地图详情面板 — 插件区域

在 [`map_manager_screen.dart`](flutter/lib/map_manager_screen.dart) 的详情面板中新增插件区域：

```
┌─────────────────────────────────────────────────┐
│  地图名称  v1.0                                  │
│  20 tiles · 8 地产                                │
│                                                  │
│  ┌─ 环境/规则配置 ────────┐  ┌─ 存档记录 ──────┐  │
│  │ 启用此地图           ☑  │  │ 存档 1      ▶ 🗑 │  │
│  │ 允许股票市场         ☑  │  │ 存档 2      ▶ 🗑 │  │
│  │ ...                   │  │                  │  │
│  └────────────────────────┘  └──────────────────┘  │
│                                                    │
│  ┌─ 插件管理 ─────────────────────────────────┐    │
│  │ 📦 地图自带插件                             │    │
│  │  ├─ 经济扩展 v1.2  ● 必选  [已激活]        │    │
│  │  ├─ 特殊事件 v2.0  ○ 可选  [启用] [禁用]   │    │
│  │  └─ 视觉主题 v1.0  ○ 可选  [启用] [禁用]   │    │
│  │                                             │    │
│  │ 📂 本地插件                                 │    │
│  │  ├─ 骰子动画 v0.5          [启用] [禁用]    │    │
│  │  ├─ 音效包 v1.0            [启用] [禁用]    │    │
│  │  └─ 天气系统 v2.1          [启用] [禁用]    │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

### 3.2 游戏大厅 — 插件面板

在 [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart) 的比赛设置区域中新增插件管理：

```
┌──────────────────────────────────────────────────┐
│  ← 游戏大厅                                      │
│                                                  │
│  ┌───────────┐  ┌──────────────────────────────┐ │
│  │ 参与者     │  │ 比赛设置                      │ │
│  │ (4/4)     │  │ ┌─ 地图预览 ────────────────┐ │ │
│  │           │  │ │ 📷 经典大富翁               │ │ │
│  │ [玩家1]   │  │ │ 20 tiles · v1.0            │ │ │
│  │ [CPU]     │  │ └────────────────────────────┘ │ │
│  │ [CPU]     │  │                                │ │
│  │ [空位]    │  │ ┌─ 插件管理 ────────────────┐ │ │
│  │           │  │ │ 📦 地图自带                │ │ │
│  │ [+ 添加]  │  │ │ 必选 ▸ 经济扩展  ● 已激活  │ │ │
│  │           │  │ │ 可选 ▸ 特殊事件  ○ 已启用  │ │ │
│  │           │  │ │       视觉主题  ○ 已禁用  │ │ │
│  │           │  │ │                            │ │ │
│  │           │  │ │ 📂 本地                    │ │ │
│  │           │  │ │    ▸ 骰子动画  ☑           │ │ │
│  │           │  │ │    ▸ 音效包    ☑           │ │ │
│  │           │  │ │    ▸ 天气系统  ☐           │ │ │
│  │           │  │ └────────────────────────────┘ │ │
│  │           │  │                                │ │
│  │           │  │ ┌─ 经济设置 ────────────────┐ │ │
│  │           │  │ │ 起始资金: [____]          │ │ │
│  │           │  │ │ ...                       │ │ │
│  │           │  │ └────────────────────────────┘ │ │
│  │           │  │                                │ │
│  │           │  │ [     开始游戏      ]          │ │
│  └───────────┘  └──────────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

### 3.3 插件管理屏幕（独立页面）

```dart
// flutter/lib/plugin_manager_screen.dart (新文件)

class PluginManagerScreen extends StatefulWidget { ... }

class _PluginManagerScreenState extends State<PluginManagerScreen> {
    List<PluginEntry> _localPlugins = [];
    List<PluginEntry> _builtinPlugins = [];

    // 布局: 左列显示分类, 右列显示详情
    // ┌────────────────────────────────────────┐
    // │ 插件管理                                │
    // │                                        │
    // │ ┌──────────┐ ┌──────────────────────┐  │
    // │ │ 📦 内置   │ │ 骰子动画 v0.5         │  │
    // │ │   (3)    │ │ 作者: xxx             │  │
    // │ │──────────│ │ 提供骰子滚动动画效果   │  │
    // │ │ 📂 本地   │ │                      │  │
    // │ │   (5)    │ │ 权限:                │  │
    // │ │──────────│ │ ☑ 读取游戏状态        │  │
    // │ │ 🗑 回收站 │ │ ☐ 写入游戏状态        │  │
    // │ │          │ │                      │  │
    // │ │          │ │ [禁用] [卸载]         │  │
    // │ └──────────┘ └──────────────────────┘  │
    // └────────────────────────────────────────┘
}

// 在游戏主界面添加入口：
// 主菜单 → 设置 ⚙ → 插件管理 🧩
```

### 3.4 联机时的插件同步

```dart
// 主机操作流程:
// 1. 主机选择地图
// 2. EventBus 加载地图的必选插件（自动启用）
// 3. 主机在界面上调整可选/本地插件的启用状态
// 4. 每次变更时，主机广播插件清单:
//    {
//      "type": "plugin_sync",
//      "plugins": [
//        {"id": "economy_ext", "mandatory": true, "enabled": true},
//        {"id": "special_events", "mandatory": false, "enabled": true},
//        {"id": "dice_anim", "mandatory": false, "enabled": false},
//      ]
//    }
// 5. 客户端收到后检查：
//    - 所有 mandatory=true 的插件是否已安装
//    - 如果缺失 → 弹出提示 "需要安装以下插件: economy_ext"
//    - 如果就绪 → 应用相同的启停状态
// 6. 开始游戏时，主机再次广播最终插件状态
```

---

## 4. 地图文件格式扩展

### 4.1 `map.json` 新增 `plugins` 字段

```json
{
    "id": "classic",
    "version": "1.0.0",
    "name_key": "maps.classic",
    "tiles": [ ... ],
    "rules": { ... },
    "plugins": [
        {
            "id": "economy_ext",
            "name": "经济扩展",
            "min_version": "1.0.0",
            "mandatory": true,
            "source": "bundled"
        },
        {
            "id": "special_events",
            "name": "特殊事件",
            "min_version": "2.0.0",
            "mandatory": false,
            "source": "bundled"
        },
        {
            "id": "weather_system",
            "name": "天气系统",
            "min_version": "2.1.0",
            "mandatory": false,
            "source": "external"
        }
    ]
}
```

### 4.2 插件元信息文件 (`meta.json`)

```json
{
    "id": "economy_ext",
    "name": "经济扩展",
    "version": "1.0.0",
    "author": "Map Author",
    "description": "为地图添加通货膨胀和经济危机事件",
    "engine_compat": ">=0.5.0",
    "dependencies": [],
    "required_permissions": {
        "granted": ["ReadState", "WriteState", "EventInjection"],
        "denied": ["NetworkAccess", "FileSystemAccess"]
    }
}
```

---

## 5. 文件系统布局

```
{app_data}/
├── maps/                    # 用户导入的地图 (.smap / .json)
│   ├── classic.smap
│   └── user_map.json
│
├── plugins/                 # 用户安装的本地插件
│   ├── dice_anim/
│   │   ├── plugin.wasm
│   │   └── meta.json
│   ├── sound_pack.wasm      # 自包含的 WASM 插件
│   └── weather_system/
│       ├── script.lua
│       └── meta.json
│
└── config/
    └── plugin_config.json   # 插件启用状态持久化
```

### 5.1 插件启用状态持久化

```json
// config/plugin_config.json
{
    "version": 1,
    "plugins": {
        "dice_anim": {
            "enabled": true,
            "auto_load": true
        },
        "sound_pack": {
            "enabled": true,
            "auto_load": false
        },
        "weather_system": {
            "enabled": false,
            "auto_load": false
        }
    },
    "map_plugin_overrides": {
        "classic": {
            "enabled": ["dice_anim"],
            "disabled": ["sound_pack"]
        }
    }
}
```

---

## 6. 实施计划

### Phase 1: Rust 数据模型扩展（~1 天）

| 文件 | 变更 |
|------|------|
| [`plugins.rs`](crates/infra/src/plugins.rs) | 添加 `PluginOrigin`, `PluginStatus`, 扩展 `PluginInfo` |
| [`map.rs`](crates/infra/src/map.rs) | 添加 `MapPluginRef`, `MapPluginSource`, 扩展 `MapDefinition` |
| [`smap.rs`](crates/infra/src/smap.rs) | 支持从 `.smap` 中提取 `plugins/` 目录内容 |
| **新文件** `plugin_manager.rs` | `PluginManager` 结构体 |

### Phase 2: PluginManager 实现（~1 天）

| 文件 | 变更 |
|------|------|
| `plugin_manager.rs` | 实现插件发现、安装、启用、禁用、卸载 |
| [`plugins.rs`](crates/infra/src/plugins.rs) | `InMemoryPluginRegistry` 集成 `PluginManager` |
| [`startup.rs`](crates/application/src/startup.rs) | 启动时扫描本地插件 |

### Phase 3: Flutter 地图插件 UI（~1 天）

| 文件 | 变更 |
|------|------|
| [`map_manager_screen.dart`](flutter/lib/map_manager_screen.dart) | 详情面板添加"插件管理"区域 |
| `flutter/lib/map_models.dart` | 添加 `MapPluginRef` Dart 模型 |

### Phase 4: Flutter 大厅插件 UI（~1 天）

| 文件 | 变更 |
|------|------|
| [`game_lobby_screen.dart`](flutter/lib/game_lobby_screen.dart) | 比赛设置添加"插件管理"面板 |
| `flutter/lib/network_service.dart` | 添加插件同步消息 |

### Phase 5: 插件管理器屏幕（~0.5 天）

| 文件 | 变更 |
|------|------|
| **新文件** `plugin_manager_screen.dart` | 独立插件管理页面 |

---

## 7. 验证清单

| 场景 | 验证点 |
|------|--------|
| 地图自带必选插件 | 加载地图时自动启用，用户不可禁用 |
| 地图自带可选插件 | 默认启用，用户可以禁用 |
| 本地插件 | 用户安装后在所有地图中可用 |
| 联机插件同步 | 主机广播插件列表 → 客户端检查一致性 |
| 必选插件缺失 | 开始游戏前弹出错误，禁止开始 |
| 插件安装 | 从 `.wasm`/`.smap` 导入到 `plugins/` 目录 |
| 插件卸载 | 从 `plugins/` 删除，清理 EventBus 注册 |
| 插件权限 | 安装时显示权限列表，运行时强制执行 |
| 地图切换 | 切换到新地图时，卸载旧地图插件，加载新地图插件 |
