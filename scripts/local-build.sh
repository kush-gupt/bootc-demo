#!/bin/bash
# Local build script for CentOS Bootc Demo
# Builds all 4 image versions sequentially

set -e

# Configuration
REGISTRY="localhost"
IMAGE_NAME="bootc-demo"
DATE=$(date +%Y%m%d)

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

# Check if podman is installed
if ! command -v podman &> /dev/null; then
    print_error "Podman is not installed. Please install podman first."
    exit 1
fi

# Change to project root
cd "$(dirname "$0")/.."

print_header "CentOS Bootc Demo - Local Build Script"

# Build version 1.0
print_info "Building Image 1.0 (Vanilla CentOS Stream 10)..."
podman build -f containerfiles/Containerfile.1.0 \
    -t ${REGISTRY}/${IMAGE_NAME}:1.0 \
    -t ${REGISTRY}/${IMAGE_NAME}:1.0-${DATE} \
    containerfiles/
print_success "Image 1.0 built successfully"

# Build version 2.0
print_info "Building Image 2.0 (+ FIPS Mode)..."
podman build -f containerfiles/Containerfile.2.0 \
    -t ${REGISTRY}/${IMAGE_NAME}:2.0 \
    -t ${REGISTRY}/${IMAGE_NAME}:2.0-${DATE} \
    containerfiles/
print_success "Image 2.0 built successfully"

# Build version 3.0
print_info "Building Image 3.0 (+ DISA STIG)..."
podman build -f containerfiles/Containerfile.3.0 \
    -t ${REGISTRY}/${IMAGE_NAME}:3.0 \
    -t ${REGISTRY}/${IMAGE_NAME}:3.0-${DATE} \
    containerfiles/
print_success "Image 3.0 built successfully"

# Build version 4.0
print_info "Building Image 4.0 (+ Modern Web App)..."
podman build -f containerfiles/Containerfile.4.0 \
    -t ${REGISTRY}/${IMAGE_NAME}:4.0 \
    -t ${REGISTRY}/${IMAGE_NAME}:4.0-${DATE} \
    -t ${REGISTRY}/${IMAGE_NAME}:latest \
    containerfiles/
print_success "Image 4.0 built successfully"

print_header "Build Complete!"

echo ""
echo "All images have been built successfully:"
echo "  • ${IMAGE_NAME}:1.0 - Vanilla CentOS Stream 10"
echo "  • ${IMAGE_NAME}:2.0 - + FIPS Mode"
echo "  • ${IMAGE_NAME}:3.0 - + DISA STIG"
echo "  • ${IMAGE_NAME}:4.0 - + Modern Web App"
echo ""
echo "To test the images:"
echo "  podman run -d --rm --name test-v4 -p 8080:8080 ${REGISTRY}/${IMAGE_NAME}:4.0 /sbin/init"
echo "  curl http://localhost:8080"
echo ""
echo "To stop the test container:"
echo "  podman stop test-v4"
echo ""

