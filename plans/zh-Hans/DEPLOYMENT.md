# saMonopoly — 多平台部署指南

> 本文档说明如何将 saMonopoly 部署到 Android、PC 和 Web 三个目标平台。  
> 核心策略：**Rust 引擎编译为平台原生库**，**Flutter 壳通过 FFI 调用引擎**。

---

## 架构回顾

```
                    ┌──────────────────────────┐
                    │     Flutter UI Shell      │
                    │  (board rendering / dialogs / i18n) │
                    └──────────┬───────────────┘
                               │ FFI (flutter_rust_bridge / dart:ffi)
                    ┌──────────▼───────────────┐
                    │     Rust Core Engine      │
                    │  (domain / application / infra)  │
                    └──────────────────────────┘
```

Rust 引擎编译为 **cdylib**（动态库），Flutter 通过 FFI 调用 `execute_json()` 接口。

---

## 一、通用准备

### 1.1 Rust 引擎编译为动态库

在 [`Cargo.toml`](Cargo.toml) 中添加一个 cdylib crate（或修改现有 crate）：

```toml
# crates/engine-ffi/Cargo.toml (新增)
[package]
name = "sa-monopoly-engine"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
sa-monopoly-domain = { path = "../domain" }
sa-monopoly-application = { path = "../application" }
sa-monopoly-infra = { path = "../infra" }
serde_json = "1"
```

创建一个 FFI 导出层：

```rust
// crates/engine-ffi/src/lib.rs
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// Execute a JSON command against a JSON state, return JSON response.
/// Caller must free the returned string with `sa_free_string`.
#[no_mangle]
pub extern "C" fn sa_execute_json(command_json: *const c_char) -> *mut c_char {
    let input = unsafe {
        CStr::from_ptr(command_json).to_str().unwrap_or("{}")
    };
    let result = sa_monopoly_application::ffi::NativeBridge::execute_json(input)
        .unwrap_or_else(|e| format!("{{\"error\":\"{e}\"}}"));
    CString::new(result).unwrap().into_raw()
}

/// Free a string returned by the engine.
#[no_mangle]
pub extern "C" fn sa_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)); }
    }
}
```

### 1.2 Flutter 端 FFI 绑定

```dart
// flutter/lib/src/native/bridge_ffi.dart
import 'dart:ffi';
import 'package:ffi/ffi.dart';

typedef SaExecuteJsonNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaExecuteJsonDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef SaFreeStringNative = Void Function(Pointer<Utf8>);
typedef SaFreeStringDart = void Function(Pointer<Utf8>);

class NativeEngine {
  static late final DynamicLibrary _lib;
  static late final SaExecuteJsonDart _executeJson;
  static late final SaFreeStringDart _freeString;

  static void init(String libPath) {
    _lib = DynamicLibrary.open(libPath);
    _executeJson = _lib
        .lookupFunction<SaExecuteJsonNative, SaExecuteJsonDart>('sa_execute_json');
    _freeString = _lib
        .lookupFunction<SaFreeStringNative, SaFreeStringDart>('sa_free_string');
  }

  static String execute(String json) {
    final input = json.toNativeUtf8();
    final resultPtr = _executeJson(input);
    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    calloc.free(input);
    return result;
  }
}
```

---

## 二、Android 部署（APK / AAB）

### 2.1 工具链

| 工具 | 用途 |
|------|------|
| Android Studio | Flutter 开发、APK 构建 |
| Android NDK | 编译 Rust 为 ARM 目标 |
| `cargo-ndk` | 简化 Rust→Android 交叉编译 |
| `flutter_rust_bridge`（可选）| 自动生成 FFI 绑定 |

### 2.2 安装 Rust Android 目标

```bash
rustup target add \
    aarch64-linux-android \
    armv7-linux-androideabi \
    x86_64-linux-android \
    i686-linux-android

cargo install cargo-ndk
```

### 2.3 编译 Rust 引擎

```bash
cd crates/engine-ffi
cargo ndk \
    -t arm64-v8a \
    -t armeabi-v7a \
    -t x86_64 \
    -t x86 \
    -o ../../flutter/android/app/src/main/jniLibs \
    build --release
```

### 2.4 构建 Flutter APK

```bash
cd flutter
flutter build apk --release
# 或构建 App Bundle
flutter build appbundle --release
```

### 2.5 产物

```
flutter/build/app/outputs/
├── apk/release/app-release.apk      ← 直接安装
└── bundle/release/app-release.aab   ← Google Play 上传
```

### 2.6 Android 特有注意事项

- **权限**: 不需要特殊权限（单机游戏）
- **网络多人**: 添加 `INTERNET` 权限（如需）
- **最低 SDK**: API 21（Android 5.0）+
- **so 文件大小**: 约 5-15MB 每个 ABI，建议上传 AAB 让 Google Play 分发对应 ABI

---

## 三、PC 部署（Linux / Windows / macOS）

### 3.1 工具链

