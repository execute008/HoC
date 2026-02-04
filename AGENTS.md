# AGENTS.md - Coding Agent Instructions for hoc

This is a **Godot 4.5** game project targeting mobile platforms.

## Project Overview

- **Engine**: Godot 4.5
- **Target Platform**: Mobile (using mobile renderer)
- **Language**: GDScript (primary), with potential for C# or GDExtension
- **Project File**: `project.godot`

## Build / Run / Test Commands

### Running the Project

```bash
# Open in Godot Editor (macOS)
/Applications/Godot.app/Contents/MacOS/Godot --path . --editor

# Run the project directly (requires main scene to be set)
/Applications/Godot.app/Contents/MacOS/Godot --path .

# Run a specific scene
/Applications/Godot.app/Contents/MacOS/Godot --path . res://scenes/main.tscn
```

### Exporting

```bash
# Export for Android (debug)
godot --headless --export-debug "Android" builds/android/game.apk

# Export for iOS (debug)
godot --headless --export-debug "iOS" builds/ios/game.ipa

# List available export presets
godot --headless --export-list
```

### Linting and Formatting (gdtoolkit)

Install gdtoolkit for linting/formatting:
```bash
pip install gdtoolkit
```

```bash
# Lint all GDScript files
gdlint scripts/

# Lint a single file
gdlint scripts/player.gd

# Format all GDScript files
gdformat scripts/

# Format a single file
gdformat scripts/player.gd

# Check formatting without modifying (dry run)
gdformat --check scripts/
```

### Testing with GUT (Godot Unit Testing)

If GUT is installed as an addon:

```bash
# Run all tests via CLI
godot --headless -s addons/gut/gut_cmdln.gd

# Run a single test script
godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://tests/test_player.gd

# Run tests matching a pattern
godot --headless -s addons/gut/gut_cmdln.gd -ginclude_subdirs -gdir=res://tests/

# Run a specific test method
godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://tests/test_player.gd -gunit_test_name=test_health_decreases
```

## Project Structure

```
hoc/
├── project.godot          # Main project configuration
├── icon.svg               # Project icon
├── .editorconfig          # Editor settings (UTF-8)
├── .gitignore             # Ignores .godot/, /android/
├── .godot/                # Engine cache (gitignored)
├── scenes/                # Scene files (.tscn)
│   ├── main.tscn
│   ├── ui/
│   └── levels/
├── scripts/               # GDScript files (.gd)
│   ├── autoload/          # Singleton scripts
│   ├── entities/
│   └── utils/
├── assets/                # Game assets
│   ├── textures/
│   ├── audio/
│   └── fonts/
├── addons/                # Godot plugins
└── tests/                 # GUT test scripts
```

## Code Style Guidelines

### GDScript Naming Conventions

| Element | Style | Example |
|---------|-------|---------|
| Classes | PascalCase | `Player`, `EnemySpawner` |
| Functions | snake_case | `take_damage()`, `spawn_enemy()` |
| Variables | snake_case | `move_speed`, `health_points` |
| Constants | SCREAMING_SNAKE_CASE | `MAX_HEALTH`, `GRAVITY` |
| Signals | snake_case (past tense) | `health_changed`, `enemy_died` |
| Enums | PascalCase (type), SCREAMING_SNAKE_CASE (values) | `enum State { IDLE, RUNNING }` |
| Private members | Leading underscore | `_internal_state`, `_cache` |
| Node references | snake_case with type hint | `@onready var sprite: Sprite2D` |

### File Naming

- Scripts: `snake_case.gd` (e.g., `player_controller.gd`)
- Scenes: `snake_case.tscn` (e.g., `main_menu.tscn`)
- Resources: `snake_case.tres` (e.g., `player_stats.tres`)
- Match script name to class name when possible

### Import and Declaration Order

