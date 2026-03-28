# zenbuser

Screenshot and upload tool for Linux. Takes a screenshot, uploads it to a Zendesk-based CDN, and copies the URL to your clipboard.

## Dependencies

- [flameshot](https://flameshot.org/) (or any other screenshot tool)
- `curl`
- `wl-copy` / `xclip` / `xsel` (clipboard)
- `notify-send` (notifications)
- `file` (MIME type validation)

## See it in action

![preview](preview.gif)

## Installation

```sh
cargo build --release
cp target/release/zenbuser ~/.local/bin/
```

## Configuration

Config lives at `~/.config/zenbuser/zenbuser.toml`. See the example config in the repo.

Bind `zenbuser` to a key in your compositor/WM and you're done.

## Disclaimer

This tool uploads files to the public attachment endpoints of third-party support platforms (Zendesk, etc.). These endpoints are intended for customer support tickets — not as a general-purpose file host.

**Abusing these endpoints may get your IP blacklisted, your uploads removed, or result in other action from the platform.** Don't spam them, don't upload anything illegal, and don't use this for anything that could cause problems for the service or its users.

You're responsible for how you use this. The author is not liable for bans, takedowns, or anything else that happens as a result.

## License

This is free and unencumbered software released into the public domain. See [UNLICENSE](UNLICENSE) for details.
