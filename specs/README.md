# Module spec template

Copy this file to `specs/<name>.md` (matching `MODULE_NAME`) and fill in every
section before implementing the module.

## Purpose

One or two sentences: what the module configures and why.

## Source of truth

What on the reference machine (the EndeavourOS setup this ports) this captures (files, settings, package lists),
and where the captured data lives in this repository.

## Files and packages touched

- Files created or modified (use `$HOME`-relative or system paths, never a
  hardcoded user).
- Packages installed (and the repository, key and pin when it is not Kali).
- Services or units enabled.

## Hardware detection

How the module adapts to CPU/GPU vendor or other hardware, and what it does
when the hardware is unknown. Write "none" if not applicable.

## Idempotency check

How the module decides there is nothing to do, and what a second run reports.

## Revert

Exact steps (or a script) to undo the module, including restoring from
`*.bak.<timestamp>` backups.

## Verification

Commands and expected results that prove the module worked (including a
`--dry-run` run that reports "Nothing to change" after applying).