| 平台 | 构建工具 |
|------|---------|
| Linux | GCC/clang + Flutter Linux 支持 |
| Windows | MSVC + Flutter Windows 支持 |
| macOS | Xcode + Flutter macOS 支持 |

### 3.2 安装桌面支持

```bash
flutter config --enable-linux-desktop
flutter config --enable-windows-desktop
flutter config --enable-macos-desktop
```

### 3.3 编译 Rust 引擎（本机）

```bash
# Linux
cargo build --release -p sa-monopoly-engine
cp target/release/libsa_monopoly_engine.so flutter/linux/

# Windows
cargo build --release -p sa-monopoly-engine
copy target\release\sa_monopoly_engine.dll flutter\windows\

# macOS
cargo build --release -p sa-monopoly-engine
cp target/release/libsa_monopoly_engine.dylib flutter/macos/
```

### 3.4 构建 Flutter 桌面应用

```bash
# Linux
cd flutter
flutter build linux --release
# 产物: flutter/build/linux/x64/release/bundle/

# Windows
flutter build windows --release
# 产物: flutter/build/windows/runner/Release/

# macOS
flutter build macos --release
# 产物: flutter/build/macos/Build/Products/Release/
```

### 3.5 产物打包

```bash
# Linux — 使用 linuxdeploy 或直接打包为 .tar.gz
tar -czf sa-monopoly-linux-x64.tar.gz \
    -C flutter/build/linux/x64/release/bundle .

# Windows — 使用 Inno Setup 或 NSIS 制作安装包
# 或直接 ZIP 压缩 Release 目录

# macOS — 使用 create-dmg
create-dmg \
    --volname "saMonopoly" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon-size 100 \
    --app-drop-link 600 185 \
    sa-monopoly-macos.dmg \
    flutter/build/macos/Build/Products/Release/saMonopoly.app
```

### 3.6 PC 特有注意事项

- **Linux**: 需确保 `libgtk-3-dev`、`liblzma-dev` 等依赖已安装
- **Windows**: 需安装 Visual Studio Build Tools 或 MSVC
- **macOS**: 需 Xcode + `flutter config --enable-macos-desktop`
- **分发方式**:
  - Linux: `.deb` / `.rpm` / AppImage / Flatpak
  - Windows: `.msi` 安装包 / `.zip` 绿色版
  - macOS: `.dmg` / Homebrew Cask

---

## 四、Web 部署

### 4.1 核心策略

Web 端无法使用原生动态库，需要将 Rust 编译为 **WASM**。

### 4.2 工具链

| 工具 | 用途 |
|------|------|
| `wasm-pack` | Rust→WASM 编译 + JS 绑定生成 |
| `wasm-bindgen` | Rust↔JS 互操作 |

### 4.3 安装 Web 目标

```bash
rustup target add wasm32-unknown-unknown
cargo install wasm-pack wasm-bindgen-cli
```

### 4.4 适配 Rust 引擎为 WASM

在 `crates/engine-ffi/Cargo.toml` 中添加：

```toml
[lib]
crate-type = ["cdylib", "staticlib", "wasm"]

[target.'cfg(target_arch = "wasm32")'.dependencies]
wasm-bindgen = "0.2"
```

创建 WASM 入口：

```rust
// crates/engine-ffi/src/wasm.rs
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn execute_json(input: &str) -> String {
    sa_monopoly_application::ffi::NativeBridge::execute_json(input)
        .unwrap_or_else(|e| format!("{{\"error\":\"{e}\"}}"))
}
```

### 4.5 编译 WASM

```bash
cd crates/engine-ffi
wasm-pack build --target web --release
# 产物: crates/engine-ffi/pkg/
#   - sa_monopoly_engine_bg.wasm  (WASM 二进制)
#   - sa_monopoly_engine.js       (JS 胶水)
#   - sa_monopoly_engine.d.ts     (TypeScript 声明)
```

### 4.6 Flutter Web 集成

```dart
// flutter/lib/src/native/wasm_bridge.dart
class WasmBridge {
  late final Function _executeJson;

  Future<void> init() async {
    final module = await JsModule.load('sa_monopoly_engine.js');
    _executeJson = module.getFunction('execute_json');
  }

  String execute(String json) {
    return _executeJson.call(json) as String;
  }
}
```

### 4.7 构建 Flutter Web

```bash
cd flutter

# 复制 WASM 产物到 Flutter web 资产目录
cp ../crates/engine-ffi/pkg/* web/

flutter build web --release
# 产物: flutter/build/web/
#   - main.dart.js
#   - assets/
#   - sa_monopoly_engine_bg.wasm
#   - sa_monopoly_engine.js
```

### 4.8 部署到 CDN

```bash
# 部署到任意静态文件服务器
rsync -avz flutter/build/web/ user@server:/var/www/samonopoly/

# 或使用 Netlify / Vercel / GitHub Pages
# 只需将 flutter/build/web/ 目录上传即可

# 需要配置 MIME 类型:
#   .wasm → application/wasm
#   .js   → application/javascript
```

### 4.9 Web 特有注意事项

