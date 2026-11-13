# Contributing

This repository is set up for agent-first development, but these rules apply equally to people and agents.

## Basic workflow

- Keep repository-level knowledge in versioned files, not only in chat history, verbal sync or ticket comments.
- If behavior changes, update the code, docs and tests together.

## Before opening a pull request

- Run `make check-docs`.
- If the change is visible to users, add a release note.
- Confirm that examples, scripts, docs and the current implementation match.

## Default review expectations

- Prefer small pull requests with a clear scope.
- State risks, migration impact and follow-up work explicitly.
- If the context is complex, link the relevant plan or spec directly instead of expecting reviewers to guess.
