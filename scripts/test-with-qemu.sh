#!/bin/bash
# Test bootc images locally with QEMU
# This script builds a bootc image and boots it in QEMU for testing

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Configuration
VERSION="${1:-4.0}"
IMAGE_NAME="localhost/bootc-demo:${VERSION}"
OUTPUT_DIR="./test-output"
DISK_IMAGE="${OUTPUT_DIR}/disk.qcow2"
SSH_PORT="${SSH_PORT:-2222}"
HTTP_PORT="${HTTP_PORT:-8080}"

print_header "Bootc Image Testing with QEMU"

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

# Check if image exists locally
print_info "Checking if image ${IMAGE_NAME} exists locally..."
if ! podman image exists ${IMAGE_NAME}; then
    print_info "Image not found locally. Building images..."
    ./scripts/local-build.sh
else
    print_success "Image ${IMAGE_NAME} found"
fi

# Create output directory
mkdir -p ${OUTPUT_DIR}

# Create bootc-image-builder config
# Following best practices for credential management from Red Hat documentation
print_info "Creating bootc-image-builder configuration..."

# Check if SSH key exists for passwordless access
SSH_KEY_CONFIG=""
if [ -f "$HOME/.ssh/id_rsa.pub" ] || [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        SSH_KEY=$(cat "$HOME/.ssh/id_ed25519.pub")
    else
        SSH_KEY=$(cat "$HOME/.ssh/id_rsa.pub")
    fi
    SSH_KEY_CONFIG="key = \"${SSH_KEY}\""
    print_info "SSH key found - enabling passwordless SSH access"
fi

cat > ${OUTPUT_DIR}/config.toml <<EOF
# Bootc-image-builder configuration
# Best practices: Use SSH keys for authentication, add user to wheel group for sudo

[[customizations.user]]
name = "bootc-user"
# Password hash generated with: openssl passwd -6 -salt saltsaltlettuce bootc
password = "\$6\$rounds=4096\$saltsaltlettuce\$YwMRfMLRv62PbqPBqGI2LMFoM4LFwZ3hd4W5lZb9A9A3xJ4I.E/u4F3B8j1jq3YJJdgcKlkPq5Vz1vFW0Q1Q21"
${SSH_KEY_CONFIG}
groups = ["wheel"]
EOF

print_success "Configuration created"
if [ -n "$SSH_KEY_CONFIG" ]; then
    print_success "SSH key configured for passwordless access"
fi

# Transfer image to root podman context if needed
print_info "Ensuring image is available in root podman context..."
if ! sudo podman image exists ${IMAGE_NAME}; then
    print_info "Transferring image from user to root podman storage..."
    podman save ${IMAGE_NAME} | sudo podman load
    print_success "Image transferred"
else
    print_success "Image already available in root context"
fi

# Check if bootc-image-builder container exists
print_info "Building QEMU disk image with bootc-image-builder..."
print_info "This may take several minutes..."

# Use bootc-image-builder to create a QEMU qcow2 image
sudo podman run --rm -it \
    --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ${OUTPUT_DIR}:/output \
    -v ${OUTPUT_DIR}/config.toml:/config.toml:ro \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    ghcr.io/osbuild/bootc-image-builder:latest \
    --type qcow2 \
    --config /config.toml \
    ${IMAGE_NAME}

if [ ! -f "${OUTPUT_DIR}/qcow2/disk.qcow2" ]; then
    print_error "Failed to create disk image"
    exit 1
fi

# Move the disk image to expected location (files are owned by root)
sudo mv ${OUTPUT_DIR}/qcow2/disk.qcow2 ${DISK_IMAGE}
sudo rm -rf ${OUTPUT_DIR}/qcow2

# Change ownership to current user
sudo chown $(id -u):$(id -g) ${DISK_IMAGE}

print_success "Disk image created: ${DISK_IMAGE}"

# Get disk image size
DISK_SIZE=$(du -h ${DISK_IMAGE} | cut -f1)
print_info "Disk image size: ${DISK_SIZE}"

# Create a startup script with IDE fallback option
cat > ${OUTPUT_DIR}/start-vm.sh <<EOF
#!/bin/bash
# Start the QEMU VM

echo "Starting QEMU VM..."
echo "SSH: ssh -p ${SSH_PORT} bootc-user@localhost"
$(if [ -n "$SSH_KEY_CONFIG" ]; then
    echo "echo \"     (Using SSH key authentication)\""
else
    echo "echo \"     (password: bootc)\""
fi)
if [ "${VERSION}" = "4.0" ]; then
    echo "Web App: http://localhost:${HTTP_PORT}"
fi
echo "Press Ctrl+C to stop the VM"
echo ""

# Try virtio first (better performance), fall back to IDE if needed
qemu-system-x86_64 \\
    -m 4096 \\
    -cpu host \\
    -enable-kvm \\
    -smp 2 \\
    -drive file=${DISK_IMAGE},format=qcow2,if=virtio \\
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${HTTP_PORT}-:8080 \\
    -device virtio-net-pci,netdev=net0 \\
    -nographic \\
    -serial mon:stdio
EOF

# Create IDE fallback script
cat > ${OUTPUT_DIR}/start-vm-ide.sh <<EOF
#!/bin/bash
# Start the QEMU VM with IDE disk (fallback if virtio doesn't work)

echo "Starting QEMU VM with IDE disk..."
echo "SSH: ssh -p ${SSH_PORT} bootc-user@localhost"
$(if [ -n "$SSH_KEY_CONFIG" ]; then
    echo "echo \"     (Using SSH key authentication)\""
else
    echo "echo \"     (password: bootc)\""
fi)
if [ "${VERSION}" = "4.0" ]; then
    echo "Web App: http://localhost:${HTTP_PORT}"
fi
echo "Press Ctrl+C to stop the VM"
echo ""

qemu-system-x86_64 \\
    -m 4096 \\
    -cpu host \\
    -enable-kvm \\
    -smp 2 \\
    -drive file=${DISK_IMAGE},format=qcow2,if=ide \\
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${HTTP_PORT}-:8080 \\
    -device e1000,netdev=net0 \\
    -nographic \\
    -serial mon:stdio
EOF

chmod +x ${OUTPUT_DIR}/start-vm.sh
chmod +x ${OUTPUT_DIR}/start-vm-ide.sh

print_success "VM startup scripts created:"
print_success "  • ${OUTPUT_DIR}/start-vm.sh (virtio - recommended)"
print_success "  • ${OUTPUT_DIR}/start-vm-ide.sh (IDE fallback)"

print_header "Build Complete!"

echo ""
echo "Disk image created successfully!"
echo ""
echo "To start the VM:"
echo "  ${OUTPUT_DIR}/start-vm.sh              # virtio (recommended)"
echo "  ${OUTPUT_DIR}/start-vm-ide.sh          # IDE fallback if virtio fails"
echo ""
echo "Or manually with:"
echo "  qemu-system-x86_64 \\"
echo "    -m 4096 \\"
echo "    -cpu host \\"
echo "    -enable-kvm \\"
echo "    -smp 2 \\"
echo "    -drive file=${DISK_IMAGE},format=qcow2,if=virtio \\"
echo "    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${HTTP_PORT}-:8080 \\"
echo "    -device virtio-net-pci,netdev=net0 \\"
echo "    -nographic"
echo ""
echo "Once booted, you can:"
if [ -n "$SSH_KEY_CONFIG" ]; then
    echo "  • SSH: ssh -p ${SSH_PORT} bootc-user@localhost (using SSH key)"
else
    echo "  • SSH: ssh -p ${SSH_PORT} bootc-user@localhost (password: bootc)"
fi
if [ "${VERSION}" = "4.0" ]; then
    echo "  • Web: http://localhost:${HTTP_PORT}"
fi
echo ""
if [ "${VERSION}" = "2.0" ] || [ "${VERSION}" = "3.0" ] || [ "${VERSION}" = "4.0" ]; then
    echo "FIPS Mode:"
    echo "  • Verify FIPS: ssh -p ${SSH_PORT} bootc-user@localhost 'cat /proc/sys/crypto/fips_enabled'"
    echo "    (should return 1)"
    echo "  • Check policy: ssh -p ${SSH_PORT} bootc-user@localhost 'update-crypto-policies --show'"
    echo "    (should return FIPS)"
    echo ""
fi
if [ "${VERSION}" = "3.0" ] || [ "${VERSION}" = "4.0" ]; then
    echo "STIG Compliance:"
    echo "  • Run STIG scan:"
    echo "    ssh -p ${SSH_PORT} bootc-user@localhost \\"
    echo "      'sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_stig \\"
    echo "       /usr/share/xml/scap/ssg/content/ssg-cs10-ds.xml'"
    echo ""
fi
echo "To stop the VM, press Ctrl+C or Ctrl+A then X"
echo ""

