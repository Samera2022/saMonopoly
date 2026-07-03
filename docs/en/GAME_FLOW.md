# Game Flow

The current flow is:

1. load content pack
2. validate map
3. create initial game state
4. execute commands through the bridge
5. resolve movement, special tiles, and economy actions
6. optionally snapshot for session sync
