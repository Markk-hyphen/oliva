@docs/oliva/agent-guide.md

# {{APP_NAME}}

The line above imports the operating guide of Oliva, the framework this app is
built on: how to run it, deploy it, keep it updated, and the rules for
configuration and secrets. If your agent does not follow imports, read
`docs/oliva/agent-guide.md` before anything else. That file belongs to Oliva
and is replaced on every sync: never edit it. What is specific to this app
goes here.

## What this app is

<!-- One paragraph: what it does and for whom. Replace this comment. -->

## Rules of this app

<!-- Conventions that are this app's own: domain language, naming, what must
     never be done. Delete this comment when you add the first one. -->

## Where things are

- `README.md`: the app, for people.
- `agent-commits.md`: this app's log of changes worth explaining (format in the guide).
- `docs/concepts.md`: this app's glossary. The framework's is `docs/oliva/concepts.md`.
- `agent-commands.md`: commands the user can type in the chat. It is Oliva's.
- `.oliva-app`: what this app is called and which Oliva it was born on.
