#!/bin/bash
#
# gentoo-installer.sh
# Instalador interativo do Gentoo Linux
#
# - Particionamento manual (cfdisk, fdisk ou parted, à sua escolha)
# - Escolha de filesystem e mountpoint por partição
# - Escolha de modo de boot (UEFI ou BIOS legado)
# - Escolha de init system (OpenRC ou systemd) dentro do chroot
#
# Uso: execute como root a partir de um live media do Gentoo (minimal install CD)
#      com conexão à internet já configurada (net-setup, dhcpcd, etc).
#
set -uo pipefail

# ------------------------------------------------------------------
# Cores / helpers
# ------------------------------------------------------------------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_BLUE='\033[1;34m'

log()   { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()   { echo -e "${C_RED}[x]${C_RESET} $*" >&2; }
step()  { echo -e "\n${C_BLUE}${C_BOLD}==> $*${C_RESET}"; }
die()   { err "$*"; exit 1; }

ask() {
    # ask "pergunta" "default"
    local prompt="$1" default="${2:-}" reply
    if [ -n "$default" ]; then
        read -rp "$(echo -e "${C_BOLD}${prompt}${C_RESET} [$default]: ")" reply
        echo "${reply:-$default}"
    else
        read -rp "$(echo -e "${C_BOLD}${prompt}${C_RESET}: ")" reply
        echo "$reply"
    fi
}

confirm() {
    # confirm "pergunta" -> retorna 0 (sim) ou 1 (não)
    local reply
    read -rp "$(echo -e "${C_BOLD}$1${C_RESET} [s/N]: ")" reply
    [[ "$reply" =~ ^[sSyY]$ ]]
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Este script precisa ser executado como root."
}

# ------------------------------------------------------------------
# Estado global
# ------------------------------------------------------------------
DISK=""
BOOT_MODE=""            # uefi | bios
INIT_SYSTEM=""           # openrc | systemd
PART_TABLE_TOOL=""       # cfdisk | fdisk | parted
declare -a PARTS         # cada item: "device:mountpoint:fstype"
STAGE3_URL=""
HOSTNAME=""
TIMEZONE=""
LOCALE_GEN=""
ROOT_MNT="/mnt/gentoo"

# ==================================================================
# 1. Seleção de disco
# ==================================================================
step "Discos disponíveis"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E 'disk$'
DISK=$(ask "Digite o disco alvo (ex: /dev/sda, /dev/nvme0n1)")
[ -b "$DISK" ] || die "Dispositivo $DISK não encontrado."

warn "TODOS os dados em $DISK serão apagados durante o particionamento."
confirm "Confirma que deseja continuar com $DISK?" || die "Instalação abortada pelo usuário."

# ==================================================================
# 2. Modo de boot
# ==================================================================
step "Modo de boot"
echo "1) UEFI (recomendado em máquinas modernas)"
echo "2) BIOS legado / MBR"
while true; do
    opt=$(ask "Escolha o modo de boot (1/2)")
    case "$opt" in
        1) BOOT_MODE="uefi"; break ;;
        2) BOOT_MODE="bios"; break ;;
        *) warn "Opção inválida." ;;
    esac
done
log "Modo de boot selecionado: $BOOT_MODE"

if [ "$BOOT_MODE" = "uefi" ] && [ ! -d /sys/firmware/efi ]; then
    warn "O live media atual não parece estar rodando em modo EFI."
    confirm "Deseja continuar mesmo assim?" || die "Instalação abortada."
fi

# ==================================================================
# 3. Particionamento manual (opcional)
# ==================================================================
step "Particionamento"
SKIP_PARTITIONING=0
if confirm "As partições em $DISK já existem? (pular etapa de particionamento e ir direto para format/mountpoints)"; then
    SKIP_PARTITIONING=1
    log "Particionamento pulado. Usando as partições já existentes em $DISK."
    lsblk "$DISK"
