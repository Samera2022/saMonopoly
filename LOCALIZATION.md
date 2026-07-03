# Localization Guide

## Supported languages

The product must ship with first-class support for:

- English (`en`)
- Russian (`ru`)
- Simplified Chinese (`zh-Hans`)

## Rules

- Use localization keys for all user-visible text.
- Never hard-code text inside UI or game logic.
- Keep translation files versioned alongside code.
- Prefer short, stable keys based on intent, not sentence wording.
- Treat documentation as localized content, not an afterthought.

## Documentation structure

Documentation should be maintained in parallel language sets:

- `docs/en`
- `docs/ru`
- `docs/zh-Hans`

Each user-facing architectural document should have matching translations.

## Runtime behavior

Runtime localization should support:

- language detection and manual override
- fallback to English when a key is missing
- pluralization support
- number and currency formatting
- date/time formatting where needed

## Asset naming

Use locale-aware asset bundles where required:

- images
- tutorial text
- card text
- map metadata
- plugin-provided UI labels

## Translation workflow

1. Add or change a stable localization key.
2. Update English source text.
3. Provide Russian and Simplified Chinese translations.
4. Validate that all supported locales pass build checks.
5. Review docs for parity across all three languages.
