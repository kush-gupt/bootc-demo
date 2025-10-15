#!/bin/bash
# Test bootc images with libvirt/KVM (recommended for Fedora)
# This script builds a bootc image and creates a VM using virt-install

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
VM_NAME="bootc-demo-v${VERSION}"
IMAGE_NAME="localhost/bootc-demo:${VERSION}"
OUTPUT_DIR="./test-output"
DISK_IMAGE="${OUTPUT_DIR}/disk.qcow2"

print_header "Bootc Image Testing with libvirt/KVM"

# Check prerequisites
print_info "Checking prerequisites..."

if ! command -v podman &> /dev/null; then
    print_error "Podman is not installed. Please install podman first."
    exit 1
fi

if ! command -v virt-install &> /dev/null; then
    print_error "virt-install is not installed"
    echo "Please install virtualization tools:"
    echo "  sudo dnf install @virtualization virt-install libvirt"
    exit 1
fi

print_success "Prerequisites checked"

# Check and start libvirtd
print_info "Checking libvirt daemon..."
if ! systemctl is-active --quiet libvirtd; then
    print_info "Starting libvirtd..."
    sudo systemctl start libvirtd
fi
print_success "libvirtd is running"

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
# Following Fedora best practices
sudo podman run --rm -it \
    --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ${OUTPUT_DIR}:/output \
    -v ${OUTPUT_DIR}/config.toml:/config.toml:ro \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    --config /config.toml \
    --local \
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

# Check if VM already exists and destroy it
if sudo virsh list --all | grep -q "${VM_NAME}"; then
    print_info "VM ${VM_NAME} already exists, removing it..."
    sudo virsh destroy ${VM_NAME} 2>/dev/null || true
    sudo virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true
fi

# Create and start the VM using virt-install
print_info "Creating VM with virt-install..."
print_info "VM Name: ${VM_NAME}"

sudo virt-install \
    --name ${VM_NAME} \
    --cpu host \
    --vcpus 2 \
    --memory 4096 \
    --import \
    --disk path=${DISK_IMAGE},format=qcow2 \
    --os-variant centos-stream10 \
    --network network=default \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole

print_success "VM created and started: ${VM_NAME}"

# Wait a moment for VM to start
sleep 3

# Get VM IP address
print_info "Waiting for VM to get IP address..."
for i in {1..30}; do
    VM_IP=$(sudo virsh domifaddr ${VM_NAME} 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1 || true)
    if [ -n "$VM_IP" ]; then
        break
    fi
    sleep 2
done

print_header "VM Setup Complete!"

echo ""
echo "VM Name: ${VM_NAME}"
if [ -n "$VM_IP" ]; then
    echo "VM IP: ${VM_IP}"
fi
echo ""
echo "To access the VM:"
echo "  • Console: sudo virsh console ${VM_NAME}"
echo "    (Press Ctrl+] to exit console)"
if [ -n "$VM_IP" ]; then
    if [ -n "$SSH_KEY_CONFIG" ]; then
        echo "  • SSH: ssh bootc-user@${VM_IP} (using SSH key)"
    else
        echo "  • SSH: ssh bootc-user@${VM_IP} (password: bootc)"
    fi
fi
echo ""
echo "VM Management:"
echo "  • Start VM: sudo virsh start ${VM_NAME}"
echo "  • Stop VM: sudo virsh shutdown ${VM_NAME}"
echo "  • Force stop: sudo virsh destroy ${VM_NAME}"
echo "  • Delete VM: sudo virsh undefine ${VM_NAME} --remove-all-storage"
echo "  • List VMs: sudo virsh list --all"
echo ""
if [ "${VERSION}" = "2.0" ] || [ "${VERSION}" = "3.0" ] || [ "${VERSION}" = "4.0" ]; then
    echo "FIPS Mode:"
    echo "  • Verify: ssh bootc-user@${VM_IP:-\$VM_IP} 'cat /proc/sys/crypto/fips_enabled'"
    echo "    (should return 1)"
    echo ""
fi
if [ "${VERSION}" = "4.0" ]; then
    echo "Web Application:"
    echo "  • Access: http://${VM_IP:-\$VM_IP}:8080"
    echo ""
fi

# Offer to connect to console
echo "Connect to VM console now? (y/n)"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    print_info "Connecting to console (Ctrl+] to exit)..."
    sudo virsh console ${VM_NAME}
fi

