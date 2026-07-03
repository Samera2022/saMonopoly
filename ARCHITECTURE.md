# Monopoly Platform Architecture

## 1. Goal

Build a highly extensible Monopoly platform with one shared core engine and thin shells for Android, PC, and Web.

## 2. Stack

- **Core:** Rust
- **UI shells:** Flutter
- **Rule extensions:** Lua, JavaScript, WASM

## 3. Dependency rules

The architecture is organized as a strict inward dependency graph:

- `domain` depends on nothing
- `application` depends only on `domain`
- `infra` depends on `application` and `domain`
- `platform` depends on `application` and `infra` interfaces, not the reverse

## 4. Module boundaries

### 4.1 `core/domain`
Contains pure game concepts:

- players, money, turns
- properties and upgrades
- board topology
- rent and special tile semantics
- jail, bank, hospital, card shop, opportunity, lottery, and stock-market concepts

This module must remain deterministic, side-effect free, and fully testable.

### 4.2 `core/application`
Contains use cases and orchestration:

- game session lifecycle
- command handling
- event emission
- turn scheduler
- AI decision requests
- rules execution coordination
- save/load orchestration

### 4.3 `core/infra`
Contains adapters and external integrations:

- RNG implementation
- persistence formats
- plugin host
- mod loader
- map validator
- Lua/JavaScript/WASM runner
- LLM adapter layer
- telemetry and logging bridges

### 4.4 `platform/android`, `platform/pc`, `platform/web`
Contain only presentation and platform glue:

- rendering
- input handling
- resource loading
- localization binding
- platform-specific sharing, storage, permissions, and packaging

## 5. Runtime boundaries

All external effects must go through ports:

- clock
- RNG
- filesystem
- network
- asset loading
- script runtime
- AI provider

This ensures replayability and makes unit testing deterministic.

## 6. Determinism policy

The engine must preserve deterministic simulation when the same seed, map version, ruleset, and player decisions are supplied.

## 7. Versioning policy

- Core save data is versioned
- Map schemas are versioned
- Plugin APIs are versioned
- Script rule contracts are versioned

Backward compatibility must be explicit and tested.
