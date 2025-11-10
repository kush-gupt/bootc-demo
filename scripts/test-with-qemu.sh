#!/bin/bash
# Test bootc images locally with QEMU
# This script builds bootc images and boots them in QEMU for testing

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "${PROJECT_ROOT}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DEFAULT_VERSIONS=("1.0" "2.0" "3.0" "4.0")
SSH_PORT_BASE=${SSH_PORT:-2222}
HTTP_PORT_BASE=${HTTP_PORT:-8080}
OUTPUT_ROOT="${PROJECT_ROOT}/test-output"

# Helper functions
print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}→ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

is_supported_version() {
    local candidate="$1"
    for known in "${DEFAULT_VERSIONS[@]}"; do
        if [ "$candidate" = "$known" ]; then
            return 0
        fi
    done
    return 1
}

ensure_root_image() {
    local image="$1"
    if sudo podman image exists "${image}" >/dev/null 2>&1; then
        return 0
    fi

    print_info "Transferring ${image} to root podman storage..."
    podman save "${image}" | sudo podman load >/dev/null
    print_success "Image ${image} transferred to root context"
}

# Configuration
declare -a VERSIONS=()
if [ "$#" -eq 0 ]; then
    VERSIONS=("${DEFAULT_VERSIONS[@]}")
elif [ "$1" = "all" ]; then
    VERSIONS=("${DEFAULT_VERSIONS[@]}")
else
    VERSIONS=("$@")
fi

declare -a NORMALIZED=()
for version in "${VERSIONS[@]}"; do
    if ! is_supported_version "$version"; then
        print_error "Unsupported version: ${version}"
        echo "Supported versions: ${DEFAULT_VERSIONS[*]}"
        exit 1
    fi

    already_present="false"
    for existing in "${NORMALIZED[@]}"; do
        if [ "$existing" = "$version" ]; then
            already_present="true"
            break
        fi
    done

    if [ "$already_present" = "false" ]; then
        NORMALIZED+=("$version")
    fi
done
VERSIONS=("${NORMALIZED[@]}")

print_header "Bootc Image Testing with QEMU"
print_info "Versions to test: ${VERSIONS[*]}"

# Check prerequisites
print_info "Checking prerequisites..."

if ! command -v podman &> /dev/null; then
    print_error "Podman is not installed. Please install podman first."
    exit 1
fi

if ! command -v qemu-system-x86_64 &> /dev/null; then
    print_error "QEMU is not installed"
    echo "Please install QEMU first:"
    echo "  sudo dnf install -y qemu-kvm qemu-img"
    exit 1
fi

print_success "Prerequisites checked"

SSH_KEY_CONFIG=""
SSH_KEY_LABEL=""
SSH_MESSAGE='echo "     (password: bootc)"'

for candidate in "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_rsa_bootc.pub"; do
    if [ -z "$SSH_KEY_CONFIG" ] && [ -f "$candidate" ]; then
        key_contents=$(tr -d '\n' < "$candidate")
        SSH_KEY_LABEL="RSA"
        SSH_KEY_CONFIG="key = \"${key_contents}\""
    fi
done

if [ -z "$SSH_KEY_CONFIG" ]; then
    for candidate in "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_ecdsa_bootc.pub"; do
        if [ -z "$SSH_KEY_CONFIG" ] && [ -f "$candidate" ]; then
            key_contents=$(tr -d '\n' < "$candidate")
            SSH_KEY_LABEL="ECDSA"
            SSH_KEY_CONFIG="key = \"${key_contents}\""
        fi
    done
fi

if [ -z "$SSH_KEY_CONFIG" ]; then
    for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ed25519_bootc.pub"; do
        if [ -z "$SSH_KEY_CONFIG" ] && [ -f "$candidate" ]; then
            key_contents=$(tr -d '\n' < "$candidate")
            SSH_KEY_LABEL="Ed25519"
            SSH_KEY_CONFIG="key = \"${key_contents}\""
        fi
    done
fi

