# releases/

Built installers land here (`./package.sh`). They are **not** committed.

Publish with:

```bash
./package.sh --publish
```

That tags `vX.Y.Z`, creates a [GitHub Release](https://github.com/JosephAHK/better-mac-taskbar/releases), and uploads the `.pkg` + `.dmg`.
