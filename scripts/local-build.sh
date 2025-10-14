#!/bin/bash
# Local build script for CentOS Bootc Demo
# Builds all 4 image versions sequentially with multi-arch support

set -e

# Configuration
REGISTRY="localhost"
IMAGE_NAME="bootc-demo"
DATE=$(date +%Y%m%d)

# Default to native architecture, or set PLATFORMS env var
PLATFORMS="${PLATFORMS:-$(uname -m)}"
BUILD_MULTIARCH="${BUILD_MULTIARCH:-false}"

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

if [ "$BUILD_MULTIARCH" = "true" ]; then
    print_info "Building for multiple architectures: amd64 and arm64"
    print_info "This requires QEMU emulation and will take longer"
    ARCHS="linux/amd64 linux/arm64"
else
    NATIVE_ARCH=$(uname -m)
    if [ "$NATIVE_ARCH" = "x86_64" ]; then
        PLATFORM="linux/amd64"
    elif [ "$NATIVE_ARCH" = "aarch64" ]; then
        PLATFORM="linux/arm64"
    else
        print_error "Unsupported architecture: $NATIVE_ARCH"
        exit 1
    fi
    print_info "Building for native architecture: $PLATFORM"
    ARCHS="$PLATFORM"
fi

# Function to build an image
build_image() {
    local version=$1
    local containerfile=$2
    local description=$3
    
    print_info "Building Image $version ($description)..."
    
    if [ "$BUILD_MULTIARCH" = "true" ]; then
        # Build for multiple architectures and create manifest
        for arch in $ARCHS; do
            arch_suffix=$(echo $arch | sed 's/linux\///')
            print_info "  Building for $arch_suffix..."
            podman build --squash --platform $arch \
                -f $containerfile \
                -t ${REGISTRY}/${IMAGE_NAME}:${version}-${arch_suffix} \
                -t ${REGISTRY}/${IMAGE_NAME}:${version}-${DATE}-${arch_suffix} \
                containerfiles/
        done
        
        # Create manifest
        print_info "  Creating multi-arch manifest..."
        podman manifest create ${REGISTRY}/${IMAGE_NAME}:${version} || \
            podman manifest rm ${REGISTRY}/${IMAGE_NAME}:${version} && \
            podman manifest create ${REGISTRY}/${IMAGE_NAME}:${version}
        
        for arch in $ARCHS; do
            arch_suffix=$(echo $arch | sed 's/linux\///')
            podman manifest add ${REGISTRY}/${IMAGE_NAME}:${version} \
                ${REGISTRY}/${IMAGE_NAME}:${version}-${arch_suffix}
        done
        
        # Create dated manifest
        podman manifest create ${REGISTRY}/${IMAGE_NAME}:${version}-${DATE} || \
            podman manifest rm ${REGISTRY}/${IMAGE_NAME}:${version}-${DATE} && \
            podman manifest create ${REGISTRY}/${IMAGE_NAME}:${version}-${DATE}
        
        for arch in $ARCHS; do
            arch_suffix=$(echo $arch | sed 's/linux\///')
            podman manifest add ${REGISTRY}/${IMAGE_NAME}:${version}-${DATE} \
                ${REGISTRY}/${IMAGE_NAME}:${version}-${DATE}-${arch_suffix}
        done
    else
        # Single architecture build
        podman build --squash --platform $PLATFORM \
            -f $containerfile \
            -t ${REGISTRY}/${IMAGE_NAME}:${version} \
            -t ${REGISTRY}/${IMAGE_NAME}:${version}-${DATE} \
            containerfiles/
    fi
    
    print_success "Image $version built successfully"
}

# Build version 1.0
build_image "1.0" "containerfiles/Containerfile.1.0" "Vanilla CentOS Stream 10"

# Build version 2.0
build_image "2.0" "containerfiles/Containerfile.2.0" "+ FIPS Mode"

# Build version 3.0
build_image "3.0" "containerfiles/Containerfile.3.0" "+ DISA STIG"

# Build version 4.0
print_info "Building Image 4.0 (+ Modern Web App)..."
if [ "$BUILD_MULTIARCH" = "true" ]; then
    for arch in $ARCHS; do
        arch_suffix=$(echo $arch | sed 's/linux\///')
        print_info "  Building for $arch_suffix..."
        podman build --squash --platform $arch \
            -f containerfiles/Containerfile.4.0 \
            -t ${REGISTRY}/${IMAGE_NAME}:4.0-${arch_suffix} \
            -t ${REGISTRY}/${IMAGE_NAME}:4.0-${DATE}-${arch_suffix} \
            -t ${REGISTRY}/${IMAGE_NAME}:latest-${arch_suffix} \
            .
    done
    
    # Create manifests
    print_info "  Creating multi-arch manifests..."
    for tag in "4.0" "4.0-${DATE}" "latest"; do
        podman manifest create ${REGISTRY}/${IMAGE_NAME}:${tag} 2>/dev/null || \
            podman manifest rm ${REGISTRY}/${IMAGE_NAME}:${tag} && \
            podman manifest create ${REGISTRY}/${IMAGE_NAME}:${tag}
        
        for arch in $ARCHS; do
            arch_suffix=$(echo $arch | sed 's/linux\///')
            podman manifest add ${REGISTRY}/${IMAGE_NAME}:${tag} \
                ${REGISTRY}/${IMAGE_NAME}:${tag}-${arch_suffix}
        done
    done
else
    podman build --squash --platform $PLATFORM \
        -f containerfiles/Containerfile.4.0 \
        -t ${REGISTRY}/${IMAGE_NAME}:4.0 \
        -t ${REGISTRY}/${IMAGE_NAME}:4.0-${DATE} \
        -t ${REGISTRY}/${IMAGE_NAME}:latest \
        .
fi
print_success "Image 4.0 built successfully"

print_header "Build Complete!"

echo ""
echo "All images have been built successfully:"
echo "  • ${IMAGE_NAME}:1.0 - Vanilla CentOS Stream 10"
echo "  • ${IMAGE_NAME}:2.0 - + FIPS Mode"
echo "  • ${IMAGE_NAME}:3.0 - + DISA STIG"
echo "  • ${IMAGE_NAME}:4.0 - + Modern Web App"
echo ""

if [ "$BUILD_MULTIARCH" = "true" ]; then
    echo "Multi-arch manifests created (amd64 + arm64)"
    echo ""
    echo "Inspect manifest:"
    echo "  podman manifest inspect ${REGISTRY}/${IMAGE_NAME}:4.0"
    echo ""
fi

echo "Image features:"
echo "  📦 Squashed to single layer for smaller size"
if [ "$BUILD_MULTIARCH" = "true" ]; then
    echo "  🏗️ Multi-architecture (amd64 + arm64)"
else
    echo "  🏗️ Native architecture ($PLATFORM)"
fi
echo ""
echo "To test the images:"
echo "  podman run -d --rm --name test-v4 -p 8080:8080 ${REGISTRY}/${IMAGE_NAME}:4.0 /sbin/init"
echo "  curl http://localhost:8080"
echo ""
echo "To stop the test container:"
echo "  podman stop test-v4"
echo ""
echo "To build for multiple architectures, run:"
echo "  BUILD_MULTIARCH=true ./scripts/local-build.sh"
echo ""
