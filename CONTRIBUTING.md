# Contributing to docs

The [shared rules](https://github.com/cplieger/.github/blob/main/CONTRIBUTING.md) for commits, releases, synced files and checks apply here.

## Rules

- The code blocks in `docs/` are copies of files under `examples/`. Edit the file under `examples/`, then run `python3 scripts/snippets.py --write`. A block edited by hand, or a code block with no include marker, fails the Snippets check.
- A new or changed example lands with the test that boots it, a script under `tests/` and a job in `.github/workflows/examples.yaml`. An example no job boots ships untested, and nothing reports that.
- A test may add services or a test certificate through its own compose file under `tests/`, but never change a setting the guide shows. Otherwise the test proves a configuration no reader runs.
- Guides and examples name no real host, domain or home network address. Use `example.com` names, the documentation ranges `192.0.2.0/24` and `203.0.113.0/24` for hosts, and `172.30.0.0/24` for the examples' Docker network.

## Checks

`python3 scripts/snippets.py --check` runs anywhere and needs only Python. `python3 -m unittest discover -s scripts` tests that check itself.

`bash tests/<topic>/<case>.sh` needs Docker with Compose v2, `sudo`, network access, and free ports 80, 81, 443, 3000, 3100, 8080, 9090, 9093 and 9190. `bash tests/images/verify.sh` needs cosign, jq and a logged-in `gh` as well.

The Examples workflow runs these tests on pull requests that change `examples/`, `tests/` or the workflow. It is not a required check.
