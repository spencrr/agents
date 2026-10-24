---
name: python-development
description: "Use when writing, reviewing, debugging, or testing Python code; managing dependencies in an existing uv project; or working with NumPy arrays, tensors, or dataframes in Python."
---

# Python development

Apply this guidance only to relevant Python work, alongside the repository's own instructions.

## Environment and dependencies
- Follow the repository's existing environment and dependency workflow; do not introduce uv into a project that uses another workflow unless requested.
- In uv-managed projects, run Python and Python tooling through `uv run`. Use `uv add` only for intentional dependency additions, preserving the repository's dependency groups and version constraints.
- Distinguish adding dependencies from restoring existing ones: use `uv sync` when synchronization is needed, rather than adding an already-declared package again. Do not install packages unnecessarily.
- Follow the repository's lockfile policy. Use `uv run --locked` for validation when dependency resolution must remain unchanged.

## Scientific and numerical code
- Use meaningful names such as `sample_weights`, `class_logits`, or `samples_by_id`. Do not require every loop variable or intermediate to encode all dimensions or literally mirror its collection's name.
- Make array axis order and important shape relationships explicit at interfaces, such as `(n_samples, n_features)`. Use appropriate type hints and runtime shape or domain checks where mistakes matter; names alone do not enforce shape.
- Document non-obvious units, coordinate systems, normalization, broadcasting assumptions, and numerical rationale. Use concise docstrings for contracts and comments for reasoning or scientific references that the code cannot convey.
