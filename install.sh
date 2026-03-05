#!/usr/bin/env bash
# Vex Language Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/vex-org/releases/main/install.sh | bash
#
# Environment variables:
#   VEX_VERSION   - Specific version to install (default: latest)
#   VEX_INSTALL   - Installation directory (default: /usr/local)
#   VEX_HOME      - Vex home directory (default: ~/.vex)

set -euo pipefail

REPO="vex-org/releases"
VEX_INSTALL="${VEX_INSTALL:-/usr/local}"
VEX_HOME="${VEX_HOME:-$HOME/.vex}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}info:${NC} $*"; }
ok()    { echo -e "${GREEN}  ok:${NC} $*"; }
warn()  { echo -e "${YELLOW}warn:${NC} $*"; }
err()   { echo -e "${RED}error:${NC} $*" >&2; }
fatal() { err "$@"; exit 1; }

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) fatal "Unsupported architecture: $arch" ;;
    esac
}

detect_os() {
    local os
    os="$(uname -s)"
    case "$os" in
        Linux)  echo "linux" ;;
        Darwin) echo "macos" ;;
        *) fatal "Unsupported OS: $os" ;;
    esac
}

get_latest_version() {
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    local version
    if command -v curl &>/dev/null; then
        version=$(curl -fsSL "$url" | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    elif command -v wget &>/dev/null; then
        version=$(wget -qO- "$url" | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    else
        fatal "curl or wget is required"
    fi

    if [ -z "$version" ]; then
        fatal "Could not determine latest version. Set VEX_VERSION manually."
    fi
    echo "$version"
}

download() {
    local url="$1" dest="$2"
    info "Downloading $url"
    if command -v curl &>/dev/null; then
        curl -fSL --progress-bar -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress -O "$dest" "$url"
    else
        fatal "curl or wget is required"
    fi
}

verify_checksum() {
    local archive="$1" checksum_file="$2"
    if command -v sha256sum &>/dev/null; then
        sha256sum -c "$checksum_file" --quiet
    elif command -v shasum &>/dev/null; then
        shasum -a 256 -c "$checksum_file" --quiet
    else
        warn "sha256sum not found, skipping checksum verification"
    fi
}

setup_shell_profile() {
    local bin_dir="$1"
    local profile_line="export PATH=\"${bin_dir}:\$PATH\""
    local vex_home_line="export VEX_HOME=\"${VEX_HOME}\""
    local marker="# Vex Language"

    # Determine shell profile
    local shell_profile=""
    case "${SHELL:-}" in
        */zsh)  shell_profile="$HOME/.zshrc" ;;
        */bash)
            if [ -f "$HOME/.bash_profile" ]; then
                shell_profile="$HOME/.bash_profile"
            else
                shell_profile="$HOME/.bashrc"
            fi
            ;;
        */fish) shell_profile="$HOME/.config/fish/config.fish" ;;
        *)      shell_profile="$HOME/.profile" ;;
    esac

    # Check if already configured
    if [ -n "$shell_profile" ] && [ -f "$shell_profile" ] && grep -q "Vex Language" "$shell_profile" 2>/dev/null; then
        return
    fi

    # Check if bin_dir is already in PATH
    case ":$PATH:" in
        *":${bin_dir}:"*) return ;;
    esac

    if [ -n "$shell_profile" ]; then
        echo "" >> "$shell_profile"
        echo "$marker" >> "$shell_profile"
        echo "$vex_home_line" >> "$shell_profile"
        echo "$profile_line" >> "$shell_profile"
        ok "Added Vex to ${shell_profile}"
        info "Run 'source ${shell_profile}' or open a new terminal."
    fi
}

