# saMonopoly

saMonopoly is a cross-platform Monopoly engine and game platform designed around one shared core with thin frontends for Android, PC, and Web.

## Architecture

The project follows a clean three-tier architecture:

```
┌─────────────────────────────────────────────┐
│              Flutter Frontend               │
│   (Android / PC / Web)                      │
│                                             │
│  ┌─────────┐ ┌──────────┐ ┌─────────────┐  │
│  │ Board   │ │ Settings │ │ i18n (en/zh)│  │
│  │ Render  │ │ Dialogs  │ │ Localization │  │
│  └────┬────┘ └────┬─────┘ └──────┬──────┘  │
│       └───────┬───┘              │          │
│               │ BridgeClient (FFI/JSON)     │
└───────────────┼─────────────────────────────┘
                │ JSON over FFI / simulation
┌───────────────┼─────────────────────────────┐
│    Rust Engine (shared core)                │
│  ┌──────────┐ ┌────────────┐ ┌───────────┐  │
│  │ Domain   │ │Application │ │ Infra     │  │
│  │ (types,  │ │ (commands, │ │ (plugins, │  │
│  │  state,  │ │  engine,   │ │  scripting│  │
│  │  board)  │ │  events)   │ │  network) │  │
│  └──────────┘ └────────────┘ └───────────┘  │
└─────────────────────────────────────────────┘
```

## Project Structure

```
saMonopoly/
├── content/                  # Game content (maps, packs)
│   ├── maps/builtin/         # Built-in map definitions
│   └── packs/                # Content pack manifests
├── crates/
│   ├── domain/               # Core domain types (board, player, property, state)
│   ├── application/          # Game logic (commands, engine, events, bridge)
│   └── infra/                # Infrastructure (plugins, scripting, network, persistence)
├── flutter/                  # Flutter cross-platform frontend
│   ├── assets/
│   │   ├── content/          # Bundled content packs
│   │   └── i18n/             # Localisation resource files (en, zh)
│   └── lib/
│       ├── l10n/             # Localisation support classes
│       ├── board_view.dart   # Board rendering with CustomPainter
│       ├── bridge_client.dart# FFI/JSON bridge client
│       ├── content_pack.dart # Content pack view models
│       ├── content_pack_loader.dart
│       └── main.dart         # Full game UI with state management
├── docs/                     # Documentation (en, ru, zh-Hans)
└── plans/                    # Development roadmaps and audit
```

## Implemented Features

### Core Engine (Rust)

| Component | Status | Description |
|-----------|--------|-------------|
| Domain Types | ✅ | Board, Player, Property, Tile, GameState, Rules |
| Commands | ✅ | Roll, BuyProperty, Upgrade, PayRent, EndTurn, Trade, Auction, Bid, Mortgage, Redeem, SellShares, BuyCard |
| Events | ✅ | Full event system with 30+ event types |
| Engine | ✅ | Command execution pipeline with state mutation |
| Bridge | ✅ | BridgeRequest/BridgeResponse FFI serialisation |
| Map Validation | ✅ | Schema validation with error reporting |
| Scheduler | ✅ | Turn-based scheduling system |
| Session Sync | ✅ | Game session synchronisation |
| Economy | ✅ | Rent calculation, pricing, upgrades |
| Special Rules | ✅ | Jail, Hospital, Cards, Lottery, Stock Market |
| Effects System | ✅ | Card effects and modifier pipeline |

### Infrastructure (Rust)

| Component | Status | Description |
|-----------|--------|-------------|
| Plugins | ✅ | Enhanced Plugin trait, PluginRegistry with enable/disable, permission system, dynamic loading config |
| Scripting | ✅ | Simple expression evaluator, JS-flavoured evaluator, WASM host stub, comment stripping |
| Network | ✅ | Enhanced NetworkTransport trait, SessionManager, WebSocketConfig, broadcast support |
| Discovery | ✅ | Plugin discovery, content pack discovery, build script config, `discover_all()` helper |
| Content | ✅ | ContentCatalog, JsonContentLoader, ValidatingContentLoader, default catalog builder |
| AI | 🟡 | Basic AI stub, LLM adapter scaffolding |
| Persistence | 🟡 | Save/load scaffolding |
| RNG | ✅ | XorShift64 implementation |
| Prompts | 🟡 | LLM prompt templates |

### Flutter Frontend (Dart)

