@AGENTS.md

## Maintainer's standing instructions

- **Commit and push to `main`.** Work on `main` directly, not on a session branch, unless told otherwise.
- **Keep explanations short.** Skip the unimportant parts.

## Apple Music reference

The redesign's player and lyrics follow the Music app. The maintainer keeps a private extraction of iOS 27.2.1
(build 24B156, iPhone18,1) and uploads it into a session when it is needed:

| File | Contents |
|---|---|
| `apple-music-27.2.1-README.md` | Read first. Findings (backdrop, the full lyrics spec, player values), where everything is, how to re-extract |
| `apple-music-27.2.1-docs.tar.xz` | `appendix/`: files, types, assets, strings, flags, shaders, constants per function (`B-*.md`) |
| `apple-music-27.2.1-raw.tar.xz` | `raw/` dumps and per-function scans, and `tools/` (`disfn.py` disassembles one function) |
| `apple-music-reference.md` | The earlier player reference: backdrop pipeline, motion cover, text ink, type map |

- None of it is in this repository, and none of it may be: the repository is public and the files are derived
  from Apple binaries and assets. Never commit the files, their dumps, assets, shader IR, strings or tools. Unpack
  them into the session's scratchpad, never inside the checkout.
- If a task needs them and they are not uploaded, ask the maintainer for them.
- Match the Music app's result, not its code. Write it the way Retrine is written (its own layers, names, keys and
  helpers); the numbers are what carry over.
- When something is unclear, don't apply a guess first. Decode the Music app's relevant code to the end (the
  README's section 0 says where to look; `tools/disfn.py` reads a function in full) and use the value found.
