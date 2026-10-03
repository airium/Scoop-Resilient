# Scoop-Resilient

Two Scoop subcommands with failure isolation:

- `scoop upgrade` follows `scoop update` arguments and runs each app update in its
  own process, so one failure cannot terminate the remaining app updates.
- `scoop tidy` follows `scoop cleanup` arguments and handles each obsolete version
  and cache file separately, so one failed deletion cannot stop the cleanup batch.

Both commands run sequentially, retain diagnostics, and finish with a summary.
The [Scoop-Resilient repository](https://github.com/airium/Scoop-Resilient) provides
the `scoop-resilient` package, which installs both command shims and their shared
libraries.

## Upgrade

```powershell
scoop upgrade                  # Synchronize Scoop and buckets only
scoop upgrade git pwsh          # Update selected local apps
scoop upgrade -a                # Update all local apps
scoop upgrade '*'               # Same selection as -a
scoop upgrade -ag               # All local and global apps
scoop upgrade git -g            # Only the global installation of git
scoop upgrade git -fi           # Force update; do not install dependencies
```

The options match `update`:

| Option | Meaning |
| --- | --- |
| `-a`, `--all` | Update all local apps; include global apps when `-g` is supplied. |
| `-g`, `--global` | Select global scope for named apps. |
| `-f`, `--force` | Force the app update, including Scoop's version-pin behavior. |
| `-i`, `--independent` | Do not install dependencies automatically. |
| `-k`, `--no-cache` | Do not use the download cache. |
| `-s`, `--skip-hash-check` | Explicitly disable hash verification. |
| `-q`, `--quiet` | Pass quiet mode to each Scoop update. |

App requests synchronize Scoop and buckets when `last_update` is missing or at
least three hours old, matching Scoop 0.6.0's freshness check. Explicitly naming
`scoop` requests synchronization immediately. A synchronization failure is
reported while the command continues attempting app updates with the available
manifests; Scoop's own update preconditions still apply in each child process.

Held apps are skipped. Repair-marked apps are passed to Scoop so its own recovery
behavior applies. Dependencies and version resolution remain Scoop's responsibility.
Bucket/version-qualified installed-app names are normalized as Scoop's update
command does. Duplicate app/scope requests run once.

Compared with the previous implementation, **no arguments no longer update every
app**. Use `scoop upgrade -a` for that workflow. Global apps now require `-g`.

Hash verification is enabled unless `-s` is explicitly supplied. Scoop sometimes
returns zero despite printing an error; known manifest, architecture, and explicit
error diagnostics are reported as failures. Running apps are reported as skipped,
and already-current apps are reported as current. Classification of arbitrary
installer output is best effort; original diagnostics remain visible.

## Tidy

```powershell
scoop tidy git pwsh             # Remove old versions of selected local apps
scoop tidy -a                   # Remove old versions of all local apps
scoop tidy -ak                  # Also remove obsolete download cache
scoop tidy -agk                 # Include global apps
scoop tidy git -gk              # Clean only the global git installation
```

| Option | Meaning |
| --- | --- |
| `-a`, `--all` | Clean all local apps; include global apps with `-g`. |
| `-g`, `--global` | Select global scope for named apps. |
| `-k`, `--cache` | Remove obsolete cache files and leftover `*.download` files. |

Each app runs in an isolated cleanup worker. Workers load the installed Scoop
core's configured paths, but use dedicated cleanup logic instead of invoking
`scoop cleanup`. Each old version and cache file has its own error handler.

Cleanup preserves the `current` directory and the active version. It recognizes
both Scoop 0.6.0's prefixed metadata filenames and legacy filenames. In
`NO_JUNCTION` mode, it follows Scoop's installation-timestamp selection, requiring
readable, consistent metadata and an unambiguous current version. If the current
version cannot be established safely, the app is skipped with an explanation.

Directory junctions and symbolic links inside old versions are unlinked without
traversing their targets. Hard-linked persisted files are removed only from the
old version; persisted data remains. Manifest hooks and uninstallers are not run.
Held apps remain eligible for cleanup.

The cache is shared between local and global installations. `-k` retains the
complete cache files for both installations' current versions, even when only one
scope is selected. If the other installation's current version is uncertain, its
app cache is retained. Leftover `*.download` files are cleaned separately, as with
native `cleanup -k`, and failures are reported rather than silently ignored.

The tidy summary counts individual removed versions/cache files, failures,
skipped operations, and apps that were already clean. Locked files may remain;
the command reports them and continues rather than retrying indefinitely.

## Global apps and elevation

Without `-g`, neither command selects global apps, even in an administrator shell.
With `-g`, an already-elevated shell performs global operations directly.
Otherwise local operations finish first, and the command offers one UAC prompt
for the global batch. Every global app still gets its own child process.

Both commands support:

```powershell
scoop upgrade -ag --no-elevation-prompt
scoop tidy -agk --no-elevation-prompt
```

Use this option for scheduled tasks and CI. Noninteractive sessions also skip
global apps instead of waiting for input. Declining or canceling elevation leaves
global apps under `Skipped`; failure to start or complete an accepted elevated
batch is reported under `Failed`. Local permission errors do not trigger an
automatic administrator retry.

## Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | No attempted operation failed; current or skipped items may remain. |
| `1` | Invalid public arguments, synchronization failure, or at least one failed operation. |
| `2` | Scoop, installed-app discovery, or the installed cleanup core could not be located. |

Uncertain cleanup metadata, held/running apps, and declined/canceled elevation do
not themselves make the command fail. Explicitly requesting an uninstalled app
is a failure. Use `scoop upgrade --help` or `scoop tidy --help` for usage.

## Local installation

Keep the entry scripts and `lib` directory together. From this checkout:

```powershell
scoop shim add scoop-upgrade (Resolve-Path .\scoop-upgrade.ps1)
scoop shim add scoop-tidy (Resolve-Path .\scoop-tidy.ps1)
scoop upgrade -a
scoop tidy -ak
```

Remove the development shims with `scoop shim rm scoop-upgrade` and
`scoop shim rm scoop-tidy`.

## Bucket installation and publishing

After a release containing the bundle has been published:

```powershell
scoop bucket add scoop-resilient https://github.com/airium/Scoop-Resilient
scoop install scoop-resilient/scoop-resilient
```

The package supplies both commands. A tagged release containing the bundle must
be published before this installation route is usable.

Generate the bundle and matching manifest:

```powershell
./scripts/new-manifest.ps1 -Version 0.1.0 -License MIT
```

This creates `dist/scoop-resilient-0.1.0.zip` and `bucket/scoop-resilient.json`. The archive
contains both entry scripts, shared libraries, and this README. The manifest
hashes that exact archive and references the corresponding GitHub release asset.
Upload that same archive as `scoop-resilient-0.1.0.zip` to the `v0.1.0` release after
committing the source/manifest and pushing the tag. Regenerating an archive can
change its hash; regenerate the manifest too, or pass `-ArchivePath` to hash an
already-built archive. `dist` is ignored by Git.

`origin` points to `git@github.com:airium/Scoop-Resilient.git`, so the generator
derives `airium/Scoop-Resilient` automatically. Use `-Repository OWNER/Scoop-Resilient`
to build for another repository. Choose the license you
actually intend to grant and add its license text before publishing; `MIT` above
is an example. No release or remote is created by these scripts.

## Testing

```powershell
pwsh -NoProfile -File ./test/run.ps1
```

The suite checks upgrade argument parity, scopes, freshness, option forwarding,
failure classification, stderr handling, and elevation. Filesystem tests check
cleanup continuation within/across apps, current and persisted data preservation,
legacy/prefixed metadata, `NO_JUNCTION`, cache failures, shared cache retention,
and global cleanup. Release tests unpack the bundle and execute its entry points.

CI runs on Windows with Windows PowerShell 5.1 and PowerShell 7, including real
file-lock and junction cases and an actual Scoop 0.6.0 cached hash failure. The
cross-platform suite also runs with PowerShell
7 on Linux, using injected deletion failures where Windows locking differs.
