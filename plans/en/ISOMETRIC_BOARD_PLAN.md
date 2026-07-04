# Isometric 1.5D Board Rendering Plan

## Overview

Replace the current flat widget-based board with an isometric (2.5D) rendered board featuring:
1. Isometric projection (cabinet/dimetric) for depth perception
2. Mouse-edge scroll camera control
3. Floating minimap overlay showing ownership

## Architecture

```
┌─ GameScreen (main.dart) ──────────────────────────────────┐
│                                                            │
│  Stack (fills entire body area)                           │
│  ┌──────────────────────────────────────────────────┐     │
│  │ IsometricBoardWidget                               │     │
│  │  ├─ IsometricBoardPainter (CustomPainter)          │     │
│  │  │   - tile rendering in isometric projection      │     │
│  │  │   - player token rendering                      │     │
│  │  │   - ownership color indicators                  │     │
│  │  │   - camera offset + zoom transform              │     │
│  │  └─ MouseRegion (edge detection for scroll)        │     │
│  ├─ Positioned (top-right) ──────────────────────┐    │     │
│  │ │ MinimapWidget                                │    │     │
│  │ │  └─ MinimapPainter (CustomPainter)           │    │     │
│  │ │     - simplified isometric view of board     │    │     │
│  │ │     - ownership colors only (no text)        │    │     │
│  │ └──────────────────────────────────────────────┘    │     │
│  └──────────────────────────────────────────────────┘     │
│                                                            │
│  Sidebar (right side, unchanged)                          │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

## Data Flow

```
GameScreen state (_gameState, _currentState)
  │
  ├──► BoardViewModel (tiles, players, propertyOwners)
  │       │
  │       ├──► IsometricBoardWidget
  │       │       │  Reads viewModel.tiles for tile data
  │       │       │  Reads viewModel.players for token positions
  │       │       │  Reads viewModel.propertyOwners for owner colors
  │       │       │
  │       │       └──► IsometricBoardPainter.paint(canvas, size)
  │       │               - Apply camera offset (_camOffsetX, _camOffsetY)
  │       │               - For each tile, compute isometric screen position
  │       │               - Draw tile rhombus with kind color
  │       │               - Draw ownership strip if owned
  │       │               - Draw tile name (abbreviated)
  │       │               - Draw player tokens (circles + initials)
  │       │
  │       └──► MinimapWidget
  │               └──► MinimapPainter.paint(canvas, size)
  │                       - Same isometric projection, fully zoomed out
  │                       - For each tile, draw tiny colored rhombus
  │                       - Ownership color fills the tile
  │                       - No text, no player tokens
  │
  └──► UI interactions
          - Roll button → triggers _onRoll → updates state
          - Camera follows mouse edge → updates _camOffset
```

## Isometric Projection Math

Using a standard 2:1 dimetric (pixel-art style isometric) projection:

```dart
// Tile grid position (row, col) in the 11x11 grid
// Transform to isometric screen coordinates:
double isoX = (col - row) * (tileWidth / 2);
double isoY = (col + row) * (tileHeight / 4);  // Half height for depth

// With camera offset:
double screenX = isoX - _camOffsetX + viewportCenterX;
double screenY = isoY - _camOffsetY + viewportCenterY;

// Tile corners for rhombus shape (centered around isoX, isoY):
// Top, Right, Bottom, Left points
```

The board grid (11x11 for 40 tiles) transforms to a diamond shape:
```
                  [0,0] top-left corner
                 /                      \
    [0,10] TL   /                        \  [10,0] TR
     corner     \                        /   corner
                  \                    /
                  [10,10] BR corner
```

Wait, the isometric transform of a rectangular grid produces a diamond where:
- Grid position (0,0) maps to the left-most point
- Grid position (0, gridSize) maps to the bottom-most point
- Grid position (gridSize, 0) maps to the top-most point
- Grid position (gridSize, gridSize) maps to the right-most point

Actually, for a Monopoly board that wraps around the edges:
- The tiles along the bottom edge of the grid become the lower-left side of the diamond
- The right edge tiles become the lower-right side
- The top edge tiles become the upper-right side
- The left edge tiles become the upper-left side

## Camera Control

```dart
class IsometricCamera {
  double offsetX = 0.0;
  double offsetY = 0.0;
  double zoom = 1.0;

  // Pan by delta
  void pan(double dx, double dy) {
    offsetX += dx;
    offsetY += dy;
    // Clamp to prevent going too far
  }

  // Zoom by factor
  void zoomBy(double factor) {
    zoom = (zoom * factor).clamp(0.5, 3.0);
  }
}
```

**Mouse edge-scroll logic:**
```
EDGE_THRESHOLD = 50px
SCROLL_SPEED = 5px/frame

On mouse move (via MouseRegion):
  if mouseX < EDGE_THRESHOLD → scroll left
  if mouseX > width - EDGE_THRESHOLD → scroll right
  if mouseY < EDGE_THRESHOLD → scroll up
  if mouseY > height - EDGE_THRESHOLD → scroll down
```

Use a `Ticker` (via `SingleTickerProviderStateMixin`) to animate the scroll smoothly.

## New Files

### 1. `flutter/lib/isometric_board.dart` (~400 lines)

Contains:
- `IsometricBoardWidget` (StatefulWidget) - main widget with mouse/camera control
- `IsometricBoardPainter` (CustomPainter) - draws tiles, tokens, ownership
- `MinimapPainter` (CustomPainter) - draws minimap
- Tile position calculation utilities

### 2. Modifications to `flutter/lib/main.dart`

- Replace `BoardWidget` with `IsometricBoardWidget` in layout
- Wrap in `Stack` with `MinimapWidget` overlay
- Keep right sidebar unchanged
- Pass same `BoardViewModel` to `IsometricBoardWidget`

## Implementation Steps

| Step | File | Description |
|------|------|-------------|
| 1 | `isometric_board.dart` | Create IsometricCamera class with offset/zoom/pan |
| 2 | `isometric_board.dart` | Implement tile-to-isometric coordinate transform |
| 3 | `isometric_board.dart` | Implement IsometricBoardPainter (tile rendering) |
| 4 | `isometric_board.dart` | Add player token rendering to painter |
| 5 | `isometric_board.dart` | Add ownership color indicators |
| 6 | `isometric_board.dart` | Implement IsometricBoardWidget (MouseRegion + GestureDetector) |
| 7 | `isometric_board.dart` | Implement edge-scroll camera logic |
| 8 | `isometric_board.dart` | Implement MinimapPainter |
| 9 | `main.dart` | Replace BoardWidget with IsometricBoardWidget + Stack layout |
| 10 | Test | Update widget tests, verify build |
