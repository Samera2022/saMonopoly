# Extensibility and Content Contracts

## 1. Command system

All user and AI actions are represented as commands.

Examples:

- roll/spin
- move
- buy property
- upgrade property
- pay rent
- draw card
- trigger special tile
- trade

Commands are validated before execution and emit events after execution.

## 2. Event bus

The event bus is the canonical way to observe state changes.

Events are used for:

- UI updates
- achievements
- plugin reactions
- scheduled effects
- logging
- replay recording

## 3. Scheduler

The scheduler handles delayed and recurring effects.

Examples:

- jail countdown
- hospital recovery
- timed card effects
- interest accumulation
- market updates
- seasonal rule events

## 4. RNG service

A centralized RNG service must be used for all randomness.

Requirements:

- seedable
- replayable
- testable
- abstracted behind a port

## 5. Plugin and mod system

The plugin system supports capability-based extensions.

Capabilities may include:

- read-only game state access
- command registration
- event subscription
- custom tile registration
- custom AI policies
- custom UI metadata
- custom serialization hooks

## 6. Rule scripting

Rule scripts may be written in:

- Lua for compact logic
- JavaScript for broader ecosystem access
- WASM for sandboxed portable logic

Rules must execute inside a restricted host environment.

## 7. Content model

### 7.1 Map definition

A map definition must describe:

- board graph/topology
- tile ordering or graph edges
- tile names
- tile types
- property attributes
- special property categories
- economic rules
- stock market rules
- lottery rules
- card deck definitions
- custom metadata

### 7.2 Property taxonomy

Supported property classes:

- ordinary property
- special property
- extension property

Special property types include:

- card shop
- lottery property
- bank property
- opportunity property
- jail property
- hospital property

Extension property is reserved for future compatibility.

### 7.3 Validation

Maps must be validated for:

- graph connectivity or declared traversal rules
- tile uniqueness
- property attribute consistency
- missing references
- economic balance constraints
- unsupported script references
- version compatibility

### 7.4 Versioning

Map files and rule packs must include:

- schema version
- content version
- engine compatibility range
- optional plugin dependencies

## 8. AI layer

### 8.1 Offline AI

Offline players should use layered decision logic:

1. rule-based safety checks
2. heuristic scoring
3. Monte Carlo / simulation evaluation
4. policy selection

### 8.2 LLM players

LLM integration must be optional and isolated behind the same decision interface.

Requirements:

- time budget per turn
- deterministic fallback
- prompt templates externalized from code
- capability-limited context
- audit logging for generated actions

## 9. Localization

The game and docs must support:

- English
- Russian
- Simplified Chinese

All display strings should use stable localization keys rather than hard-coded text.
