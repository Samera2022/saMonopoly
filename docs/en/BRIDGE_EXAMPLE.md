# Bridge Example

Example request shape:

```json
{
  "command": "EndTurn",
  "state": {
    "board": {
      "tiles": [],
      "properties": []
    },
    "players": [],
    "ruleset": {
      "id": "classic",
      "version": "0.1.0"
    },
    "current_turn": 0,
    "active_player_index": 0,
    "seed": 1
  }
}
```

The current bridge expects typed command and state values serialized by `serde`.
