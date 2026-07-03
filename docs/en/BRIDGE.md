# Engine Bridge

The bridge exposes platform-neutral execution helpers that can later be wired into Flutter, native desktop, or Web frontends.

It accepts serialized requests and returns serialized responses so frontends can communicate with the Rust engine through a stable contract.

An example request shape is available from the application bridge module for integration testing and frontend prototyping.
