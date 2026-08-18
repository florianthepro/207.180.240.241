# Gitea nativ auf Windows Server (127.0.0.1:9200)

Selbst-gehosteter Git-Server als **nativer Windows-Dienst** — ohne Docker, ohne
WSL2, ohne Virtualisierung. Gedacht als Ersatz für die GitLab-in-Docker-Idee,
die auf diesem KVM-VPS an fehlender *nested virtualization* scheitert
(`SLAT=False`, `hasNoVirtualization=true`).

Gitea kann im Wesentlichen dasselbe wie GitLab für Self-Hosting: Repos, Issues,
**Pull/Merge Requests**, Wiki, Web-UI, Orgs/Teams, Webhooks, Container-/Package-
Registry und CI (**Gitea Actions**, GitHub-Actions-kompatibel).

## Installation

**Nur eine Datei nötig:** `gitea-setup.bat`. Der PowerShell-Teil ist darin
eingebettet (die Bat entpackt ihn beim Start selbst in eine Temp-Datei und
führt ihn aus). Einfach doppelklicken oder als Administrator starten — sie
fragt bei Bedarf UAC ab:

```bat
.\gitea-setup.bat
```

Das Skript:

1. installiert bei Bedarf **Git for Windows** (via winget),
2. lädt die **neueste stabile Gitea-Version** und prüft die **SHA256-Summe**,
3. schreibt eine **gehärtete** `C:\gitea\custom\conf\app.ini`,
4. härtet die **Datei-ACLs** (nur SYSTEM / Administratoren / Dienstkonto),
5. legt einen **Admin mit Zufallspasswort** an (wird einmalig angezeigt),
6. registriert den Dienst **Gitea** (Autostart + Auto-Restart) unter dem
   niedrig-privilegierten Konto **LocalService**,
7. blockt eingehend TCP 9200 in der Firewall (Defense-in-Depth),
8. startet den Dienst und macht einen Health-Check.

### Optionen

Oben in der `gitea-setup.bat` im Block `Konfiguration` anpassen (`set "..."`):

| Variable | Zweck | Default |
|---|---|---|
| `GITEA_DOMAIN` | Betrieb hinter Apache/HTTPS (setzt ROOT_URL + Secure-Cookies) | leer = nur lokal |
| `GITEA_VERSION` | feste Gitea-Version statt „neueste" | leer = auto |
| `GITEA_PORT` | HTTP-Port (nur Loopback) | `9200` |
| `GITEA_DIR` | Datenverzeichnis (ohne Leerzeichen) | `C:\gitea` |
| `GITEA_ADMIN` / `GITEA_EMAIL` | Admin-Benutzer / -E-Mail | `gitadmin` / `admin@localhost` |
| `GITEA_FORCE` | `1` = `gitea.exe` neu laden (Upgrade) + Migration | `0` |

## Warum das „stabil & nicht unsicher" ist

- **Nur lokal:** bindet an `127.0.0.1:9200` → von außen nicht erreichbar;
  zusätzlich Firewall-Block eingehend.
- **Niedrige Rechte:** Dienst läuft als `NT AUTHORITY\LocalService`, nicht als
  SYSTEM/Admin.
- **Restriktive ACLs:** `C:\gitea` nur für SYSTEM, Administratoren, Dienstkonto.
- **Keine offene Tür:** `DISABLE_REGISTRATION`, `REQUIRE_SIGNIN_VIEW`,
  Gravatar/Föderation aus, `OFFLINE_MODE` (keine externen Requests),
  Update-Checker aus.
- **Integrität:** Download wird per SHA256 gegen die offizielle Prüfsumme
  verifiziert.
- **Secrets:** `SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET` werden generiert.
- **Stabil:** Windows-Dienst mit Autostart und automatischem Neustart bei Absturz;
  SQLite im WAL-Modus.

## Zugriff

- **Lokal am Server:** im Browser `http://127.0.0.1:9200/`.
- **Remote:** entweder per RDP lokal öffnen, per SSH-Tunnel, **oder** über die
  optionale Apache-TLS-Config (`apache-gitea.conf`) hinter deiner Domain.
  Danach in der `app.ini` `ROOT_URL=https://…/` und `COOKIE_SECURE=true` setzen
  und `Restart-Service Gitea`.

## Verwaltung

```powershell
Get-Service Gitea
Restart-Service Gitea
Stop-Service Gitea

# Admin-Passwort zurücksetzen / weiteren Admin anlegen:
& C:\gitea\gitea.exe admin user change-password --username gitadmin --password 'NeuesStarkesPW!' --config C:\gitea\custom\conf\app.ini --work-path C:\gitea
& C:\gitea\gitea.exe admin user create --username u2 --email u2@localhost --admin --random-password --config C:\gitea\custom\conf\app.ini --work-path C:\gitea
```

Logs: `C:\gitea\log\` und Setup-Protokoll `C:\gitea\setup-log.txt`.

## Upgrade

In der `gitea-setup.bat` oben `set "GITEA_FORCE=1"` setzen und die Bat erneut
starten. Lädt die neueste `gitea.exe`, führt die Migration aus und startet den
Dienst neu. `app.ini` und Daten bleiben erhalten.

## Deinstallation

```powershell
Stop-Service Gitea
sc.exe delete Gitea
Remove-NetFirewallRule -DisplayName 'Gitea_9200_Block_Inbound'
Remove-Item -Recurse -Force C:\gitea   # löscht ALLE Daten/Repos!
```
