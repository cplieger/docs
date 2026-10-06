# docs

These are guides for running the cplieger container images with Docker Compose, licensed under Apache-2.0. They work on any Docker host, and each guide comes with example files you can copy.

## What is here

- [Monitoring and alerts](docs/monitoring.md) sets up notifications from the apps' logs, then metrics and dashboards. Start here if an app's README says it ships alert rules or a dashboard.
- [Image tags, updates and verification](docs/images.md) explains which tag to run and how updates reach you. It also shows how to check an image's signature and software bill of materials.
- [Hardening a compose file](docs/hardening.md) shows the settings that limit what a container can do, and how to keep passwords in secret files.
- [Running an app behind a reverse proxy](docs/reverse-proxy.md) puts an app that answers over HTTP behind Caddy, nginx, Traefik or Nginx Proxy Manager, with HTTPS.
- [Adding a login on a reverse proxy](docs/proxy-login.md) puts a password on the proxy for marotte and web-terminal-kiro, which have no login of their own.

Each app's own README covers its settings, and its `docs/` pages cover what is specific to that app.

## Every example is tested

Each code block in a guide is a copy of a file under [`examples/`](examples/), or of a marked part of one. A check fails when the two differ, or when a block has no file. A workflow starts each example on a clean machine whenever an example changes, and checks that it does what its guide says. The checks include these:

- The monitoring stack sends a real alert to a test webhook.
- The hardened compose file starts healthy and reads its secret from a file.
- The image checks pass against published images.
- Each reverse proxy passes WebSockets, live updates, forwarded headers and a large upload.
- Each proxy login refuses a missing or wrong password, lets WebSockets and live updates through with the right login, and keeps the password from the app.

## Using the examples

Run `git clone https://github.com/cplieger/docs.git`, then copy the folder of the example you want. Two kinds of example are copied over another one. For the full monitoring stack, copy `examples/monitoring/minimal`, then add the files from `examples/monitoring/full`, as [its guide](docs/monitoring.md#the-full-stack-adds-dashboards-and-metrics) explains. For a proxy login, copy the proxy's folder, then the files from its folder under `examples/reverse-proxy/login`, as [Adding a login on a reverse proxy](docs/proxy-login.md) explains.

Change `app.example.com` to your own name, `you@example.com` to your own address, and every password and token to your own.

The examples pin each third-party image to an exact version, and the cplieger images to `latest`. For a server, change `latest` to the major version tag, as [Which tag to use](docs/images.md#which-tag-to-use) explains.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE).
