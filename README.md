# spatial-ux

A node-based GDScript editor for desktop and VR. Open a Godot project and its
`.gd` files appear as editable node graphs floating in 3D.

The `.gd` text is the single source of truth. The graph is a live projection of
the tree-sitter CST, and every graph operation compiles to a byte-range text
edit followed by an incremental re-parse. Comments, formatting and anything the
graph can't represent survive untouched; unrepresentable statements show up as
opaque, editable code blocks.

Built against the stock Godot 4.5+ GDExtension API (tested on 4.7.2).

## Build the parser extension

```bash
git submodule update --init
cd gdextension
scons
```

Requires SCons and a C++ compiler (MSVC on Windows). This writes
`bin/libgdsyntax.<platform>.template_debug.<arch>.dll|so`, which
`bin/gdsyntax.gdextension` loads. After the first build, open the project in
the editor once (or run `godot --headless --path . --import`) so Godot
registers the extension.

## Run

```bash
godot --path . -- --open=examples/demo_project
```

- `--open=<folder>`: Godot project to open (relative paths resolve against this project). The last project is remembered.
- `--desktop`: force desktop mode even if an OpenXR runtime is present.

The app starts in VR when OpenXR initialises, otherwise in desktop mode. Press
F1 for the desktop controls; in VR the controls are on the left-wrist panel.

## Functions, inputs and outputs

Each board's top node is the function's signature: its name, one row per
input (parameter) and the output (return type). Every change is one text
edit to the signature line.

- **New function:** click "+ func" on a board's title bar (or press N with a node selected) to add it right after that function, with its board placed alongside. Or click "+ func" under an expanded class sphere (its function orbs showing) to add it at the end of the class. Type `name(a: int) -> float`; the body starts as `pass`, or as a default `return` that compiles for the output type.
- **Inputs:** click "+ input" (or press I), then type `name: Type` or `name := default`. Required inputs are inserted before defaulted ones. Click an input to edit it; clear it to remove it.
- **Output:** click "returns" for a type picker; anything typed in its filter, such as `Array[Vector3]`, can be used as is.
- **Rename** with the name field, or double-click the func node to edit the whole signature. The board and its saved layout follow the new name.
- **From the graph:**
  - Dragging off an input pin offers "+ new input", which adds a parameter of the expected type and wires it in.
  - Dragging off a value offers "return … as the function's output", which inserts the `return` and sets the return type.
- **Delete** a function with "delete" on its title bar; it needs a second click to confirm. Ctrl+Z undoes any of these as one step.

Call sites are not updated when a function is renamed or its inputs change.

## Test

```bash
godot --headless --path . --script res://tests/run_tests.gd
godot --headless --path . --script res://tests/run_tests.gd -- --corpus=C:/some/godot/projects
godot --headless --path . --script res://tests/run_tests.gd -- --only=graph_edits
godot --headless --path . --script res://tests/smoke_app.gd
```

- `test_parser`: parse, edit and re-parse round trips; untouched bytes stay identical; incremental tree equals a fresh parse; CRLF, BOM and UTF-8 handling.
- `test_function_graph`, `test_graph_edits`, `test_function_edits`: CST to graph mapping, and every statement- and function-level edit checked against the exact resulting text.
- `test_corpus`: byte-identical load/save, fuzzed token edits and random graph operations over every `.gd` under `app/`, `tests/` and `~/Downloads/godot-demo-projects-master` (or `--corpus`). Each graph operation must only change the lines it is about and never introduce a parse error.
- `test_index`, `test_layout`: project index, type resolution, drag-off ranking, layout and the sidecar.
- `smoke_app.gd`: drives the full app headless against a temp copy of the demo project.

## Layout of the code

| Path | What |
|---|---|
| `gdextension/` | `GDSyntaxDocument`: UTF-8 buffer + tree-sitter CST, `apply_edits`, incremental re-parse. |
| `app/core/` | `ScriptFile` (file, undo, external-change polling), `FunctionGraph` (CST → statements, exec edges, fields), `GraphEdits` (graph ops → byte edits), `SugiyamaLayout` / `FunctionLayout`, `LayoutStore` (`.graphlayout.json`). |
| `app/index/` | `ProjectIndex` (ClassDB + `data/builtin_api.json` + project scripts + usage/recency), `TypeResolver` (static types), `MemberSearch` (ranked drag-off candidates, fuzzy filter). |
| `app/view/` | Boards, statement nodes, pins, wires, macro force graph, function orbs, 3D panels, virtual keyboard, HUD. |
| `app/input/` | `Pointer` / `Interaction` (one input model for mouse and controllers), desktop fly rig, OpenXR rig. |
| `tools/extract_builtin_api.py` | Regenerates `data/builtin_api.json` from `godot --dump-extension-api`. |

## Notes and known limits

- tree-sitter-gdscript 6.1 does not parse `$%UniqueName`. Statements using it become code blocks; their text is still preserved and editable.
- Expressions stay as text fields; `match`, lambdas, `await` and annotations inside functions are code blocks, as specified.
- Manual node positions are keyed by function + statement path and re-attached by statement-header hash when the code moves. Edited statements fall back to auto layout.
- Type inference is static only: annotations, `:=`, literals, return types and the `extends` chain. `var x = ...` is treated as Variant.
