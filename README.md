# Risky Bit
> Diploma 2026/27

This project was made as the practical part of the team's diploma.


## Description
RiskyBit is a software collection in Docker that aims to provide an environment to conduct hacking challenges for companies and schools. It features real systems and actual CVEs in a competitive environment.

## Requirements

The setup script checks for these and tells you what is missing.

### Linux

| Software | Purpose |
|---|---|
| [Docker Engine](https://docs.docker.com/engine/install/) | Runs the containers |
| Docker Compose v2 plugin (`docker compose`) | Manages the stack |
| `git` | Pulls updates and submodules |
| `gpg` (GnuPG) | Encrypts and decrypts the stored passwords |
| `openssl` | Generates the host key and passwords |
| `curl` | Checks for image updates |

You also need `root` or `sudo` rights (setup writes to `/etc`), and your user must be allowed to use Docker (`sudo usermod -aG docker $USER`, then log in again).

### Windows

| Software | Purpose |
|---|---|
| [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) | Runs the containers (includes Compose v2) |
| [Git for Windows](https://git-scm.com/download/win) | Pulls updates and submodules |
| [Gpg4win](https://www.gpg4win.org/) | Encrypts and decrypts the stored passwords |

You also need PowerShell 5.1 or newer (included in Windows 10 and 11), administrator rights (the script asks for them via a UAC prompt), and your user must be in the `docker-users` group.

Make sure Docker Desktop is running before you start.

## Installation
This main repository features a script to automatically set up the project for you. Run it, and remove it again once you're done.

<br>

Fetch the repository
```Bash
git clone https://github.com/DA-Risky-Bit/RiskyBit.git
cd RiskyBit
```

### Linux

Run the script for setup
```Bash
./riskybit.sh setup
```
Fill in the admin email, admin password and PostgreSQL password. Leave a password empty to auto-generate one.

<br>

Start the containers
```Bash
./riskybit.sh run
```

### Windows

Open PowerShell in the project folder and run the script for setup
```PowerShell
.\riskybit.ps1 setup
```
Fill in the admin email, admin password and PostgreSQL password. Leave a password empty to auto-generate one.

<br>

Start the containers
```PowerShell
.\riskybit.ps1 run
```

> [!NOTE]
> If PowerShell refuses to run the script, allow it for the current session only:
> ```PowerShell
> Set-ExecutionPolicy -Scope Process Bypass
> ```

> [!NOTE]
> We recommend using this tool, since it automatically saves and loads passwords into the env, so your passwords won't ever lie around in plain text.

## Usage

| Command | Description |
|---|---|
| `setup` | First-time setup: pulls the latest commits and images, creates the encryption key and asks for the admin credentials |
| `run` | Checks that the images are present and up to date, then starts all containers |
| `down` | Stops all containers (not deleted) |
| `status` | Shows each service's state, ports, CPU and memory usage |
| `remove` | **Permanently** deletes the project, its volumes and the encryption key (asks first) |

Option: `--dev` for developers. `setup` also updates the git submodules and builds the images locally, and `run` also verifies the submodules.

Use `./riskybit.sh <command>` on Linux and `.\riskybit.ps1 <command>` on Windows.

Once running, the frontends are available at:
- Admin: `admin.localhost`
- Chat: `chat.localhost`
- App: `app.localhost`

## License
This project is licensed under MIT, specifics in:
[License](LICENSE)

## Contact
**Main Contact:** [contact@riskybit.com](mailto:contact@riskybit.com)

Team:
- **Valerian Hobel** – @htl3r-2135 [valerian.hobel@htl.rennweg.at](mailto:valerian.hobel@htl.rennweg.at)
- **Christoph Neumayer** – @ItzVoxel  [christoph.neumayer@htl.rennweg.at](mailto:christoph.neumayer@htl.rennweg.at)
- **Gabriel Berger** – @htl3r-2129 [gabriel.berger@htl.rennweg.at](mailto:gabriel.berger@htl.rennweg.at)
- **Alexander Reiter** – @Sunnickel  [alexander.reiter@htl.rennweg.at](mailto:alexander.reiter@htl.rennweg.at)
