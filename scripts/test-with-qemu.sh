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
print_info "Creating bootc-image-builder configuration..."
cat > ${OUTPUT_DIR}/config.toml <<EOF
[[customizations.user]]
name = "bootc-user"
password = "\$6\$rounds=4096\$saltsaltlettuce\$YwMRfMLRv62PbqPBqGI2LMFoM4LFwZ3hd4W5lZb9A9A3xJ4I.E/u4F3B8j1jq3YJJdgcKlkPq5Vz1vFW0Q1Q21"
# Password is: bootc
groups = ["wheel"]
EOF

print_success "Configuration created"

# Check if bootc-image-builder container exists
print_info "Building QEMU disk image with bootc-image-builder..."
print_info "This may take several minutes..."

# Use bootc-image-builder to create a QEMU qcow2 image
sudo podman run --rm -it \
    --privileged \
    --pull=newer \
    -v ${OUTPUT_DIR}:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    registry.redhat.io/rhel9/bootc-image-builder:latest \
    --type qcow2 \
    --local \
    ${IMAGE_NAME}

if [ ! -f "${OUTPUT_DIR}/qcow2/disk.qcow2" ]; then
    print_error "Failed to create disk image"
    exit 1
fi

# Move the disk image to expected location
mv ${OUTPUT_DIR}/qcow2/disk.qcow2 ${DISK_IMAGE}
rm -rf ${OUTPUT_DIR}/qcow2

print_success "Disk image created: ${DISK_IMAGE}"

# Get disk image size
DISK_SIZE=$(du -h ${DISK_IMAGE} | cut -f1)
print_info "Disk image size: ${DISK_SIZE}"

# Create a startup script
cat > ${OUTPUT_DIR}/start-vm.sh <<EOF
#!/bin/bash
# Start the QEMU VM

echo "Starting QEMU VM..."
echo "SSH: ssh -p ${SSH_PORT} bootc-user@localhost (password: bootc)"
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
    -drive file=${DISK_IMAGE},if=virtio,format=qcow2 \\
    -net nic,model=virtio \\
    -net user,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${HTTP_PORT}-:8080 \\
    -nographic \\
    -serial mon:stdio
EOF

chmod +x ${OUTPUT_DIR}/start-vm.sh

print_success "VM startup script created: ${OUTPUT_DIR}/start-vm.sh"

print_header "Build Complete!"

echo ""
echo "Disk image created successfully!"
echo ""
echo "To start the VM:"
echo "  ${OUTPUT_DIR}/start-vm.sh"
echo ""
echo "Or manually with:"
echo "  qemu-system-x86_64 \\"
echo "    -m 4096 \\"
echo "    -cpu host \\"
echo "    -enable-kvm \\"
echo "    -smp 2 \\"
echo "    -drive file=${DISK_IMAGE},if=virtio,format=qcow2 \\"
echo "    -net nic,model=virtio \\"
echo "    -net user,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${HTTP_PORT}-:8080 \\"
echo "    -nographic"
echo ""
echo "Once booted, you can:"
echo "  • SSH: ssh -p ${SSH_PORT} bootc-user@localhost (password: bootc)"
if [ "${VERSION}" = "4.0" ]; then
    echo "  • Web: http://localhost:${HTTP_PORT}"
fi
echo "  • Check FIPS: ssh -p ${SSH_PORT} bootc-user@localhost 'cat /proc/sys/crypto/fips_enabled'"
if [ "${VERSION}" = "3.0" ] || [ "${VERSION}" = "4.0" ]; then
    echo "  • Run STIG scan: ssh -p ${SSH_PORT} bootc-user@localhost 'sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_stig /usr/share/xml/scap/ssg/content/ssg-cs10-ds.xml'"
fi
echo ""
echo "To stop the VM, press Ctrl+C or Ctrl+A then X"
echo ""