if [ -n "$SSH_KEY_CONFIG" ]; then
    print_info "SSH key detected (${SSH_KEY_LABEL}) - enabling passwordless SSH access"
    SSH_MESSAGE="echo \"     (Using SSH key: ${SSH_KEY_LABEL})\""
else
    print_info "No SSH key detected; password authentication will be required"
fi

fips_variants_requested=0
for version in "${VERSIONS[@]}"; do
    case "$version" in
        2.0|3.0|4.0)
            fips_variants_requested=1
            break
            ;;
    esac
done

if [ "$fips_variants_requested" -eq 1 ] && [ "$SSH_KEY_LABEL" = "Ed25519" ]; then
    print_info "FIPS-enabled variants require RSA/ECDSA SSH keys; Ed25519 keys will be rejected by sshd"
fi

declare -a MISSING_VERSIONS=()
for version in "${VERSIONS[@]}"; do
    image="localhost/bootc-demo:${version}"
    if ! podman image exists "${image}" >/dev/null 2>&1; then
        MISSING_VERSIONS+=("$version")
    fi
done

if [ "${#MISSING_VERSIONS[@]}" -gt 0 ]; then
    print_info "Images missing locally: ${MISSING_VERSIONS[*]}"
    print_info "Building images with scripts/local-build.sh..."
    "${PROJECT_ROOT}/scripts/local-build.sh"
else
    print_success "All requested images found locally"
fi

mkdir -p "${OUTPUT_ROOT}"

declare -a SUMMARY_LINES=()
declare -a SSH_PORT_LIST=()
declare -a HTTP_PORT_LIST=()

has_web=0
has_fips=0
has_stig=0

for idx in "${!VERSIONS[@]}"; do
    version="${VERSIONS[$idx]}"
    image="localhost/bootc-demo:${version}"
    version_dir="${OUTPUT_ROOT}/${version}"
    disk_image="${version_dir}/disk.qcow2"
    config_path="${version_dir}/config.toml"
    start_vm="${version_dir}/start-vm.sh"
    ssh_port=$((SSH_PORT_BASE + idx))
    http_port=$((HTTP_PORT_BASE + idx))

    mkdir -p "${version_dir}"

    print_header "Preparing ${image}"
    print_info "Ensuring image is available in root podman context..."
    ensure_root_image "${image}"

    print_info "Creating bootc-image-builder configuration..."
cat > "${config_path}" <<EOF
# Bootc-image-builder configuration
# Best practices: Use SSH keys for authentication, add user to wheel group for sudo

[[customizations.user]]
name = "bootc-user"
# Password hash generated with: openssl passwd -6 'Bootc!2025Demo#'
password = "\$6\$xIk16J.VloD/CVPJ\$PdRldheDZ87q9L7jDL.O3VHgNBgFi7sBTv5CsPYltKKUvIQaZjXZCJtD4ODPc6akUkslRD1XzISP11EMwGRQh/"
${SSH_KEY_CONFIG}
groups = ["wheel"]
EOF
    print_success "Configuration created at ${config_path}"

    sudo rm -rf "${version_dir}/qcow2"
    sudo rm -f "${disk_image}"

    print_info "Building QEMU disk image with bootc-image-builder..."
    print_info "This may take several minutes..."
    sudo podman run --rm -it \
        --privileged \
        --pull=newer \
        --security-opt label=type:unconfined_t \
        -v "${version_dir}:/output" \
        -v "${config_path}:/config.toml:ro" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        ghcr.io/osbuild/bootc-image-builder:latest \
        --type qcow2 \
        --config /config.toml \
        "${image}"

    if [ ! -f "${version_dir}/qcow2/disk.qcow2" ]; then
        print_error "Failed to create disk image for ${image}"
        exit 1
    fi

    sudo mv "${version_dir}/qcow2/disk.qcow2" "${disk_image}"
    sudo rm -rf "${version_dir}/qcow2"
    sudo chown "$(id -u)":"$(id -g)" "${disk_image}"

    print_success "Disk image created: ${disk_image}"

    disk_size=$(du -h "${disk_image}" | cut -f1)
    print_info "Disk image size: ${disk_size}"

    cat > "${start_vm}" <<EOF
