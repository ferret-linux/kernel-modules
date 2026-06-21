#!/usr/bin/env bash
# ================================================================
#  kvmfr — kmod build script
#  Ported from HikariKnight's kvmfr-kmod.spec (looking-glass-kvmfr-akmod)
#  Source: module/ directory of gnif/LookingGlass (upstream Looking Glass)
# ================================================================

set -Eeuo pipefail

# ── Styling ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

say()  { printf "$@"; printf '\n'; }
info() { say "${CYAN}◈${NC}  $*"; }
ok()   { say "${GREEN}◆${NC}  $*"; }
warn() { say "${YELLOW}◇${NC}  $*"; }
fail() { say "${RED}⦻${NC}  $*" >&2; exit 1; }

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◈  kvmfr kmod build                   ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════╝${NC}"
say ""

# ── Paths ─────────────────────────────────────────────────────
BUILDROOT="/kernel-modules/rpmbuild"

# ── Upgrade system ────────────────────────────────────────────
info "Upgrading system packages..."
dnf upgrade -y
ok "System upgraded"

# ── Detect kernel version ─────────────────────────────────────
info "Detecting latest kernel version..."
KERNEL_VERSION="$(rpm -q kernel \
    --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' \
    | sort -V | tail -1)"
[[ -n "$KERNEL_VERSION" ]] || fail "Could not detect kernel version"
ok "Kernel version: ${KERNEL_VERSION}"

# ── Detect latest LookingGlass release ────────────────────────
info "Detecting latest LookingGlass release..."
LG_TAG="$(curl -fLsS \
    https://api.github.com/repos/gnif/LookingGlass/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)"
[[ -n "$LG_TAG" ]] || fail "Could not detect latest LookingGlass release"

# strip leading non-numeric chars for RPM version field (B7 -> 7)
LG_VERSION="$(echo "${LG_TAG}" | sed 's/^[A-Za-z]*//')"
ok "LookingGlass tag: ${LG_TAG} -> RPM version: ${LG_VERSION}"

# ── Install build dependencies ────────────────────────────────
info "Installing build dependencies..."
dnf install -y --setopt=install_weak_deps=False \
    kernel-devel-matched-"${KERNEL_VERSION}" \
    gcc \
    make \
    rpm-build \
    git \
    systemd-rpm-macros
ok "Build dependencies installed"

# ── Setup rpmbuild dirs ───────────────────────────────────────
info "Setting up rpmbuild directories..."
mkdir -p "${BUILDROOT}/BUILD" \
         "${BUILDROOT}/RPMS" \
         "${BUILDROOT}/SOURCES" \
         "${BUILDROOT}/SPECS" \
         "${BUILDROOT}/SRPMS"
ok "rpmbuild directories ready"

# ── Clone LookingGlass source at latest release tag ───────────
# Only the module/ subdirectory (the kvmfr driver) is needed.
info "Cloning LookingGlass ${LG_TAG}..."
git clone --depth=1 --branch "${LG_TAG}" \
    https://github.com/gnif/LookingGlass.git \
    "${BUILDROOT}/BUILD/LookingGlass-${LG_VERSION}"
ok "Source cloned"

# ── Create source tarball (module/ only) ──────────────────────
info "Creating source tarball..."
mv "${BUILDROOT}/BUILD/LookingGlass-${LG_VERSION}/module" \
   "${BUILDROOT}/BUILD/kvmfr-${LG_VERSION}"
tar -czf "${BUILDROOT}/SOURCES/kvmfr-${LG_VERSION}.tar.gz" \
    -C "${BUILDROOT}/BUILD" "kvmfr-${LG_VERSION}"
ok "Source tarball created: kvmfr-${LG_VERSION}.tar.gz"

# ── Write spec ─────────────────────────────────────────────────
info "Writing spec file..."
cat > "${BUILDROOT}/SPECS/kvmfr.spec" <<'SPEC_EOF'
%global debug_package %{nil}

Name:           kmod-kvmfr-%{kernel_version}
Version:        %{kmod_version}
Release:        1%{?dist}
Summary:        KVM framebuffer relay kernel module for Looking Glass, built for %{kernel_version}
License:        GPL-2.0
URL:            https://github.com/gnif/LookingGlass
Source0:        kvmfr-%{kmod_version}.tar.gz

