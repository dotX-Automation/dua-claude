---
name: dua-integration
description: Including one DUA unit inside another project with git submodules or subtrees, using the dua-submod and dua-subtree helpers, and the rules for when each is appropriate. Use when a project needs another unit as a dependency, when submodules are out of date or detached, or when a subtree must be pulled or pushed.
---

# Integrating units with git

A DUA unit becomes part of a larger project by living under its `src/`, with the full copy and history carried in the parent repository. Git does that, in one of two ways, and the choice matters.

These are host operations. Your git, credentials and SSH agent are on the host, so run them directly, not through `dua exec`.

**The default behavior is for the user to run git commands and operations**: you may suggest what to do and ask if they want you to do it, else you say and wait.

## Which one

**Submodule when the unit is under active development.** The unit stays a separate repository with its own history and branches, so changes made inside it can be committed and pushed upstream. The cost is bookkeeping: the parent records one commit of the submodule, and that reference is updated by hand.

**Subtree when the unit is a dependency you just consume.** Files and history merge into the parent, so a plain clone gets everything with no extra commands. The cost is that the parent's history grows and some git operations get slower. Almost never needed in practice, since units are all under development.

**The default behavior is to use submodules over subtrees.**

## Submodules

```bash
git submodule add <URL> src/my_unit
git submodule update --init --recursive
git submodule status --recursive
```

The project ships `dua-submod update` and `dua-submod status` as shorthands for the last two. They are shell functions defined inside the container, so on the host use the plain git commands above.

Before changing anything inside a submodule, check which commit it is on. A submodule is usually in detached HEAD, and committing there produces work that the parent cannot reference and that is easy to lose. Check out a branch first.

After committing inside a submodule, the parent must record the new reference: `git add src/my_unit` in the parent, then commit there too. Say so explicitly; it is the step people forget.

## Subtrees

The project provides `dua-subtree`, which wraps `git subtree` with the right flags. It is a shell function inside the container, so either call the underlying git commands on the host, matching its behaviour, or run it through `dua exec` and accept that the container's git credentials are the host's, since `~/.ssh` and `~/.gitconfig` are mounted.

The equivalents, all squashing as `dua-subtree` does:

```bash
git subtree add  --prefix=src/my_unit <remote> <branch> --squash
git subtree pull --prefix=src/my_unit <remote> <branch> --squash
git subtree push --prefix=src/my_unit <remote> <branch>
git rm -r src/my_unit                 # removal, then commit
```

Always use `--squash` for add and pull.

## Where the two collide

**A project with submodules, included as a subtree, loses its submodules.** They are managed outside the source tree, so they do not come along. The subtree's `.gitmodules` has to be copied to the parent's root with its paths adjusted before submodule commands work. If units need to nest more than one level deep, use submodules throughout.

**A project with subtrees, included as a submodule, works normally**, since the subtree's history is already part of the unit's history.

All reasons to keep the submodules-only default behavior standing.

## Afterwards

Placing a unit under `src/` makes its code visible to colcon, but not to the container's image. If the unit needs build steps of its own, it must also be integrated into the target's Dockerfile, which is the `dua-targets` skill, and that means a rebuild.

So the full sequence for adding a dependency is: bring the code in with git, integrate the unit into the target if it needs build steps, ask the user to rebuild if it did, then `dua build`.
