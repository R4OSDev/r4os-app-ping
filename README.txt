PING.R4X
========

PING.R4X sendet ICMP-Echo-Anfragen und nutzt R4NET fuer Namensaufloesung und
IPv4.

Projektstruktur seit 0.51.19:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, Imports und Contract.

Build:

    cd Code\System\Software\Ping
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\Ping\zig-out\PING.R4X

Contract:
- R4XStart-Entry: `ping_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`, `R4DESK`, `R4NET`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\PING.R4X`