main() {
    echo ""
    echo -e "${GREEN}  Vex Toolchain Installer${NC}"
    echo ""

    local os arch version
    os="$(detect_os)"
    arch="$(detect_arch)"

    if [ "$os" != "linux" ] && [ "$os" != "macos" ]; then
        fatal "This installer supports Linux and macOS only."
    fi

    if [ "$os" = "macos" ] && [ "$arch" != "aarch64" ]; then
        fatal "macOS x86_64 builds are not available. Only Apple Silicon (ARM64) is supported."
    fi

    version="${VEX_VERSION:-$(get_latest_version)}"

    # Map arch/os to release archive naming
    local pkg_arch="$arch"
    if [ "$os" = "macos" ]; then
        pkg_arch="arm64"
    fi

    info "Installing Vex ${version} for ${os}-${pkg_arch}"

    local archive_name="vex-${version}-${os}-${pkg_arch}.tar.gz"
    local base_url="https://github.com/${REPO}/releases/download/${version}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    # Download archive and checksum
    download "${base_url}/${archive_name}" "${tmp_dir}/${archive_name}"
    download "${base_url}/${archive_name}.sha256" "${tmp_dir}/${archive_name}.sha256"

    # Verify checksum
    cd "$tmp_dir"
    info "Verifying checksum..."
    verify_checksum "${archive_name}" "${archive_name}.sha256"
    ok "Checksum verified"

    # Extract
    info "Extracting..."
    tar xzf "${archive_name}"

    local pkg_dir
    pkg_dir="$(find . -maxdepth 1 -type d -name 'vex-*' | head -1)"
    if [ -z "$pkg_dir" ]; then
        fatal "Failed to find extracted directory"
    fi

    # Setup VEX_HOME (~/.vex) — everything goes here
    info "Setting up VEX_HOME at ${VEX_HOME}..."
    mkdir -p "${VEX_HOME}/bin" "${VEX_HOME}/lib/std" "${VEX_HOME}/lib/runtime" "${VEX_HOME}/deps" "${VEX_HOME}/cache"

    # Install all tool binaries into VEX_HOME/bin
    local installed_tools=""
    for bin in vex vex-lsp vex-formatter vex-doc vex-pm; do
        if [ -f "${pkg_dir}/bin/${bin}" ]; then
            cp "${pkg_dir}/bin/${bin}" "${VEX_HOME}/bin/${bin}"
            chmod +x "${VEX_HOME}/bin/${bin}"
            installed_tools="${installed_tools} ${bin}"
        fi
    done
    ok "Tools installed:${installed_tools}"

    # Install stdlib
    if [ -d "${pkg_dir}/lib/std" ]; then
        rm -rf "${VEX_HOME}/lib/std"
        cp -r "${pkg_dir}/lib/std" "${VEX_HOME}/lib/std"
        ok "Standard library → ${VEX_HOME}/lib/std"
    fi

    # Install runtime
    if [ -d "${pkg_dir}/lib/runtime" ]; then
        rm -rf "${VEX_HOME}/lib/runtime"
        cp -r "${pkg_dir}/lib/runtime" "${VEX_HOME}/lib/runtime"
        ok "Runtime → ${VEX_HOME}/lib/runtime"
    fi

    # Symlink main binary to /usr/local/bin for convenience (if writable)
    local system_bin="${VEX_INSTALL}/bin"
    if [ -w "$system_bin" ] 2>/dev/null; then
        ln -sf "${VEX_HOME}/bin/vex" "${system_bin}/vex"
        ok "Symlinked vex → ${system_bin}/vex"
    elif command -v sudo &>/dev/null; then
        sudo ln -sf "${VEX_HOME}/bin/vex" "${system_bin}/vex" 2>/dev/null && \
            ok "Symlinked vex → ${system_bin}/vex" || true
    fi

    # Write config
    cat > "${VEX_HOME}/config.json" << VEXCFG
{
  "version": "${version}",
  "vex_home": "${VEX_HOME}",
  "std_path": "${VEX_HOME}/lib/std",
  "runtime_path": "${VEX_HOME}/lib/runtime",
  "tools": [$(echo "$installed_tools" | sed 's/ /", "/g; s/^", "//; s/^/"/; s/$/"/' )]
}
VEXCFG
    ok "Config → ${VEX_HOME}/config.json"

    # Add VEX_HOME/bin to shell profile
    setup_shell_profile "${VEX_HOME}/bin"

    # Verify
    echo ""
    if "${VEX_HOME}/bin/vex" --version 2>/dev/null; then
        ok "Vex ${version} installed successfully!"
    else
        ok "Vex ${version} files installed."
    fi

    echo ""
    echo -e "${GREEN}  Installed to: ${VEX_HOME}${NC}"
    echo ""
    echo -e "  ${CYAN}bin/${NC}          vex, vex-lsp, vex-formatter, vex-doc"
    echo -e "  ${CYAN}lib/std/${NC}      Standard library"
    echo -e "  ${CYAN}lib/runtime/${NC}  Runtime libraries"
    echo -e "  ${CYAN}deps/${NC}         Package dependencies"
    echo -e "  ${CYAN}cache/${NC}        Build cache"
    echo ""
    echo -e "${GREEN}  Get started:${NC}"
    echo "    vex run hello.vx"
    echo ""
}

main "$@"
