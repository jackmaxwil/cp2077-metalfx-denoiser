#!/usr/bin/env python3
"""
NRD Address Discovery Script for MetalFX Denoiser Mod
Finds function addresses for NRD denoiser hooks in Cyberpunk 2077 macOS binary.
"""

import struct
from pathlib import Path
import json

BINARY_PATH = Path.home() / "Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
IMAGE_BASE = 0x100000000
OUTPUT_FILE = Path(__file__).parent.parent / "docs" / "nrd_addresses.json"


def decode_adrp(instr: int, pc: int) -> int | None:
    """Decode ADRP instruction to get target page address."""
    if (instr >> 24) & 0x9F != 0x90:
        return None
    immlo = (instr >> 29) & 0x3
    immhi = (instr >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & 0x100000:
        imm -= 0x200000
    return (pc & ~0xFFF) + (imm << 12)


def find_string_offset(data: bytes, string: str) -> int | None:
    """Find string in binary data."""
    encoded = string.encode('utf-8')
    pos = data.find(encoded)
    return pos if pos != -1 else None


def find_code_references(data: bytes, target_offset: int, max_search: int = 0x6000000) -> list[int]:
    """Find ADRP+ADD sequences that reference a target address."""
    target_page = (IMAGE_BASE + target_offset) & ~0xFFF
    target_off = (IMAGE_BASE + target_offset) & 0xFFF
    refs = []
    
    for i in range(0x4000, min(len(data) - 8, max_search), 4):
        try:
            instr1 = struct.unpack('<I', data[i:i+4])[0]
            instr2 = struct.unpack('<I', data[i+4:i+8])[0]
            
            page = decode_adrp(instr1, IMAGE_BASE + i)
            if page is None or page != target_page:
                continue
            
            # Check ADD immediate
            if (instr2 >> 24) & 0xFF != 0x91:
                continue
            
            add_imm = (instr2 >> 10) & 0xFFF
            if add_imm == target_off:
                refs.append(IMAGE_BASE + i)
                
        except:
            continue
    
    return refs


def find_function_start(data: bytes, ref_addr: int, max_search: int = 0x2000) -> int | None:
    """Find function start by scanning backwards for prologue."""
    ref_offset = ref_addr - IMAGE_BASE
    
    for back in range(0, max_search, 4):
        check_off = ref_offset - back
        if check_off < 0:
            break
        
        instr = struct.unpack('<I', data[check_off:check_off+4])[0]
        
        # STP X29, X30, [SP, #-X]! (standard prologue)
        if instr & 0xFFC07FFF == 0xA9807BFD:
            return IMAGE_BASE + check_off
        
        # PACIBSP (pointer auth)
        if instr == 0xD503237F:
            # Check next instruction for STP
            next_instr = struct.unpack('<I', data[check_off+4:check_off+8])[0]
            if next_instr & 0xFFC07FFF == 0xA9807BFD:
                return IMAGE_BASE + check_off
            
    return None


def main():
    print("=== NRD Address Discovery ===\n")
    
    if not BINARY_PATH.exists():
        print(f"Error: Binary not found at {BINARY_PATH}")
        return
    
    print(f"Loading binary: {BINARY_PATH}")
    data = BINARY_PATH.read_bytes()
    print(f"Binary size: {len(data):,} bytes\n")
    
    # Target strings to find
    targets = {
        # REBLUR denoiser passes
        "REBLUR_Diffuse_Temporal": "REBLUR_Diffuse - Temporal accumulation",
        "REBLUR_DiffuseSpecular_Temporal": "REBLUR_DiffuseSpecular - Temporal accumulation",
        "REBLUR_Diffuse_Blur": "REBLUR_Diffuse - Blur",
        "REBLUR_Diffuse_PostBlur": "REBLUR_Diffuse - Post-blur",
        "REBLUR_Diffuse_HistoryFix": "REBLUR_Diffuse - History fix",
        "REBLUR_Diffuse_PrePass": "REBLUR_Diffuse - Pre-pass",
        
        # NRD configuration
        "NrdInputs": "NrdInputs",
        
        # RTXDI denoising
        "RTXDI_Denoising_Enable": "EnableRTXDIDenoising",
        "RTXDI_DenoisingMask": "DenoisingRtxdiShaderMaskAAPL",
        
        # Render nodes
        "CRenderNode_RayTracingFilterOutput": "CRenderNode_RayTracingFilterOutput",
        "CRenderNode_FilterRayTracedLocalShadow": "CRenderNode_FilterRayTracedLocalShadow",
        
        # Shadow filtering
        "SIGMA_Shadow": "SIGMA_Shadow",
    }
    
    discovered = {}
    
    for name, string in targets.items():
        str_offset = find_string_offset(data, string)
        if str_offset is None:
            print(f"[SKIP] {name}: string not found")
            continue
        
        refs = find_code_references(data, str_offset)
        if not refs:
            print(f"[SKIP] {name}: no code references")
            discovered[name] = {
                "string_offset": hex(str_offset),
                "code_refs": [],
                "function_offset": None
            }
            continue
        
        # Find function start from first reference
        func_start = find_function_start(data, refs[0])
        func_offset = (func_start - IMAGE_BASE) if func_start else None
        
        discovered[name] = {
            "string_offset": hex(str_offset),
            "code_refs": [hex(r) for r in refs[:5]],
            "function_addr": hex(func_start) if func_start else None,
            "function_offset": hex(func_offset) if func_offset else None
        }
        
        print(f"[FOUND] {name}:")
        print(f"        String @ 0x{str_offset:X}")
        print(f"        Code refs: {len(refs)}")
        if func_start:
            print(f"        Function @ 0x{func_start:X} (offset 0x{func_offset:X})")
        print()
    
    # Find NRD memory functions (from symbols)
    print("\n=== NRD Symbol Functions ===\n")
    
    import subprocess
    result = subprocess.run(
        ['nm', '-n', str(BINARY_PATH)],
        capture_output=True, text=True
    )
    
    nrd_symbols = {}
    for line in result.stdout.splitlines():
        if 'Nrd' in line:
            parts = line.split()
            if len(parts) >= 3:
                addr = int(parts[0], 16)
                offset = addr - IMAGE_BASE
                name = ' '.join(parts[2:])
                nrd_symbols[name] = {
                    "addr": hex(addr),
                    "offset": hex(offset)
                }
                print(f"[SYMBOL] {name}: 0x{addr:X} (offset 0x{offset:X})")
    
    discovered["_symbols"] = nrd_symbols
    
    # Save results
    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_FILE, 'w') as f:
        json.dump(discovered, f, indent=2)
    
    print(f"\n=== Results saved to {OUTPUT_FILE} ===")
    
    # Generate C++ header snippet
    print("\n=== Address Constants for C++ ===\n")
    print("namespace NRD {")
    for name, info in discovered.items():
        if name.startswith("_"):
            continue
        offset = info.get("function_offset")
        if offset:
            print(f"    constexpr uintptr_t {name} = {offset};")
    print("}")


if __name__ == "__main__":
    main()