#!/bin/bash
# Start the QEMU VM for ${image}

echo "Starting QEMU VM..."
echo "SSH: ssh -p ${ssh_port} bootc-user@localhost"
${SSH_MESSAGE}
if [ "${version}" = "4.0" ]; then
    echo "Web App: http://localhost:${http_port}"
fi
echo "Press Ctrl+C to stop the VM"
echo ""

qemu-system-x86_64 \
    -m 4096 \
    -cpu host \
    -enable-kvm \
    -smp 2 \
    -drive file=${disk_image},format=qcow2,if=virtio \
    -netdev user,id=net0,hostfwd=tcp::${ssh_port}-:22,hostfwd=tcp::${http_port}-:8080 \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -serial mon:stdio
EOF

    chmod +x "${start_vm}"

    print_success "VM startup script created:"
    print_success "  • ${start_vm}"

    summary="Version ${version}: ${start_vm} (SSH ${ssh_port}"
    if [ "${version}" = "4.0" ]; then
        summary="${summary}, HTTP ${http_port}"
    fi
    summary="${summary})"
    SUMMARY_LINES+=("${summary}")
    SSH_PORT_LIST+=("${ssh_port}")
    HTTP_PORT_LIST+=("${http_port}")

    case "${version}" in
        4.0)
            has_web=1
            has_fips=1
            has_stig=1
            ;;
        3.0)
            has_fips=1
            has_stig=1
            ;;
        2.0)
            has_fips=1
            ;;
    esac
done

print_header "Build Complete!"

echo ""
echo "Disk images created:"
for idx in "${!VERSIONS[@]}"; do
    version="${VERSIONS[$idx]}"
    echo "  • ${version}: ${OUTPUT_ROOT}/${version}/disk.qcow2"
done
echo ""
echo "To start a VM (virtio):"
for summary in "${SUMMARY_LINES[@]}"; do
    echo "  • ${summary}"
done
echo ""
echo "Once booted, connect using the SSH port listed above."
if [ -n "$SSH_KEY_LABEL" ]; then
    echo "  • Authentication uses your SSH key (${SSH_KEY_LABEL})"
else
    echo "  • Use password: bootc"
fi
if [ "${has_web}" -eq 1 ]; then
    echo ""
    echo "Web App:"
    for idx in "${!VERSIONS[@]}"; do
        if [ "${VERSIONS[$idx]}" = "4.0" ]; then
            echo "  • Version 4.0: http://localhost:${HTTP_PORT_LIST[$idx]}"
        fi
    done
fi
if [ "${has_fips}" -eq 1 ]; then
    echo ""
    echo "FIPS Mode verification:"
    for idx in "${!VERSIONS[@]}"; do
        version="${VERSIONS[$idx]}"
        case "${version}" in
            2.0|3.0|4.0)
                ssh_port="${SSH_PORT_LIST[$idx]}"
                echo "  • [${version}] ssh -p ${ssh_port} bootc-user@localhost 'cat /proc/sys/crypto/fips_enabled'"
                echo "    [${version}] ssh -p ${ssh_port} bootc-user@localhost 'update-crypto-policies --show'"
                ;;
        esac
    done
fi
if [ "${has_stig}" -eq 1 ]; then
    echo ""
    echo "STIG compliance scan:"
    for idx in "${!VERSIONS[@]}"; do
        version="${VERSIONS[$idx]}"
        case "${version}" in
            3.0|4.0)
                ssh_port="${SSH_PORT_LIST[$idx]}"
                echo "  • [${version}] ssh -p ${ssh_port} bootc-user@localhost \\\n      'sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_stig \\\n       /usr/share/xml/scap/ssg/content/ssg-cs10-ds.xml'"
                ;;
        esac
    done
fi
echo ""
echo "To stop a VM, press Ctrl+C or use the QEMU monitor (Ctrl+A then X)."
echo ""

