# Project Guidelines

## Git Workflow

Branches follow [Conventional Branches](https://conventional-branch.github.io/): `<type>/<short-description>`, where `<type>` matches Conventional Commits (`feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `perf`, `build`, `ci`, `style`, `revert`) and the description is kebab-case (e.g., `docs/improvements`, `feat/wraparound-monitoring`).

**One increment per PR, merge-then-branch.** Branch each unit of work off the current `main` and target `main`. Do **not** open a PR whose base is another feature branch — no stacked PRs. Before starting the next increment, merge the current PR and confirm the squash landed on `main`, then branch again from the updated `main`. (Enforced on the remote by the `PR Hygiene / base-is-main` required check, which fails any PR not based on `main`.) If a genuine blocker forces working ahead of an unmerged PR, say so and ask before stacking — and keep any such stack shallow (one deep), never a long chain.

## Project Structure

Two extensions, each in its own subdirectory:

| Directory       | Extension      | Schema         | Purpose            |
|-----------------|----------------|----------------|--------------------|
| `pgfc_observe/` | `pgfc_observe` | `pgfc_observe` | Observe and Orient |
| `pgfc_govern/`  | `pgfc_govern`  | `pgfc_govern`  | Decide and Act     |

Each subdirectory contains:

- `install.sql` — extension SQL
- `uninstall.sql` — `DROP SCHEMA ... CASCADE`
- `extension.control` — dbdev metadata (renamed to `pgfc_*.control` at publish time)
- `docker-compose.yml` — extension-specific volume mounts (merged with root via `-f`)
- `tests/` — pgTAP test files
- `README.md`

Other key files:

- `test.sh` — runs all tests on PG 15/16/17/18 via Docker
- `docker-compose.yml` — base test infrastructure (services, build, env, healthcheck, data volumes)

Docker Compose files are merged at invocation time: `test.sh` passes `-f docker-compose.yml -f pgfc_observe/docker-compose.yml -f pgfc_govern/docker-compose.yml`. Volume paths in extension compose files are relative to the project root (Docker Compose resolves all `-f` file paths relative to the first file's directory).

## Markdown Formatting

When writing or editing markdown files, follow these rules to pass linting:

- **Blank lines around blocks**: Always add a blank line before and after:
  - Lists (bulleted or numbered)
  - Headings
  - Fenced code blocks

- **List markers**: Use dashes (`-`) for unordered lists, not asterisks (`*`)

- **Indentation**: Use 2 spaces for nested list items

### Example

Wrong:

````markdown
**Some header text:**
- Item 1
- Item 2
#### Subheading
```code
example
```
````

Right:

````markdown
**Some header text:**

- Item 1
- Item 2

#### Subheading

```code
example
```
````

## Testing

We practice **Test-Driven Development (TDD)**: write the failing test first, run it and watch it fail for the right reason, then write the code that makes it pass. Add a regression test with every bug fix.

Run tests with:

```bash
./test.sh        # all supported versions (15 16 17 18)
./test.sh 17     # a single version (fast dev loop)
```

Tests are distributed across extension subdirectories:

- `pgfc_observe/tests/`
- `pgfc_govern/tests/`

## Code Style

- Follow existing patterns in the relevant `install.sql`
- Use the correct schema prefix: `pgfc_observe.` for observe, `pgfc_govern.` for govern
- Include COMMENT ON statements for new functions and tables
- Extensions read observe tables cross-schema  but never write to another extension's schema

## Schema Evolution

pgfc_observe uses **additive-only schema changes**:

- Add new nullable columns (never remove or rename existing ones)
- Historical data with NULL in new columns is correct ("not collected then")
- Re-running `pgfc_observe/install.sql` is the upgrade path (uses `CREATE OR REPLACE` / `IF NOT EXISTS`)

**Why not JSONB + versioning?**

- Query performance matters during incident analysis
- Strong typing catches errors early
- Schema-as-documentation (`\d pgfc_observe.snapshots` shows what's collected)
- Underlying pg_stat_* views evolve slowly and additively
