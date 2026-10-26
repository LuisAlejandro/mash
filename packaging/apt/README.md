# Mash APT repository

Mash's Linux packages are delivered through a signed APT repository, so a
machine that installed `letsmash` once receives every later release through its
ordinary system update.

Public URL: **`https://apt.letsma.sh/`**

This repository is a **separate reprepro instance** from
[`apt.dockershelf.com`](https://apt.dockershelf.com/dockershelf/), which lives on
the same host. The two share nothing: different root, different signing key,
different nginx server block, different deploy user, different import binary.
Nothing here may modify the Dockershelf repository.

## Layout on the host

```text
/var/www/letsmash/
├── .gnupg/                        # reprepro Release signing key (letsmash-repo user)
├── conf/
│   └── distributions              # from reprepro-distributions
├── incoming/                      # rsync target for new .deb files
├── dists/                         # reprepro-generated indices
├── pool/                          # reprepro package pool
└── letsmash-apt-signing.pub       # exported public key (served to clients)
```

`/usr/local/bin/letsmash-import-incoming` is installed from
[`import-incoming.sh`](import-incoming.sh) and is what turns an rsync'd `.deb`
into a published package.

## One-time setup

From this repository, with passwordless `sudo` on the host:

```bash
scp packaging/apt/bootstrap-letsmash-repo.sh \
    packaging/apt/reprepro-distributions \
    packaging/apt/nginx-letsmash.conf \
    packaging/apt/import-incoming.sh luisalejandro@apt.letsma.sh:/tmp/
ssh luisalejandro@apt.letsma.sh
sudo mkdir -p /tmp/mash-apt && sudo mv /tmp/{bootstrap-letsmash-repo.sh,reprepro-distributions,nginx-letsmash.conf,import-incoming.sh} /tmp/mash-apt/
sudo /tmp/mash-apt/bootstrap-letsmash-repo.sh
```

Then issue the certificate. `certonly` is deliberate: the `--nginx` plugin would
otherwise edit whichever server block it considers the default, and the
Dockershelf block is certbot-managed:

```bash
sudo certbot certonly --nginx -d apt.letsma.sh
sudo /tmp/mash-apt/bootstrap-letsmash-repo.sh      # re-run: adds the TLS block
```

The bootstrap adds the publisher account to its own
`/etc/ssh/sshd_config.d/letsmash-apt.conf` include and reloads sshd. It does not
edit Dockershelf's SSH configuration. The publisher key is installed separately
with the `restrict` option (no forwarding, PTY, or agent socket); see GitHub
Actions publish credentials below.

## Publish flow

CI runs this after every artifact is built, verified and attached to the
draft release. It keeps the release private until both architectures are in the
signed repository and the Ubuntu runner verifies the APT source. A maintainer
runs the same script by hand:

```bash
make publish-apt VERSION=0.1.0
```

`packaging/apt/publish.sh` rsyncs both `.deb`s into one
`incoming/<publish-id>/` batch and SSHes `letsmash-import-incoming noble
<publish-id>`. The importer holds one lock across both architectures and exports
once, so a failure cannot expose an amd64-only release. Both architectures are
required; the script then verifies the public
InRelease signature and confirms each version/architecture appears in the
signed package indices.

### GitHub Actions publish credentials

The repository needs these settings for `publish-apt`:

- Secret `MASH_APT_DEPLOY_KEY`: private half of a dedicated Ed25519 key accepted
  for `letsmash-repo` (not the Dockershelf deploy key).
- Variable `MASH_APT_KNOWN_HOSTS`: one pinned `apt.letsma.sh ssh-ed25519 <key>`
  line, verified against the host fingerprint before it was stored.
- Variables `MASH_APT_HOST=apt.letsma.sh` and `MASH_APT_USER=letsmash-repo`.

The authorized key is prefixed with `restrict`: CI can run the upload/import
commands, but cannot request forwarding, a PTY, or an agent socket. Rotate it
by installing the new restricted public key on `letsmash-repo`, replacing the
GitHub secret, testing connectivity, then removing the old authorized-key line.

## Client apt source

The `letsmash` package installs this itself (see `packaging/linux/postinst`). To
subscribe by hand:

```text
Types: deb
URIs: https://apt.letsma.sh
Suites: noble
Components: main
Signed-By: /usr/share/keyrings/letsmash-archive-keyring.gpg
```

The suite is named for the Ubuntu release the packages were built against, not
`stable`: `packaging/build-linux.sh` derives `Depends` from the build machine's
libraries, so a package built on a later Ubuntu is a different artifact and
belongs in its own suite.

## Why this is not the Dockershelf repository

| Concern | Dockershelf | Mash |
| --- | --- | --- |
| Root | `/var/www/debian` | `/var/www/letsmash` |
| Suite | `trixie`, `unstable` | `noble` |
| Signing key | Dockershelf key | Mash key, generated separately |
| nginx site | `dockershelf-apt` | `letsmash-apt` |
| Import binary | `dockershelf-import-incoming` | `letsmash-import-incoming` |
| Deploy user | `deploy` | `letsmash-repo` |

`import-incoming.sh` is forked from Dockershelf's rather than shared, because
that script skips any `.deb` whose version does not embed `+<codename>` — a
Dockershelf naming convention Mash's plain `0.1.0` does not follow.
