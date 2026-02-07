# MetalFX Denoiser — Status

> **Last updated:** 2026-02-01  

## Canonical docs

- **Development guide / detailed status:** `docs/DEVELOPMENT.md`
- **Addresses overview:** `docs/ADDRESSES.md`
- **Validation notes:** `docs/VALIDATION.md`

## Current state (high signal)

- The project is in **early development** with core infrastructure in place.
- Address discovery exists and is scripted (`scripts/discover_nrd_addresses.py`), but runtime integration + buffer RE remain the main work.

## Key “source of truth” files

- Address override header: `lib/Support/macOS/AddressResolverOverride.hpp`
- Discovery output: `docs/nrd_addresses.json`
- Frida hook script(s): `scripts/metalfx_hooks.min.js` (production) and related debug tooling

## After a game update

1. Run address discovery:

```bash
python3 scripts/discover_nrd_addresses.py
```

2. Update:
   - `lib/Support/macOS/AddressResolverOverride.hpp`
   - `scripts/metalfx_hooks.min.js`

3. Rebuild and validate per `docs/DEVELOPMENT.md`.

