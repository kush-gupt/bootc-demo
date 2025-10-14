# CentOS Stream 10 Bootc Demo

A progressive bootable container image demonstration using CentOS Stream 10, showcasing the evolution from a vanilla base to a fully hardened system with FIPS compliance, DISA STIG hardening, and a modern web application.

## Overview

This project demonstrates the power and flexibility of bootable container images (bootc) by creating four progressively enhanced versions:

## 📚 Version Comparison

| Feature | v1.0 | v2.0 | v3.0 | v4.0 |
|---------|------|------|------|------|
| Base OS | ✅ | ✅ | ✅ | ✅ |
| FIPS Mode | ❌ | ✅ | ✅ | ✅ |
| DISA STIG | ❌ | ❌ | ✅ | ✅ |
| Web App | ❌ | ❌ | ❌ | ✅ |
| Multi-arch (AMD64/ARM64) | ✅ | ✅ | ✅ | ✅ |
| Single Layer (Squashed) | ✅ | ✅ | ✅ | ✅ |
| Use Case | Development | Compliance Required | High Security | Full Stack Demo |

Each version builds upon the previous one, demonstrating how bootable container images can be layered and customized for different security and operational requirements.

## Prerequisites

- Podman installed
- Access to CentOS Stream 10 bootc base image
- For local builds: Linux system with sufficient disk space
- For deployment: UEFI-capable system or VM

## Building Images

### Quick Start

Use the provided script to build all four versions for your native architecture:

```bash
./scripts/local-build.sh
```

This will build all images with tags:
- `localhost/bootc-demo:1.0`
- `localhost/bootc-demo:2.0`
- `localhost/bootc-demo:3.0`
- `localhost/bootc-demo:4.0`

### Multi-Architecture Build

To build for both AMD64 and ARM64 architectures:

```bash
BUILD_MULTIARCH=true ./scripts/local-build.sh
```

This creates multi-arch manifests that automatically select the correct image for your platform.

### Manual Build

Build specific versions manually (with squashing for single-layer images):

```bash
# Version 1.0 - Vanilla
cd containerfiles
podman build --squash -f Containerfile.1.0 -t somewhere/bootc-demo:1.0 .

# Version 2.0 - FIPS
podman build --squash -f Containerfile.2.0 -t somewhere/bootc-demo:2.0 .

# Version 3.0 - FIPS + STIG
podman build --squash -f Containerfile.3.0 -t somewhere/bootc-demo:3.0 .

# Version 4.0 - FIPS + STIG + WebApp
cd ..
podman build --squash -f containerfiles/Containerfile.4.0 -t somewhere/bootc-demo:4.0 .
```

## Testing the Images

You can test any version by running it as a regular container with systemd:

```bash
# Test version 4.0 with the web app
podman run -d --rm --name test-webapp \
    -p 8080:8080 \
    localhost/bootc-demo:4.0 \
    /sbin/init

# Access the web application
curl http://localhost:8080

# Or open in your browser:
# http://localhost:8080

# View logs
podman logs test-webapp

# Stop the container
podman stop test-webapp
```

### Test FIPS Mode

**Important**: When running as a container, FIPS mode requires the host system to have FIPS enabled, since containers share the host's kernel. The FIPS kernel arguments configured in the bootc image will take effect when the image is deployed to bare metal or a VM.

```bash
# Run version 2.0 or higher
podman run -it --rm localhost/bootc-demo:2.0 bash

# Inside the container:
cat /proc/sys/crypto/fips_enabled  # Shows 1 only if host has FIPS enabled
update-crypto-policies --show      # Should show: FIPS

# To test FIPS properly, deploy the bootc image to a real system
# where it will boot with its own kernel and FIPS will be fully enabled
```

### Test STIG Compliance

**Important**: Many STIG checks will show as "notapplicable" or "error" when running as a container because:
- Containers don't have their own kernel (kernel parameters won't apply)
- Some services can't start in container context
- Audit rules require kernel-level features

When deployed as a bootc image to a real system, significantly more STIG controls will pass.

```bash
# Run version 3.0 or higher
podman run -it --rm localhost/bootc-demo:3.0 bash

# Inside the container - run STIG evaluation
oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_stig \
    /usr/share/xml/scap/ssg/content/ssg-cs10-ds.xml

# Generate an HTML report
oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_stig \
    --report /tmp/stig-report.html \
    /usr/share/xml/scap/ssg/content/ssg-cs10-ds.xml
```

## 🚢 Deploying to Physical/Virtual Systems

### Option 1: Using bootc-image-builder

Convert the bootable container to a disk image:

```bash
# Create a config.json for user setup
cat > config.json <<EOF
{
  "blueprint": {
    "customizations": {
      "user": [
        {
          "name": "admin",
          "password": "your-hashed-password",
          "groups": ["wheel"]
        }
      ]
    }
  }
}
EOF

# Build a QCOW2 image
sudo podman run --rm -it --privileged \
    -v $(pwd)/config.json:/config.json:ro \
    -v $(pwd)/output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    registry.redhat.io/rhel9/bootc-image-builder:latest \
    --type qcow2 \
    --config /config.json \
    localhost/bootc-demo:4.0
```

### Option 2: Create Bootable ISO

Use the bootc-image-builder to create an installable ISO:

```bash
sudo podman run --rm -it --privileged \
    -v $(pwd)/config.json:/config.json:ro \
    -v $(pwd)/output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    registry.redhat.io/rhel9/bootc-image-builder:latest \
    --type iso \
    --config /config.json \
    localhost/bootc-demo:4.0
```

### Option 3: Direct Installation to Disk

On a target system with bootc installed:

```bash
# Install to a specific disk
sudo bootc install to-disk \
    --generic-image \
    --via loopback \
    /dev/sda \
    localhost/bootc-demo:4.0
```

## 🔄 Updating Deployed Systems

Once a system is deployed from a bootc image, it can be updated by pulling new versions:

```bash
# On the deployed system
sudo bootc update

# Or specify a different image/tag
sudo bootc switch ghcr.io/kush-gupt/bootc-demo:4.0
sudo bootc update --apply
```

The system uses a systemd timer (`bootc-fetch-apply-updates.timer`) to automatically check for and apply updates.

### API Endpoints:

```bash
# System status (JSON)
curl http://localhost:8080/api/status

# Health check
curl http://localhost:8080/api/health
```

### Accessing the Web App:

After deploying version 4.0, access the web interface at:
```
http://<system-ip>:8080
```



## 📖 References

- [CentOS Stream Bootc Documentation](https://docs.centos.org/en-US/stream/)
- [Bootc Project](https://github.com/containers/bootc)
- [RHEL Image Mode Documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/composing_installing_and_managing_rhel_for_edge_images/)
- [FIPS Mode Configuration](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/assembly_installing-the-system-in-fips-mode_security-hardening)
- [DISA STIG OpenSCAP](https://www.open-scap.org/security-policies/scap-security-guide/)
- [Example Bootc Demo by Rich!](https://github.com/rlucente-se-jboss/bootc-demo)

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

# This project is provided as-is for demonstration purposes.

---

**Made with ❤️ for the bootc community**