else
    echo "1) cfdisk (interface ncurses simples)"
    echo "2) fdisk (linha de comando, MBR/GPT)"
    echo "3) parted (linha de comando, GPT recomendado)"
    while true; do
        opt=$(ask "Escolha a ferramenta (1/2/3)")
        case "$opt" in
            1) PART_TABLE_TOOL="cfdisk"; break ;;
            2) PART_TABLE_TOOL="fdisk"; break ;;
            3) PART_TABLE_TOOL="parted"; break ;;
            *) warn "Opção inválida." ;;
        esac
    done

    command -v "$PART_TABLE_TOOL" >/dev/null 2>&1 || die "$PART_TABLE_TOOL não está disponível neste live media."

    log "Abrindo $PART_TABLE_TOOL em $DISK. Crie suas partições e salve antes de sair."
    sleep 1
    "$PART_TABLE_TOOL" "$DISK"

    lsblk "$DISK"
fi

# ==================================================================
# 4. Definição de filesystem e mountpoint por partição
# ==================================================================
step "Definição de filesystem e mountpoint"
echo "Informe cada partição criada. Digite 'fim' no campo do dispositivo para encerrar."
echo "Filesystems suportados: ext4, btrfs, xfs, vfat, swap"
echo

while true; do
    dev=$(ask "Dispositivo da partição (ex: ${DISK}1) ou 'fim' para terminar")
    [ "$dev" = "fim" ] && break
    [ -b "$dev" ] || { warn "Dispositivo $dev não existe."; continue; }

    fstype=$(ask "Filesystem para $dev (ext4/btrfs/xfs/vfat/swap)")
    case "$fstype" in
        ext4|btrfs|xfs|vfat|swap) ;;
        *) warn "Filesystem inválido."; continue ;;
    esac

    if [ "$fstype" = "swap" ]; then
        mnt="swap"
    else
        mnt=$(ask "Mountpoint para $dev (ex: /, /boot, /home)")
        [[ "$mnt" == /* ]] || { warn "Mountpoint deve começar com /"; continue; }
    fi

    PARTS+=("${dev}:${mnt}:${fstype}")
    log "Adicionado: $dev -> $mnt ($fstype)"
done

[ "${#PARTS[@]}" -gt 0 ] || die "Nenhuma partição definida. Abortando."

# Precisa existir uma partição raiz
has_root=0
for p in "${PARTS[@]}"; do
    IFS=':' read -r _ mnt _ <<< "$p"
    [ "$mnt" = "/" ] && has_root=1
done
[ "$has_root" -eq 1 ] || die "Nenhuma partição raiz (/) foi definida."

# ==================================================================
# 5. Formatação
# ==================================================================
step "Formatando partições"
for p in "${PARTS[@]}"; do
    IFS=':' read -r dev mnt fstype <<< "$p"
    case "$fstype" in
        ext4)  log "mkfs.ext4 $dev";  mkfs.ext4 -F "$dev" ;;
        btrfs) log "mkfs.btrfs $dev"; mkfs.btrfs -f "$dev" ;;
        xfs)   log "mkfs.xfs $dev";   mkfs.xfs -f "$dev" ;;
        vfat)  log "mkfs.vfat $dev";  mkfs.vfat -F32 "$dev" ;;
        swap)  log "mkswap $dev";     mkswap "$dev"; swapon "$dev" ;;
    esac
done

# ==================================================================
# 6. Montagem (raiz primeiro, depois demais em ordem de profundidade)
# ==================================================================
step "Montando partições em $ROOT_MNT"
mkdir -p "$ROOT_MNT"

# monta a raiz primeiro
for p in "${PARTS[@]}"; do
    IFS=':' read -r dev mnt fstype <<< "$p"
    if [ "$mnt" = "/" ]; then
        mount "$dev" "$ROOT_MNT" || die "Falha ao montar partição raiz."
        log "Raiz montada: $dev -> $ROOT_MNT"
    fi
done

# ordena os demais mountpoints por profundidade (menor número de '/' primeiro)
mapfile -t sorted_parts < <(
    for p in "${PARTS[@]}"; do
        IFS=':' read -r dev mnt fstype <<< "$p"
        [ "$mnt" = "/" ] && continue
        [ "$mnt" = "swap" ] && continue
        depth=$(grep -o '/' <<< "$mnt" | wc -l)
        echo "${depth}:${p}"
    done | sort -n -t: -k1,1
)

for entry in "${sorted_parts[@]}"; do
    p="${entry#*:}"
    IFS=':' read -r dev mnt fstype <<< "$p"
    mkdir -p "${ROOT_MNT}${mnt}"
    mount "$dev" "${ROOT_MNT}${mnt}" || die "Falha ao montar $dev em $mnt"
    log "Montado: $dev -> ${ROOT_MNT}${mnt}"
done

# ==================================================================
# 7. Stage3
# ==================================================================
# Links diretos (snapshot fixo). Gerados a partir de:
#   amd64/arm64: 20260705T*, x86: 20260707T170109Z
# Caso o mirror expire esses builds, atualize as URLs abaixo em
# https://www.gentoo.org/downloads/
step "Download do stage3"

ARCH=$(ask "Arquitetura (amd64/arm64/x86)" "amd64")

case "$ARCH" in
    amd64|arm64)
        echo "1) openrc"
        echo "2) systemd"
        while true; do
            opt=$(ask "Init system para o stage3 (1/2)")
            case "$opt" in
                1) INIT_SYSTEM="openrc"; break ;;
                2) INIT_SYSTEM="systemd"; break ;;
                *) warn "Opção inválida." ;;
            esac
        done

        echo "1) minimal"
        echo "2) desktop"
        while true; do
            opt=$(ask "Variante do stage3 (1/2)")
            case "$opt" in
                1) VARIANT="minimal"; break ;;
                2) VARIANT="desktop"; break ;;
                *) warn "Opção inválida." ;;
            esac
        done
        ;;
    x86)
        echo "1) openrc"
        echo "2) systemd"
        while true; do
            opt=$(ask "Init system para o stage3 (1/2)")
            case "$opt" in
                1) INIT_SYSTEM="openrc"; break ;;
                2) INIT_SYSTEM="systemd"; break ;;
                *) warn "Opção inválida." ;;
            esac
        done

        echo "1) i686"
        echo "2) i486"
        while true; do
            opt=$(ask "Subarquitetura (1/2)")
            case "$opt" in
                1) VARIANT="i686"; break ;;
                2) VARIANT="i486"; break ;;
                *) warn "Opção inválida." ;;
            esac
        done
        ;;
    *)
        die "Arquitetura inválida: $ARCH"
        ;;
esac

# Tabela de links diretos (snapshot fixo, ver comentário acima)
declare -A STAGE3_LINKS=(
    [amd64:openrc:minimal]="https://distfiles.gentoo.org/releases/amd64/autobuilds/20260705T170105Z/stage3-amd64-openrc-20260705T170105Z.tar.xz"
    [amd64:systemd:minimal]="https://distfiles.gentoo.org/releases/amd64/autobuilds/20260705T170105Z/stage3-amd64-systemd-20260705T170105Z.tar.xz"
    [amd64:openrc:desktop]="https://distfiles.gentoo.org/releases/amd64/autobuilds/20260705T170105Z/stage3-amd64-desktop-openrc-20260705T170105Z.tar.xz"
    [amd64:systemd:desktop]="https://distfiles.gentoo.org/releases/amd64/autobuilds/20260705T170105Z/stage3-amd64-desktop-systemd-20260705T170105Z.tar.xz"
    [arm64:openrc:minimal]="https://distfiles.gentoo.org/releases/arm64/autobuilds/20260705T233102Z/stage3-arm64-openrc-20260705T233102Z.tar.xz"
    [arm64:systemd:minimal]="https://distfiles.gentoo.org/releases/arm64/autobuilds/20260705T233102Z/stage3-arm64-systemd-20260705T233102Z.tar.xz"
    [arm64:openrc:desktop]="https://distfiles.gentoo.org/releases/arm64/autobuilds/20260705T233102Z/stage3-arm64-desktop-openrc-20260705T233102Z.tar.xz"
    [arm64:systemd:desktop]="https://distfiles.gentoo.org/releases/arm64/autobuilds/20260705T233102Z/stage3-arm64-desktop-systemd-20260705T233102Z.tar.xz"
    [x86:openrc:i686]="https://distfiles.gentoo.org/releases/x86/autobuilds/20260707T170109Z/stage3-i686-openrc-20260707T170109Z.tar.xz"
    [x86:systemd:i686]="https://distfiles.gentoo.org/releases/x86/autobuilds/20260707T170109Z/stage3-i686-systemd-20260707T170109Z.tar.xz"
    [x86:openrc:i486]="https://distfiles.gentoo.org/releases/x86/autobuilds/20260707T170109Z/stage3-i486-openrc-20260707T170109Z.tar.xz"
    [x86:systemd:i486]="https://distfiles.gentoo.org/releases/x86/autobuilds/20260707T170109Z/stage3-i486-systemd-20260707T170109Z.tar.xz"
)

KEY="${ARCH}:${INIT_SYSTEM}:${VARIANT}"
STAGE3_URL="${STAGE3_LINKS[$KEY]:-}"
[ -n "$STAGE3_URL" ] || die "Nenhum link encontrado para $KEY."

log "Baixando: $STAGE3_URL"
cd "$ROOT_MNT" || die "Não foi possível acessar $ROOT_MNT"
curl -fL -o stage3.tar.xz "$STAGE3_URL" || die "Falha no download do stage3."

log "Extraindo stage3..."
tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C "$ROOT_MNT" \
    > /tmp/stage3-extract.log 2>&1 \
    || die "Falha ao extrair o stage3 (veja /tmp/stage3-extract.log)."
rm -f "$ROOT_MNT/stage3.tar.xz"

# ==================================================================
# 8. Configuração básica antes do chroot
# ==================================================================
step "Configurando make.conf básico"
NPROC=$(nproc)
if ! grep -q '^MAKEOPTS' "$ROOT_MNT/etc/portage/make.conf" 2>/dev/null; then
    {
        echo "MAKEOPTS=\"-j${NPROC}\""
        echo "EMERGE_DEFAULT_OPTS=\"--jobs=$(( NPROC > 2 ? NPROC/2 : 1 )) --load-average=${NPROC}\""
    } >> "$ROOT_MNT/etc/portage/make.conf"
fi

step "Copiando resolv.conf"
cp --dereference /etc/resolv.conf "$ROOT_MNT/etc/" || warn "Não foi possível copiar resolv.conf."

step "Montando filesystems virtuais"
mount --types proc /proc "$ROOT_MNT/proc"
mount --rbind /sys "$ROOT_MNT/sys"
mount --make-rslave "$ROOT_MNT/sys"
mount --rbind /dev "$ROOT_MNT/dev"
mount --make-rslave "$ROOT_MNT/dev"
mount --bind /run "$ROOT_MNT/run" 2>/dev/null || true
mount --make-slave "$ROOT_MNT/run" 2>/dev/null || true

# ==================================================================
# 9. Coleta de dados para dentro do chroot
# ==================================================================
step "Configurações finais do sistema"
HOSTNAME=$(ask "Hostname da máquina" "gentoo")
TIMEZONE=$(ask "Timezone (ex: America/Fortaleza)" "America/Fortaleza")
LOCALE_GEN=$(ask "Locale principal (ex: pt_BR.UTF-8 UTF-8)" "pt_BR.UTF-8 UTF-8")
ROOT_PASSWORD=$(ask "Senha de root (será usada dentro do chroot)")
NEW_USER=$(ask "Nome do usuário a ser criado (deixe vazio para pular)")

BOOTLOADER_PKG="grub"

# ==================================================================
# 10. Script que roda dentro do chroot
# ==================================================================
step "Gerando script de segunda etapa (dentro do chroot)"
cat > "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF
#!/bin/bash
set -uo pipefail

log()  { echo -e "\033[1;32m[+]\033[0m \$*"; }
warn() { echo -e "\033[1;33m[!]\033[0m \$*"; }
die()  { echo -e "\033[1;31m[x]\033[0m \$*" >&2; exit 1; }

log "Sincronizando o Portage (isso pode demorar)..."
emerge-webrsync

log "Selecionando perfil..."
eselect profile list
echo "Ajuste o perfil manualmente com 'eselect profile set <n>' se necessário."

log "Definindo timezone: ${TIMEZONE}"
echo "${TIMEZONE}" > /etc/timezone
emerge --config sys-libs/timezone-data 2>/dev/null || true

log "Configurando locale: ${LOCALE_GEN}"
echo "${LOCALE_GEN}" >> /etc/locale.gen
locale-gen
eselect locale list
echo "Ajuste com 'eselect locale set <n>' se necessário."

log "Definindo hostname: ${HOSTNAME}"
echo "hostname=\"${HOSTNAME}\"" > /etc/conf.d/hostname 2>/dev/null || true
echo "${HOSTNAME}" > /etc/hostname 2>/dev/null || true

log "Instalando kernel (genkernel + firmware)..."
emerge --ask=n sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/linux-firmware
log "Compilando kernel com genkernel (pode demorar bastante)..."
genkernel --install all

log "Gerando fstab..."
: > /etc/fstab
echo "# <fs>          <mountpoint>   <type>   <opts>        <dump/pass>" >> /etc/fstab
CHROOT_EOF

# gera as linhas do fstab a partir de PARTS, com UUID
for p in "${PARTS[@]}"; do
    IFS=':' read -r dev mnt fstype <<< "$p"
    uuid=$(blkid -s UUID -o value "$dev")
    if [ "$mnt" = "swap" ]; then
        echo "echo \"UUID=${uuid}  none  swap  sw  0 0\" >> /etc/fstab" >> "$ROOT_MNT/root/chroot-setup.sh"
    else
        opts="defaults"
        pass="2"
        [ "$mnt" = "/" ] && pass="1"
        echo "echo \"UUID=${uuid}  ${mnt}  ${fstype}  ${opts}  0 ${pass}\" >> /etc/fstab" >> "$ROOT_MNT/root/chroot-setup.sh"
    fi
done

cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Instalando bootloader ($BOOTLOADER_PKG)..."
emerge --ask=n sys-boot/grub

if [ "${BOOT_MODE}" = "uefi" ]; then
    emerge --ask=n sys-boot/efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GENTOO
else
    grub-install "${DISK}"
fi
grub-mkconfig -o /boot/grub/grub.cfg

log "Definindo senha de root..."
echo "root:${ROOT_PASSWORD}" | chpasswd

if [ -n "${NEW_USER}" ]; then
    log "Criando usuário ${NEW_USER}..."
    useradd -m -G users,wheel,audio,video -s /bin/bash "${NEW_USER}"
    echo "Defina a senha para ${NEW_USER}:"
    passwd "${NEW_USER}"
    emerge --ask=n app-admin/sudo
    echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi

if [ "${INIT_SYSTEM}" = "openrc" ]; then
    log "Configurando serviços OpenRC básicos..."
    emerge --ask=n net-misc/dhcpcd
    rc-update add dhcpcd default
    rc-update add sshd default 2>/dev/null || true
else
    log "Habilitando serviços systemd básicos..."
    systemctl enable systemd-networkd 2>/dev/null || true
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl enable sshd 2>/dev/null || true
fi

log "Etapa dentro do chroot concluída."
CHROOT_EOF

chmod +x "$ROOT_MNT/root/chroot-setup.sh"

# ==================================================================
# 11. Entrando no chroot e executando
# ==================================================================
step "Entrando no chroot para finalizar a instalação"
chroot "$ROOT_MNT" /bin/bash /root/chroot-setup.sh || die "Falha durante a configuração no chroot."

# ==================================================================
# 12. Limpeza e finalização
# ==================================================================
step "Instalação concluída"
log "Desmontando filesystems..."
umount -l "$ROOT_MNT/dev" 2>/dev/null
umount -l "$ROOT_MNT/sys" 2>/dev/null
umount -l "$ROOT_MNT/proc" 2>/dev/null
umount -l "$ROOT_MNT/run" 2>/dev/null

for entry in "${sorted_parts[@]}"; do
    p="${entry#*:}"
    IFS=':' read -r dev mnt fstype <<< "$p"
    umount -l "${ROOT_MNT}${mnt}" 2>/dev/null
done
umount -l "$ROOT_MNT" 2>/dev/null

log "Gentoo instalado com sucesso em $DISK."
log "Reinicie a máquina e remova o live media."
