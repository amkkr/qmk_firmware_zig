# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a QMK (Quantum Mechanical Keyboard) firmware repository. QMK is firmware for custom mechanical keyboards, supporting AVR and ARM controllers. The repository contains keyboard definitions, keymaps, and the core QMK firmware infrastructure.

### Fork Repository Information

**This repository is a fork of https://github.com/qmk/qmk_firmware**

Important rules for working with this fork:

- **One-way sync only**: When instructed to "取り込み" (incorporate/merge), pull changes FROM the upstream repository (qmk/qmk_firmware) INTO this repository
- **Never push upstream**: NEVER push or contribute changes from this repository back to the upstream qmk/qmk_firmware repository
- This is a personal fork for custom keyboard development, not for contributing to the main QMK project
- Keep custom keyboards (madbd1, madbd2, madbd34) and personal configurations in this fork only

## Communication Rules

**All communication with Claude Code must be in Japanese (日本語).**

When working in this repository, all interactions, explanations, and responses should be conducted in Japanese. This includes:
- Explanations of code changes
- Discussion of implementation approaches
- Error messages and debugging information
- Pull request descriptions and commit messages (commit messages should still follow English conventions for the broader QMK community)

## Git Branch Operation Rules

### Basic Principles

1. **No Direct Commits to Master**: Never commit directly to the master branch
2. **Always Create Branches**: Always create a branch before editing or committing files
3. **Branch Name Prefixes**: Branch names must use one of the following prefixes:
   - `feature/` - New feature development
   - `fix/` - Bug fixes
   - `chore/` - Refactoring, documentation updates, etc.
   - `posts/${yyyymmdd}` - When writing today's article
4. **English Branch Names**: Branch names must be written in English
5. **Concise Naming**: Keep branch names short and descriptive
6. **No Direct Merging**: Never merge development branches directly to master
7. **Pull Request Required**: Always push to Github and merge through Pull Requests
8. **No Rebase**: Do not use `git rebase` command. Use `git merge` for conflict resolution
9. **Use PR Template**: Create Pull Request content based on `.github/pull_request_template.md`

### Branch Naming Examples

```bash
# Good examples
feature/user-authentication
fix/login-error
chore/update-dependencies

# Bad examples
new-feature
修正
my-branch
```

### Conflict Resolution Procedure

When conflicts occur with master:

1. **Switch to master**: `git checkout master`
2. **Pull latest changes**: `git pull origin master`
3. **Return to working branch**: `git checkout [branch-name]`
4. **Merge master**: `git merge master`
5. **Resolve conflicts**: Manually resolve conflicts in your editor
6. **Stage resolved files**: `git add [resolved-files]`
7. **Commit merge**: `git commit` (use default merge message)
8. **Push changes**: `git push origin [branch-name]`

**Important**: Never use `git rebase` under any circumstances.

## QMK Development Rules

### Mandatory QMK CLI Usage

**IMPORTANT: Always use official QMK CLI commands. Never use direct file manipulation (mkdir, touch, etc.) for QMK operations.**

- **Creating new keyboards**: Use `qmk new-keyboard` command
  ```bash
  qmk new-keyboard -kb <keyboard_name> -u <username>
  # Interactive mode will prompt for MCU type and layout
  ```

- **Creating new keymaps**: Use `qmk new-keymap` command
  ```bash
  qmk new-keymap -kb <keyboard> -km <keymap_name>
  ```

- **Before executing any QMK-related command**:
  - Consult https://docs.qmk.fm/ documentation
  - Use `qmk <command> --help` to verify correct usage
  - Verify the command exists and is appropriate for the task

- **Prohibited actions**:
  - ❌ `mkdir keyboards/<name>` - Use `qmk new-keyboard` instead
  - ❌ `touch keymap.c` - Use `qmk new-keymap` instead
  - ❌ Manual file creation for QMK structures - Use QMK CLI commands

### Official Documentation Reference

Always refer to https://docs.qmk.fm/ for:
- CLI commands: https://docs.qmk.fm/cli_commands
- Hardware guidelines: https://docs.qmk.fm/hardware_keyboard_guidelines
- RP2040 specific: https://docs.qmk.fm/platformdev_rp2040
- Building firmware: https://docs.qmk.fm/newbs_building_firmware

## Build Commands

### Building Firmware

```bash
# Build firmware for a specific keyboard and keymap
make <keyboard>:<keymap>

# Example: Build the default keymap for madbd34
make madbd34:default

# Build with verbose output
make <keyboard>:<keymap> VERBOSE=1
```

### Flashing Firmware

```bash
# Build and flash firmware to connected keyboard
make <keyboard>:<keymap>:flash

# Example: Flash madbd34 with default keymap
make madbd34:default:flash
```

### QMK CLI Commands

The repository uses the `qmk` CLI tool for various operations:

```bash
# Compile a keyboard (alternative to make)
qmk compile -kb <keyboard> -km <keymap>

# Flash firmware
qmk flash -kb <keyboard> -km <keymap>

# List all keyboards
qmk list-keyboards

# List keymaps for a specific keyboard
qmk list-keymaps -kb <keyboard>

# Get keyboard info
qmk info -kb <keyboard>

# Create a new keymap
qmk new-keymap -kb <keyboard>

# Lint keyboard files
qmk lint -kb <keyboard>

# Clean build artifacts
qmk clean
```

### Testing

```bash
# Run tests (in test directory)
make test:all

# Clean all build artifacts
make clean
```

## Repository Structure

### Core Directories

- **`keyboards/`** - Keyboard-specific configurations, organized by manufacturer/keyboard name
  - Each keyboard has: `info.json` (hardware config), `rules.mk` (build rules), `config.h` (C config), `keymaps/` (keymap definitions)
  - Current custom keyboards: `madbd1/`, `madbd2/`, `madbd34/`

- **`quantum/`** - Core QMK firmware code
  - Action/keycode handling (`action*.c/h`, `keycode*.c/h`)
  - Feature implementations (RGB, audio, encoders, etc.)
  - Common keyboard functionality (`keyboard.c`, `matrix.c`)
  - Process handlers for different keycode types

- **`tmk_core/`** - Low-level TMK keyboard firmware base
  - Protocol implementations for USB, etc.

- **`platforms/`** - Platform-specific code for different MCUs
  - `avr/` - AVR platform support
  - `chibios/` - ARM platform support (ChibiOS RTOS)
  - `arm_atsam/` - Atmel SAM ARM support

- **`drivers/`** - Hardware driver implementations (LEDs, displays, sensors, etc.)

- **`builddefs/`** - Build system makefiles for features and compilation

- **`layouts/`** - Community layout definitions (layouts shared across keyboards)

- **`users/`** - User-specific code that can be shared across keyboards

## Keyboard Configuration

### Key Files for Each Keyboard

1. **`info.json`** - Main hardware configuration
   - Matrix configuration (pins, rows, cols)
   - USB IDs (VID/PID)
   - Features enabled/disabled
   - Layout definitions (physical key positions)
   - Processor and bootloader type

2. **`rules.mk`** - Build-time feature flags
   - Enable/disable features (e.g., `MOUSEKEY_ENABLE = yes`)
   - Include additional source files

3. **`config.h`** - C preprocessor configuration
   - Hardware-specific settings
   - Feature customization

4. **`keymaps/<name>/keymap.c`** - Keymap definitions
   - Layer definitions using `LAYOUT()` macro
   - Custom keycode handling
   - Key overrides and tap dance configurations

### Common Keyboard Features

Features controlled in `info.json` or `rules.mk`:
- `bootmagic` - Boot configuration via key combinations
- `mousekey` - Mouse control via keyboard
- `extrakey` - Media keys and system control
- `nkro` - N-key rollover
- `rgb_matrix` / `rgblight` - RGB lighting
- `audio` - Audio/speaker support
- `encoder` - Rotary encoder support

## Current Custom Keyboards

This repository contains custom keyboard definitions:

- **madbd1** - Custom keyboard configuration
- **madbd2** - Custom keyboard configuration
- **madbd34** - Custom split keyboard (RP2040-based)
  - 4x12 matrix with split layout
  - RP2040 processor with rp2040 bootloader
  - 4 layers: base, numbers/symbols, navigation, function/media/mouse

## Keymap Development

### Layer System

Keymaps use a layer-based system where multiple layers can be active simultaneously:

- Base layer (0) is always active
- Higher layers can be momentarily activated (`MO(n)`) or toggled (`TG(n)`)
- Layer-tap keys (`LT(layer, keycode)`) activate a layer when held, send keycode when tapped

### Common Keycodes

- Standard keys: `KC_A`, `KC_1`, `KC_ESC`, etc.
- Modifiers: `KC_LCTL`, `KC_LSFT`, `KC_LGUI`, `KC_LALT`
- Special: `KC_NO` (no action), `KC_TRNS` (transparent, use lower layer)
- Layer switching: `MO(n)` (momentary), `LT(n, kc)` (layer-tap), `TG(n)` (toggle)
- Media: `KC_MUTE`, `KC_VOLU`, `KC_VOLD`
- Mouse: `KC_MS_U/D/L/R` (movement), `KC_WH_U/D/L/R` (wheel)

### Keymap File Structure

```c
#include QMK_KEYBOARD_H

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
    [0] = LAYOUT(
        // Key definitions matching the LAYOUT macro in info.json
    ),
    [1] = LAYOUT(
        // Layer 1 definitions
    ),
    // Additional layers...
};
```

## Bootloader Entry

To flash firmware, enter bootloader mode:

1. **Bootmagic reset** - Hold top-left key while plugging in keyboard
2. **Physical reset button** - Press reset button on PCB
3. **Keycode** - Press key mapped to `QK_BOOT` in your keymap

## Documentation

- Official docs: https://docs.qmk.fm
- Getting started guide: `docs/newbs.md`
- Feature documentation in `docs/` directory
- CLI documentation: `qmk --help` or `qmk <subcommand> --help`