BuildRequires:  kernel-devel
BuildRequires:  gcc
BuildRequires:  make

Requires:       kernel
Requires:       kvmfr-kmod-common = %{kmod_version}

%description
KVM framebuffer relay (kvmfr) kernel module, built from the module/
source of the upstream Looking Glass project, for kernel %{kernel_version}.
Provides /dev/kvmfrN for use with the Looking Glass client.

%package -n kvmfr-kmod-common
Summary:        Looking Glass kvmfr module-load configuration
License:        GPL-2.0

%description -n kvmfr-kmod-common
Loads the kvmfr kernel module at boot via modules-load.d, so it does
not need to be loaded manually with modprobe.

%prep
%setup -q -n kvmfr-%{kmod_version}
find . -type f -name '*.c' -exec sed -i "s/#VERSION#/%{kmod_version}/" {} \+

%build
make -j%(nproc) -C /usr/src/kernels/%{kernel_version} M=%{_builddir}/kvmfr-%{kmod_version} modules

%install
install -d %{buildroot}/usr/lib/modules/%{kernel_version}/extra/kvmfr
install -D -m 0644 kvmfr.ko %{buildroot}/usr/lib/modules/%{kernel_version}/extra/kvmfr/kvmfr.ko

install -d %{buildroot}/usr/lib/modules-load.d
echo "kvmfr" > %{buildroot}/usr/lib/modules-load.d/kvmfr.conf

%files
/usr/lib/modules/%{kernel_version}/extra/kvmfr/kvmfr.ko

%files -n kvmfr-kmod-common
/usr/lib/modules-load.d/kvmfr.conf

%changelog
* %(date "+%a %b %d %Y") kernel-modules <ferret-linux> - %{kmod_version}-1
- Automated build by kernel-modules
- Kernel: %{kernel_version}
- LookingGlass tag: %{kmod_version}
SPEC_EOF
ok "Spec file written"

# ── Build RPMs ────────────────────────────────────────────────
info "Building RPMs..."
rpmbuild -bb "${BUILDROOT}/SPECS/kvmfr.spec" \
    --define "_topdir ${BUILDROOT}" \
    --define "kernel_version ${KERNEL_VERSION}" \
    --define "kmod_version ${LG_VERSION}"
ok "RPMs built"

# ── Verify & list built RPMs ──────────────────────────────────
info "Verifying built RPMs..."
mapfile -t RPMS < <(find "${BUILDROOT}/RPMS" -name '*.rpm' | sort)
[[ ${#RPMS[@]} -gt 0 ]] || fail "No RPMs found after build"

ok "Built RPMs:"
for rpm in "${RPMS[@]}"; do
    say "  ${CYAN}◈${NC}  $(basename "$rpm")"
done

# ── Verify kmod loads cleanly via modinfo ─────────────────────
info "Verifying kvmfr kmod..."
KMOD_RPM="$(printf '%s\n' "${RPMS[@]}" | grep 'kmod-kvmfr-' | head -1)"
[[ -n "${KMOD_RPM}" ]] || fail "kmod RPM not found for verification"

VERIFY_DIR="$(mktemp -d)"
pushd "${VERIFY_DIR}" > /dev/null
rpm2cpio "${KMOD_RPM}" | cpio -idm --quiet

MOD_FILE="$(find . -type f -name 'kvmfr.ko' | head -1)"
[[ -n "${MOD_FILE}" ]] || fail "kvmfr.ko not found inside built RPM"
modinfo "${MOD_FILE}" > /dev/null || fail "modinfo failed on kvmfr.ko"
ok "kvmfr.ko verified: $(modinfo -F version "${MOD_FILE}" 2>/dev/null || echo unknown)"

popd > /dev/null
rm -rf "${VERIFY_DIR}"

# ── Copy to output ────────────────────────────────────────────
info "Copying RPMs to /output/..."
cp "${RPMS[@]}" /output/
ok "RPMs copied to /output/"

# ── Cleanup ───────────────────────────────────────────────────
info "Cleaning up build directory..."
rm -rf "${BUILDROOT}"
ok "Cleanup complete"

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◆  kvmfr build complete                   ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════════╝${NC}"
say ""