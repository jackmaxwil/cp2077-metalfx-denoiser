#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

// ============================================================================
// Versioning
// ============================================================================

#define MODMENU_API_VERSION 1u

// ============================================================================
// Core types
// ============================================================================

typedef enum ModMenuEntryType : uint32_t
{
    MODMENU_ENTRY_PAGE = 0,
    MODMENU_ENTRY_TOGGLE = 1,
    MODMENU_ENTRY_SLIDER = 2,
    MODMENU_ENTRY_BUTTON = 3,
    MODMENU_ENTRY_TEXT = 4,
} ModMenuEntryType;

typedef enum ModMenuCapabilityFlags : uint32_t
{
    MODMENU_CAP_NONE = 0,
    MODMENU_CAP_UI = 1u << 0,
    MODMENU_CAP_HOOKING = 1u << 1,
    MODMENU_CAP_FILE_IO = 1u << 2,
    MODMENU_CAP_NETWORK = 1u << 3,
} ModMenuCapabilityFlags;

typedef struct ModMenuString
{
    const char* ptr; // UTF-8, null-terminated
} ModMenuString;

typedef struct ModMenuId
{
    // Stable identifier for persistence and indexing. Must be unique within a given mod.
    ModMenuString id;
} ModMenuId;

typedef struct ModMenuEntryPath
{
    ModMenuId modId;
    ModMenuId pageId;
    ModMenuId entryId;
} ModMenuEntryPath;

// ============================================================================
// Callbacks (invoked by ModMenu backend)
// ============================================================================

typedef void (*ModMenuOnToggleChangedFn)(const ModMenuEntryPath* path, bool value);

typedef void (*ModMenuOnSliderChangedFn)(const ModMenuEntryPath* path, float value);

typedef void (*ModMenuOnButtonPressedFn)(const ModMenuEntryPath* path);

// ============================================================================
// Registration descriptors
// ============================================================================

typedef struct ModMenuModInfo
{
    ModMenuString modId;   // stable ID (e.g. "TweakXL", "MetalFXDenoiser")
    ModMenuString name;    // display name
    ModMenuString author;  // optional
    ModMenuString version; // optional
    uint32_t capabilityFlags;
} ModMenuModInfo;

typedef struct ModMenuPageInfo
{
    ModMenuString pageId; // stable
    ModMenuString title;  // display
} ModMenuPageInfo;

typedef struct ModMenuToggleInfo
{
    ModMenuString entryId; // stable
    ModMenuString title;   // display
    bool defaultValue;
    ModMenuOnToggleChangedFn onChanged; // optional
} ModMenuToggleInfo;

typedef struct ModMenuSliderInfo
{
    ModMenuString entryId; // stable
    ModMenuString title;   // display
    float minValue;
    float maxValue;
    float step;
    float defaultValue;
    ModMenuOnSliderChangedFn onChanged; // optional
} ModMenuSliderInfo;

typedef struct ModMenuButtonInfo
{
    ModMenuString entryId; // stable
    ModMenuString title;   // display
    ModMenuOnButtonPressedFn onPressed; // optional
} ModMenuButtonInfo;

// ============================================================================
// API surface
// ============================================================================

typedef struct ModMenuApi
{
    uint32_t apiVersion;

    // Mod registration
    bool (*RegisterMod)(const ModMenuModInfo* mod);
    bool (*RegisterPage)(const char* modId, const ModMenuPageInfo* page);

    // Entries
    bool (*RegisterToggle)(const char* modId, const char* pageId, const ModMenuToggleInfo* toggle);
    bool (*RegisterSlider)(const char* modId, const char* pageId, const ModMenuSliderInfo* slider);
    bool (*RegisterButton)(const char* modId, const char* pageId, const ModMenuButtonInfo* button);

    // Optional: allow a mod to register a function that ModMenu can call later for additional registration.
    // Reserved for future expansion without breaking ABI.
    void* reserved[8];
} ModMenuApi;

// Exported by ModMenu plugin.
// Mods can dlsym("ModMenu_GetApi") and then call through the returned table.
const ModMenuApi* ModMenu_GetApi(void);

// Optional exported by other mods (if they prefer ModMenu to discover & call them):
//   extern "C" bool ModMenu_Register(const ModMenuApi* api);

#ifdef __cplusplus
} // extern "C"
#endif

