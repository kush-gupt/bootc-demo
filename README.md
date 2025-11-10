# CentOS Stream 10 Bootc Demo

Delivers four progressively hardened bootable container images (bootc) on CentOS Stream 10—from a vanilla base all the way to a STIG-hardened web stack. Everything builds locally with Podman, validates under QEMU, and is ready to deploy onto bare metal or virtual infrastructure.

## Contents
- [Version Lineup](#version-lineup)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
  - [Build All Images](#build-all-images)
  - [Automated QEMU Validation](#automated-qemu-validation)
  - [Feature Checks per Version](#feature-checks-per-version)
- [Credentials & Ports](#credentials--ports)
- [Container Smoke Tests](#container-smoke-tests)
- [Advanced Builds](#advanced-builds)
- [Deploying Bootc Images](#deploying-bootc-images)
- [Updating Deployed Systems](#updating-deployed-systems)
- [API Endpoints](#api-endpoints)
- [References](#references)

## Version Lineup

| Feature / Use Case | v1.0 Base | v2.0 FIPS | v3.0 FIPS + STIG | v4.0 Web App |
|--------------------|:---------:|:---------:|:----------------:|:-----------:|
| CentOS Stream 10 base | ✅ | ✅ | ✅ | ✅ |
| FIPS mode | ❌ | ✅ | ✅ | ✅ |
| DISA STIG hardening | ❌ | ❌ | ✅ | ✅ |
| Flask web application | ❌ | ❌ | ❌ | ✅ |
| Default target | Dev sandbox | FIPS-required workloads | High-security workloads | Full-stack demo |

Each tag builds on the previous one, so you can see how compliance and application features layer onto a minimal base image.

## Prerequisites
- Fedora, RHEL, CentOS Stream, or another Linux host with Podman ≥ 5 and QEMU/KVM available
- ~40 GB free disk space for builds and QEMU artifacts
- Passwordless `sudo` *not* required, but you will be prompted during image → qcow2 conversion
- (Recommended) An RSA SSH key (`~/.ssh/id_rsa.pub` or `id_rsa_bootc.pub`) for logging into FIPS/STIG guests

## Quick Start

### Build All Images
```bash
./scripts/local-build.sh
```
This produces the local tags:
- `localhost/bootc-demo:1.0`
- `localhost/bootc-demo:2.0`
- `localhost/bootc-demo:3.0`
- `localhost/bootc-demo:4.0`

### Automated QEMU Validation
The helper script turns every image into a qcow2 disk, drops launch wrappers, and prints connection info.

```bash
./scripts/test-with-qemu.sh        # test all versions

./scripts/test-with-qemu.sh 3.0 4.0  # Or a subset
```
What it does:
1. Ensures the image exists locally (else build).
2. Copies it into the root Podman store (`sudo` prompt expected).
3. Uses `bootc-image-builder` to create `test-output/<version>/disk.qcow2`.
4. Writes `start-vm.sh` (virtio) and `start-vm-ide.sh` wrappers per version with unique port mappings (SSH starts at 2222, HTTP at 8080).
5. Shows a summary of artifacts and feature checks.

Launch a guest in a separate terminal:
```bash
./test-output/2.0/start-vm.sh   # boot the FIPS image (SSH on 2223)
```
The console stays attached to that terminal (`-nographic`); press `Ctrl+a`, then `x` to power off.

#### Clean up stale QEMU runs

If a previous VM didn’t exit cleanly, ports such as 222x/808x stay busy and the new VM can’t start. Free them up before relaunching:

```bash
# List any lingering QEMU processes
ps -ef | grep -i qemu

# Terminate them if needed
pkill -f qemu

# Double-check which process is holding forwarded ports
sudo ss -ltnp | grep ':222[0-9]\|:808[0-9]'
```

### Feature Checks per Version
| Version | SSH command | Extra verification |
|---------|-------------|--------------------|
| 1.0 | `ssh -p 2222 -i ~/.ssh/id_rsa_bootc bootc-user@localhost` | Basic system sanity (`cat /etc/os-release`) |
| 2.0 | `ssh -p 2223 -i ~/.ssh/id_rsa_bootc bootc-user@localhost` | `cat /proc/sys/crypto/fips_enabled` → `1` |
| 3.0 | `ssh -p 2224 -i ~/.ssh/id_rsa_bootc bootc-user@localhost` | `sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_stig ...` |
| 4.0 | `ssh -p 2225 -i ~/.ssh/id_rsa_bootc bootc-user@localhost` | Web app on `http://localhost:8083`, FIPS + STIG checks |

> **Tip:** If you only have an Ed25519 key, the STIG/FIPS images will reject it. Generate a dedicated RSA key for testing:
> ```bash
> ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_bootc
> ```
> The validation script prioritizes `id_rsa*`, then `id_ecdsa*`, and finally falls back to Ed25519.

## Credentials & Ports
| Item | Value |
|------|-------|
| Default user | `bootc-user` |
| Password | `Bootc!2025Demo#` (meets STIG complexity) |
| SSH ports | 1.0 → 2222, 2.0 → 2223, 3.0 → 2224, 4.0 → 2225 |
| HTTP port | Only v4.0 exposes HTTP (`8083`) |

Passwordless sudo is disabled by design; use the password above or supply your own via the config snippets in the scripts.

## Container Smoke Tests
Just want to sanity-check an image without QEMU? Run it as a regular container using PID 1 `/sbin/init`:

```bash
podman run -d --rm --name bootc-demo-v4 \
    -p 8080:8080 \
    localhost/bootc-demo:4.0 \
    /sbin/init

curl http://localhost:8080
podman logs bootc-demo-v4
podman stop bootc-demo-v4
```
Note that FIPS/STIG kernel-level checks only pass when the image boots its own kernel (VM/bare metal).

## Advanced Builds
- **Multi-architecture manifests:**
  ```bash
  BUILD_MULTIARCH=true ./scripts/local-build.sh
  ```
  Creates `linux/amd64` + `linux/arm64` builds and pushes into local manifests.
- **Manual builds:** each `containerfiles/Containerfile.*` can be built directly with Podman if you prefer fine-grained control (see previous README version for explicit commands).

## Deploying Bootc Images
Use `bootc-image-builder` or `bootc install` to move beyond local VMs.

### Create qcow2 or ISO artifacts
```bash
cat > config.json <<'EOF'
{
  "blueprint": {
    "customizations": {
      "user": [
        {
          "name": "admin",
          "password": "<hashed-password>",
          "groups": ["wheel"]
        }
      ]
    }
  }
}
EOF

sudo podman run --rm -it --privileged \
    -v $(pwd)/config.json:/config.json:ro \
    -v $(pwd)/output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    ghcr.io/osbuild/bootc-image-builder:latest \
    --type qcow2 \
    --config /config.json \
    localhost/bootc-demo:4.0
```
Switch `--type qcow2` to `--type iso` for an installer ISO instead.

### Direct disk install
```bash
sudo bootc install to-disk \
    --generic-image \
    --via loopback \
    /dev/sdX \
    localhost/bootc-demo:4.0
```
Replace `/dev/sdX` with your target disk.

## Updating Deployed Systems
Once installed, a bootc-based host tracks its upstream image:
```bash
sudo bootc update                    # apply latest commit of the current tag
sudo bootc switch <repo>:<tag>        # move to a different image/tag
sudo bootc update --apply             # stage + reboot in one go
```
A systemd timer (`bootc-fetch-apply-updates.timer`) handles scheduled updates.

## API Endpoints
Version 4.0 ships a simple Flask app with health endpoints:
```bash
curl http://localhost:8080/api/status
curl http://localhost:8080/api/health
```
When running inside QEMU, remember to hit the forwarded port (`8080`) from your host machine.

## References
- [CentOS Stream Bootc Docs](https://docs.centos.org/en-US/stream/)
- [bootc Project](https://github.com/containers/bootc)
- [RHEL Image Mode Documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/composing_installing_and_managing_rhel_for_edge_images/)
- [Security Hardening / FIPS Guide](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/assembly_installing-the-system-in-fips-mode_security-hardening)
- [DISA STIG content (OpenSCAP)](https://www.open-scap.org/security-policies/scap-security-guide/)
- [Original Rich Lucente Bootc Demo](https://github.com/rlucente-se-jboss/bootc-demo)

---

**Made with ❤️ for the bootc community**