| Component | Status | Description |
|-----------|--------|-------------|
| Bridge Client | ✅ | BridgeRequest/BridgeResponse classes, executeCommand with simulation, PlayerViewModel parsing |
| Board Rendering | ✅ | CustomPainter-based board renderer, classic square layout, tile drawing, player tokens |
| Game UI | ✅ | Full game screen with player info bar, dice display, action buttons (Roll/Buy/End Turn/Trade/Card Shop), event log |
| Settings Dialog | ✅ | Player count (2-6), custom names, AI/human toggle |
| Dialogs | ✅ | Buy property confirmation, auction, trade proposal, card shop |
| State Management | ✅ | InheritedWidget-based GameStateWidget, event logging |
| i18n | ✅ | AppLocalizations with JSON resource files (English, Simplified Chinese), fallback support |
| Content Loading | ✅ | Content pack JSON loader and view models |

## Getting Started

### Prerequisites

- **Rust** (1.75+): [rustup.rs](https://rustup.rs/)
- **Flutter** (3.24+): [flutter.dev](https://flutter.dev/)
- **Platform SDKs**: Android SDK (for Android builds), Web browser (for Web builds)

### Build & Run

```bash
# Rust engine (unit tests)
cd crates
cargo test --workspace

# Flutter frontend
cd flutter
flutter pub get
flutter run -d chrome   # Web
flutter run -d linux    # Linux desktop
flutter run -d android  # Android
```

### Rust crate test matrix

```bash
# Test all crates
cargo test -p sa-monopoly-domain
cargo test -p sa-monopoly-application
cargo test -p sa-monopoly-infra

# Build only (no tests)
cargo build --workspace
```

## Content Packs

Content packs define the tile layout, property sets, and rules for a game board. They are JSON files placed in `content/packs/`.

Example structure:

```json
{
  "id": "my-pack",
  "version": "0.1.0",
  "maps": [
    {
      "id": "classic",
      "version": "0.1.0",
      "name_key": "maps.classic",
      "tiles": [
        { "id": "start", "name_key": "tile.start", "tile_type": "Start", "attributes": {} },
        { "id": "prop_1", "name_key": "tile.prop_1", "tile_type": "OrdinaryProperty", "attributes": {} }
      ],
      "rules": {
        "allow_custom_topology": false,
        "allow_stock_market": false,
        "allow_lottery": false,
        "allow_card_system": true
      }
    }
  ]
}
```

## Scripting

The engine supports multiple scripting backends through the `ScriptHost` trait:

| Backend | Status | Description |
|---------|--------|-------------|
| **Simple** | ✅ | `{variable}` substitution, arithmetic, comparisons, `if/then/else`, function calls |
| **JavaScript** | ✅ | JS-flavoured syntax: `cond ? a : b`, `$var` / `${var}`, `//` and `/* */` comments |
| **WASM** | ✅ | Stub host (returns descriptive error; ready for wasmtime/wasmer integration) |
| **Lua** | 🟡 | Via optional `mlua` crate |

## Plugins

Plugins are registered through the `Plugin` trait with a permission-based sandbox:

```rust
use sa_monopoly_infra::plugins::*;

struct MyPlugin;

impl Plugin for MyPlugin {
    fn id(&self) -> &str { "my-plugin" }
    fn version(&self) -> &str { "1.0.0" }
    fn permissions(&self) -> &PermissionSet {
        // Request only read + event injection
        &PermissionSet::default_safe()
    }
}

let mut registry = InMemoryPluginRegistry::default();
registry.register(Box::new(MyPlugin)).unwrap();
```

## Networking

The network layer provides configuration for future WebSocket multiplayer:

```rust
use sa_monopoly_infra::network::*;

let mut mgr = SessionManager::new();
let ep = SessionEndpoint::new("192.168.1.100", 9000);
let session_id = mgr.create_session("My Game", ep, 4);
mgr.join_session(&session_id, "player_1").unwrap();
mgr.join_session(&session_id, "player_2").unwrap();
mgr.start_session(&session_id).unwrap();
```

## Localisation

The Flutter frontend supports English and Simplified Chinese out of the box. Resource files live in `flutter/assets/i18n/`.

```dart
// In any widget:
final l10n = AppLocalizations.of(context);
Text(l10n.translate('game.roll'));
// With parameters:
Text(l10n.translate('log.rolled', {
  'dice1': '3', 'dice2': '5', 'total': '8',
}));
```

## License

This project is open source. See license information in the repository.
