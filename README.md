# RDPConnect

## Simple FreeRDP frontend: Linux (GTK), macOS (Swift) and Windows (Qt).

## macOS

```sh
make install       # build RDPConnect.app into ~/Applications
make sign          # re-sign with hardened runtime + secure timestamp
make notarize      # sign, notarize with Apple and staple the ticket
```

Builds are signed with your Developer ID Application identity if present, else Apple
Development, else ad-hoc. A team identity keeps keychain "Always Allow" and Accessibility
grants across rebuilds; ad-hoc builds ask again after every rebuild. `make notarize` needs a
Developer ID Application identity and a stored notarytool profile (once):

```sh
xcrun notarytool store-credentials RDPConnect --apple-id <apple-id> --team-id <team-id>
```

## Windows

A native Qt 6 Widgets app (`Qt/main.cpp`, also buildable on Linux with `make qt`) that uses
the Windows 11 style and follows the system light/dark mode. It launches the bundled `sdl-freerdp.exe`.

Cross-compiled on Linux (or WSL) in a container; nothing is installed on Windows:

```sh
make windows       # podman image with a MinGW UCRT cross compiler + MSYS2 Qt6/FreeRDP
make windows-run   # from WSL: start dist/RDPConnect/bin/rdpconnect.exe
```

`dist/RDPConnect` is self-contained (exe, DLLs, `sdl-freerdp.exe`, Qt plugins) and can be
copied anywhere on Windows. It can also be built natively in an [MSYS2](https://www.msys2.org)
UCRT64 shell with `pacman -S make mingw-w64-ucrt-x86_64-{gcc,pkgconf,qt6-base,freerdp}`
and `make dist` / `make install`.

Settings live in `%LOCALAPPDATA%\RDPConnect` and passwords in Windows Credential Manager
(`RDPConnect:<id>`).
