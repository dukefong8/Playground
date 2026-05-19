---
name: ghc-debug
description: Haskell debugging via nvim-mcp-controlled GHCi terminal + source sync. Use when debugging Haskell, hitting breakpoints, inspecting bindings, or syncing editor to GHCi stop location.
---

# GHC Debug Skill

Default: use `nvim-mcp`, not tmux.

Loop:
- find terminal buffer running `ghci`
- send commands with `nvim-mcp.exec_lua`
- read tail with `nvim-mcp.read`
- sync source with `nvim-mcp.navigate`
- print state only after sync

Use tmux only if GHCi is not inside Neovim.

After every file edit, read `ghcid.txt`.

## Find GHCi term

```lua
local out = {}
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) then
    local bt = vim.api.nvim_get_option_value('buftype', { buf = b })
    if bt == 'terminal' then
      table.insert(out, {
        buf = b,
        name = vim.api.nvim_buf_get_name(b),
        job = vim.b[b].terminal_job_id,
      })
    end
  end
end
return out
```

Confirm prompt like `*Todo λ>`, `*Test λ>`, `*Main λ>`.

## Sync + resume

Order:
1. read terminal tail
2. parse newest stop
3. decide resume mode:
   - `Press enter to continue` -> Enter
   - GHCi prompt -> `:continue`
4. move cursor to newest stop
5. print args/locals/DB

Stop formats:

`Stopped in ...`:

```text
Stopped in Todo.getTodosPage, src/Todo.hs:(119,21)-(122,31)
```

`Breakpoint Hit`:

```text
### Breakpoint Hit ###
(src/Todo.hs:148:3-13)
```

Rules:
- GHCi `:break`: sync to function entry line
- `Breakpoint Hit`: sync to explicit line

## Breakpoint workflow

Prefer GHCi `:break` first.

```text
:break [<mod>] <l> [<col>]  set a breakpoint at the specified location
:break <name>               set a breakpoint on the specified function
:show breaks                show all breakpoints
:delete *                   clear all breakpoints
:reload                     reload and clear breakpoints
```

Use source breakpoints when you need post-bind state:

```haskell
breakpoint
breakpointM
breakpointIO
```

- use `:break` at function entry
- use `breakpointM` in handler / monadic code when you need post-bind state
- use `breakpointIO` only for IO stacks if `breakpointM` is wrong

## Inspect state at each stop

After sync:
```text
:show context
:show bindings
:print x
:sprint x
:force x
x
```

Notes:
- at entry, only early bindings may exist
- `:show bindings` may only show placeholders
- if a binding has `Show`, prefer evaluating `x` directly
- for `Text`, evaluating the binding name directly is usually better than `:force`
- avoid dumping everything if only one or two locals matter

Use direct `psql -c`, not tmux pg.

```bash
psql -c "select id, title, completed from todos order by id;"
```

Keep the default `psql` table format:

```text
 id  | title  | completed
-----+--------+----------
 971 | Task C | f
```

## Reporting format

Keep output short and flat:

```text
src/Todo.hs:129 getTodoListPartial
filter_=Just "active"
search_=Nothing
items=[Task A done, Task B done, Task C]
 id  | title  | completed
-----+--------+----------
 969 | Task A | t
 970 | Task B | t
 971 | Task C | f
```

If only an entry `:break` is active, say locals are not in scope yet.

## Auto-step loop

1. Read last terminal lines.
2. If `Press enter to continue` is present, send Enter.
3. Else if the last line is a GHCi prompt, send `:continue`.
4. Wait briefly.
5. Read the new tail.
6. Parse the newest stop.
7. Sync the source cursor.
8. Print concise state and DB rows.

Stop when:
- tests finish
- GHCi returns to a normal prompt with no new stop
- a new error or blocker appears