```gdscript
class_name ClassName
extends BaseClass

# Signals (alphabetical)
signal health_changed(new_health: int)
signal died

# Enums
enum State { IDLE, MOVING, ATTACKING }

# Constants
const MAX_HEALTH: int = 100
const SPEED: float = 200.0

# Exported variables (grouped by category)
@export_group("Movement")
@export var move_speed: float = 100.0
@export var jump_force: float = 300.0

@export_group("Combat")
@export var damage: int = 10

# Public variables
var health: int = MAX_HEALTH
var current_state: State = State.IDLE

# Private variables
var _velocity: Vector2 = Vector2.ZERO

# Onready variables (node references)
@onready var sprite: Sprite2D = $Sprite2D
@onready var collision: CollisionShape2D = $CollisionShape2D

# Built-in virtual methods
func _ready() -> void:
    pass

func _process(delta: float) -> void:
    pass

func _physics_process(delta: float) -> void:
    pass

# Public methods
func take_damage(amount: int) -> void:
    health -= amount
    health_changed.emit(health)

# Private methods
func _update_animation() -> void:
    pass
```

### Type Annotations

Always use static typing for better performance and error detection:

```gdscript
# Variables
var health: int = 100
var position: Vector2 = Vector2.ZERO
var enemies: Array[Enemy] = []
var data: Dictionary = {}

# Function parameters and return types
func calculate_damage(base: int, multiplier: float) -> int:
    return int(base * multiplier)

# Use void for functions that don't return
func _ready() -> void:
    pass
```

### Error Handling

```gdscript
# Use assertions for development-time checks
func set_health(value: int) -> void:
    assert(value >= 0, "Health cannot be negative")
    health = value

# Use is_instance_valid() for node references
if is_instance_valid(target):
    target.take_damage(damage)

# Check for null with explicit comparisons
if node != null:
    node.queue_free()

# Use push_error/push_warning for runtime issues
if file.open(path, FileAccess.READ) != OK:
    push_error("Failed to open file: %s" % path)
    return
```

### Signals Best Practices

```gdscript
# Define signals with typed parameters
signal inventory_updated(item: Item, quantity: int)

# Connect signals in _ready
func _ready() -> void:
    button.pressed.connect(_on_button_pressed)
    health_component.health_changed.connect(_on_health_changed)

# Name handlers with _on_ prefix
func _on_button_pressed() -> void:
    pass

func _on_health_changed(new_health: int) -> void:
    update_health_bar(new_health)
```

### Scene Organization

- Keep scenes focused (single responsibility)
- Use composition over inheritance
- Prefer packed scenes for reusable components
- Use `@onready` for node references instead of `get_node()` in `_ready()`

### Performance Guidelines

- Cache node references with `@onready`
- Avoid `get_node()` or `$` in `_process()` or `_physics_process()`
- Use object pooling for frequently spawned objects
- Prefer `_physics_process()` for movement, `_process()` for visuals
- Use `set_process(false)` to disable unused process functions

## Editor Configuration

### .editorconfig

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
indent_style = tab
indent_size = 4
insert_final_newline = true
trim_trailing_whitespace = true

[*.gd]
indent_style = tab

[*.{json,yml,yaml}]
indent_style = space
indent_size = 2
```

## Common Patterns

### Autoload Singletons

Register in `project.godot` under `[autoload]`:
```ini
[autoload]
GameManager="*res://scripts/autoload/game_manager.gd"
AudioManager="*res://scripts/autoload/audio_manager.gd"
```

### Resource Classes

```gdscript
class_name WeaponData
extends Resource

@export var name: String
@export var damage: int
@export var attack_speed: float
@export var icon: Texture2D
```

## Important Notes for AI Agents

1. **Never modify `.godot/`** - This directory is auto-generated
2. **Use `res://` paths** for project resources, not absolute paths
3. **Scene files are text-based** - `.tscn` files can be edited directly
4. **Test changes** by running the specific scene when possible
5. **Follow Godot's node naming** - Use PascalCase for nodes in the scene tree
6. **Prefer composition** - Create modular, reusable components