- **WASM 限制**: 无文件系统 / 无原始 TCP / 无线程（Rust 引擎必须是纯计算）
- **单线程**: `GameEngine::execute` 已是纯函数，适合 WASM
- **文件大小**: WASM 约 2-5MB，gzip 后约 500KB-1MB
- **浏览器兼容**: Chrome 57+, Firefox 52+, Safari 11+, Edge 16+
- **CORS**: 如果引擎和数据在不同域名，需配置 CORS 头
- **Service Worker**: Flutter Web 自动生成，用于离线缓存

---

## 五、部署选项对比

| 维度 | Android | PC (Linux/Win/Mac) | Web |
|------|---------|-------------------|-----|
| **Rust 编译目标** | `aarch64-linux-android` | 本机 `x86_64-unknown-linux-gnu` 等 | `wasm32-unknown-unknown` |
| **Rust 二进制形式** | `.so` (共享库) | `.so` / `.dll` / `.dylib` | `.wasm` |
| **FFI 方式** | `dart:ffi` + `DynamicLibrary` | `dart:ffi` + `DynamicLibrary` | `wasm-bindgen` + JS 桥 |
| **构建工具链** | `cargo-ndk` + Android NDK | 本机编译器 | `wasm-pack` |
| **Flutter 构建命令** | `flutter build apk` | `flutter build linux/windows/macos` | `flutter build web` |
| **产物体积** | 20-50 MB (APK) | 50-100 MB (含运行时) | 5-15 MB (gzip 后 1-3 MB) |
| **分发方式** | Google Play / APK 下载 | 安装包 / 绿色版 | 静态 CDN / 任何 Web 服务器 |
| **用户获取** | Google Play 搜索下载 | 官网下载安装 | 浏览器访问 URL |
| **更新方式** | Google Play 更新 / 热更新 | 重新下载安装包 | 刷新页面即更新 |
| **离线支持** | ✅ 完全离线 | ✅ 完全离线 | ⚠️ 需 Service Worker |
| **性能** | ⭐⭐⭐ (原生) | ⭐⭐⭐⭐⭐ (最高) | ⭐⭐ (WASM 有 overhead) |
| **开发调试** | Android Studio + adb | 本机直接运行 | Chrome DevTools |

---

## 六、推荐部署工作流

### 6.1 开发阶段

```bash
# 本地开发（PC 最快）
cd flutter
flutter run -d linux   # 或 windows / macos

# 修改 Rust 后重新编译
cargo build --release -p sa-monopoly-engine
cp target/release/libsa_monopoly_engine.so flutter/linux/
```

### 6.2 自动化 CI/CD（GitHub Actions）

项目已有 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)，可扩展为：

```yaml
# 在 ci.yml 中添加部署 job
jobs:
  deploy-android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo ndk build --release
      - uses: subosito/flutter-action@v2
      - run: flutter build appbundle --release
      - uses: actions/upload-artifact@v4
        with:
          name: android-aab
          path: flutter/build/app/outputs/bundle/release/app-release.aab

  deploy-web:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: wasm32-unknown-unknown
      - run: wasm-pack build crates/engine-ffi --target web
      - uses: subosito/flutter-action@v2
      - run: flutter build web --release
      - uses: peaceiris/actions-gh-pages@v3
        with:
          publish_dir: flutter/build/web
```

### 6.3 发布清单

| 步骤 | Android | PC | Web |
|------|---------|-----|-----|
| 版本号更新 | `pubspec.yaml` + `Cargo.toml` | 同左 | 同左 |
| 签名 | ✅ 需要 keystore | ✅ 需要代码签名(macOS) | ❌ 不需要 |
| 测试 | `flutter test` + `cargo test` | 同左 | 同左 + 浏览器测试 |
| 构建 | `flutter build appbundle` | `flutter build linux` | `flutter build web` |
| 上传 | Google Play Console | GitHub Releases | CDN / GitHub Pages |
| 通知 | 自动发版说明 | 同左 | 刷新 CDN 缓存 |

---

## 七、快速部署参考

### Android（最简路径）

```bash
# 1. 编译 Rust → ARM so
cargo ndk -t arm64-v8a -o flutter/android/app/src/main/jniLibs build --release

# 2. 构建 APK
cd flutter && flutter build apk --release

# 3. 安装到设备
flutter install
```

### Web（最简路径）

```bash
# 1. 编译 Rust → WASM
wasm-pack build crates/engine-ffi --target web

# 2. 复制 WASM 到 Flutter web
cp -r crates/engine-ffi/pkg/ flutter/web/

# 3. 构建 Web
cd flutter && flutter build web --release

# 4. 用 Python 快速预览
cd build/web && python3 -m http.server 8080
# 浏览器打开 http://localhost:8080
```

### PC Linux（最简路径）

```bash
# 1. 编译 Rust 动态库
cargo build --release -p sa-monopoly-engine

# 2. 复制到 Flutter
cp target/release/libsa_monopoly_engine.so flutter/linux/

# 3. 构建
cd flutter && flutter build linux --release

# 4. 运行
./build/linux/x64/release/bundle/sa_monopoly
```
