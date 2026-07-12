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
C_BLUE='\033[1;35m'
C_CYAN='\033[0;36m'

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

opt() {
    # opt "1) texto da opção"
    echo -e "${C_CYAN}$*${C_RESET}"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Este script precisa ser executado como root."
}

# ------------------------------------------------------------------
# i18n — cobertura definida manualmente (não é calculada de verdade,
# é só uma estimativa honesta de quanto do texto já foi traduzido).
# Os logs internos gerados dentro do chroot ainda são só em pt-BR.
# ------------------------------------------------------------------
declare -A MSGS
LANG_CHOICE="pt"
PT_COVERAGE=100
EN_COVERAGE=55

t() {
    local key="$1" val
    val="${MSGS[${LANG_CHOICE}:${key}]:-}"
    [ -z "$val" ] && val="${MSGS[pt:${key}]:-$key}"
    printf '%s' "$val"
}

tf() {
    local key="$1"; shift
    # shellcheck disable=SC2059
    printf "$(t "$key")\n" "$@"
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
# -1. Idioma / Language
# ==================================================================
echo -e "${C_CYAN}1) Português${C_RESET}"
echo -e "${C_CYAN}2) English (~${EN_COVERAGE}% traduzido / translated)${C_RESET}"
read -rp "$(echo -e "${C_BOLD}Idioma / Language [1]${C_RESET}: ")" lang_reply
case "$lang_reply" in
    2) LANG_CHOICE="en" ;;
    *) LANG_CHOICE="pt" ;;
esac

# Dicionário de mensagens. Chave "pt:X" é a fonte (100% cobertura);
# "en:X" é a tradução (parcial — ver EN_COVERAGE acima).
MSGS[pt:step_checks]="Checagens iniciais"
MSGS[en:step_checks]="Initial checks"
MSGS[pt:step_disk]="Discos disponíveis"
MSGS[en:step_disk]="Available disks"
MSGS[pt:disk_prompt]="Digite o disco alvo (ex: /dev/sda, /dev/nvme0n1)"
MSGS[en:disk_prompt]="Enter the target disk (e.g: /dev/sda, /dev/nvme0n1)"
MSGS[pt:disk_wipe_warn]="TODOS os dados em %s serão apagados durante o particionamento."
MSGS[en:disk_wipe_warn]="ALL data on %s will be erased during partitioning."
MSGS[pt:confirm_continue_disk]="Confirma que deseja continuar com %s?"
MSGS[en:confirm_continue_disk]="Confirm you want to continue with %s?"
MSGS[pt:step_bootmode]="Modo de boot"
MSGS[en:step_bootmode]="Boot mode"
MSGS[pt:bootmode_prompt]="Escolha o modo de boot (1/2)"
MSGS[en:bootmode_prompt]="Choose the boot mode (1/2)"
MSGS[pt:step_partitioning]="Particionamento"
MSGS[en:step_partitioning]="Partitioning"
MSGS[pt:existing_parts_confirm]="As partições em %s já existem? (pular etapa de particionamento e ir direto para format/mountpoints)"
MSGS[en:existing_parts_confirm]="Do the partitions on %s already exist? (skip partitioning and go straight to format/mountpoints)"
MSGS[pt:create_label_confirm]="Criar automaticamente a tabela de partição (%s) em %s? (apaga a tabela atual; responda não para manter a tabela existente)"
MSGS[en:create_label_confirm]="Automatically create the partition table (%s) on %s? (erases the current table; answer no to keep the existing one)"
MSGS[pt:tool_choice_prompt]="Escolha a ferramenta (1/2/3)"
MSGS[en:tool_choice_prompt]="Choose the tool (1/2/3)"
MSGS[pt:step_fsmount]="Definição de filesystem e mountpoint"
MSGS[en:step_fsmount]="Filesystem and mountpoint definition"
MSGS[pt:dev_prompt]="Dispositivo da partição (ex: %s1) ou 'fim' para terminar"
MSGS[en:dev_prompt]="Partition device (e.g: %s1) or 'end' to finish"
MSGS[pt:fim_keyword]="fim"
MSGS[en:fim_keyword]="end"
MSGS[pt:fstype_prompt]="Filesystem para %s (ext4/btrfs/xfs/vfat/swap)"
MSGS[en:fstype_prompt]="Filesystem for %s (ext4/btrfs/xfs/vfat/swap)"
MSGS[pt:mount_prompt]="Mountpoint para %s (ex: /, /boot, /home)"
MSGS[en:mount_prompt]="Mountpoint for %s (e.g: /, /boot, /home)"
MSGS[pt:step_format]="Formatando partições"
MSGS[en:step_format]="Formatting partitions"
MSGS[pt:step_mount]="Montando partições em %s"
MSGS[en:step_mount]="Mounting partitions on %s"
MSGS[pt:step_stage3]="Download do stage3"
MSGS[en:step_stage3]="Downloading stage3"
MSGS[pt:arch_prompt]="Arquitetura (amd64/arm64/x86)"
MSGS[en:arch_prompt]="Architecture (amd64/arm64/x86)"
MSGS[pt:init_prompt]="Init system para o stage3 (1/2)"
MSGS[en:init_prompt]="Init system for the stage3 (1/2)"
MSGS[pt:variant_prompt]="Variante do stage3 (1/2)"
MSGS[en:variant_prompt]="Stage3 variant (1/2)"
MSGS[pt:subarch_prompt]="Subarquitetura (1/2)"
MSGS[en:subarch_prompt]="Sub-architecture (1/2)"
MSGS[pt:step_makeconf]="Configurando make.conf"
MSGS[en:step_makeconf]="Configuring make.conf"
MSGS[pt:march_confirm]="Usar -march=native nas CFLAGS? (otimizado pra essa CPU específica; não copie esse disco pra outro hardware depois)"
MSGS[en:march_confirm]="Use -march=native in CFLAGS? (optimized for this specific CPU; don't copy this disk to other hardware afterwards)"
MSGS[pt:step_useflags]="USE flags"
MSGS[en:step_useflags]="USE flags"
MSGS[pt:keymap_prompt]="Layout de teclado do console (1/2)"
MSGS[en:keymap_prompt]="Console keyboard layout (1/2)"
MSGS[pt:display_prompt]="Servidor gráfico (1/2)"
MSGS[en:display_prompt]="Display server (1/2)"
MSGS[pt:audio_prompt]="Sistema de áudio (1/2)"
MSGS[en:audio_prompt]="Audio system (1/2)"
MSGS[pt:videocards_prompt]="VIDEO_CARDS (ajuste se a detecção estiver errada)"
MSGS[en:videocards_prompt]="VIDEO_CARDS (adjust if detection got it wrong)"
MSGS[pt:step_finalconfig]="Configurações finais do sistema"
MSGS[en:step_finalconfig]="Final system configuration"
MSGS[pt:hostname_prompt]="Hostname da máquina"
MSGS[en:hostname_prompt]="Machine hostname"
MSGS[pt:timezone_prompt]="Timezone (ex: America/Fortaleza)"
MSGS[en:timezone_prompt]="Timezone (e.g: America/Fortaleza)"
MSGS[pt:locale_prompt]="Locale principal (ex: pt_BR.UTF-8 UTF-8)"
MSGS[en:locale_prompt]="Main locale (e.g: en_US.UTF-8 UTF-8)"
MSGS[pt:newuser_prompt]="Nome do usuário a ser criado (deixe vazio para pular)"
MSGS[en:newuser_prompt]="Username to create (leave empty to skip)"
MSGS[pt:step_network]="Rede"
MSGS[en:step_network]="Network"
MSGS[pt:wifi_confirm]="Deseja configurar uma rede WiFi para o sistema instalado?"
MSGS[en:wifi_confirm]="Do you want to configure a WiFi network for the installed system?"
MSGS[pt:wifi_iface_prompt]="Nome da interface WiFi (ex: wlan0)"
MSGS[en:wifi_iface_prompt]="WiFi interface name (e.g: wlan0)"
MSGS[pt:wifi_ssid_prompt]="SSID da rede WiFi"
MSGS[en:wifi_ssid_prompt]="WiFi network SSID"
MSGS[pt:wifi_pass_prompt]="Senha da rede WiFi (deixe vazio se a rede for aberta)"
MSGS[en:wifi_pass_prompt]="WiFi network password (leave empty for open networks)"
MSGS[pt:step_kernel]="Kernel"
MSGS[en:step_kernel]="Kernel"
MSGS[pt:kernel_mode_prompt]="Escolha o método de instalação do kernel (1/2/3)"
MSGS[en:kernel_mode_prompt]="Choose the kernel installation method (1/2/3)"
MSGS[pt:kernel_config_prompt]="Caminho para um .config existente (vazio = abrir 'make menuconfig' interativo)"
MSGS[en:kernel_config_prompt]="Path to an existing .config (empty = open interactive 'make menuconfig')"
MSGS[pt:step_genscript]="Gerando script de segunda etapa (dentro do chroot)"
MSGS[en:step_genscript]="Generating second-stage script (inside the chroot)"
MSGS[pt:step_enterchroot]="Entrando no chroot para finalizar a instalação"
MSGS[en:step_enterchroot]="Entering the chroot to finish the installation"
MSGS[pt:step_installdone]="Instalação base concluída"
MSGS[en:step_installdone]="Base installation complete"
MSGS[pt:finalmenu_prompt]="O que deseja fazer agora? (1/2/3/4)"
MSGS[en:finalmenu_prompt]="What do you want to do now? (1/2/3/4)"
MSGS[pt:opt_invalid]="Opção inválida."
MSGS[en:opt_invalid]="Invalid option."


# ==================================================================
# 0. Checagens iniciais
# ==================================================================
step "$(t step_checks)"
require_root

for tool in curl tar chroot blkid lsblk mkswap; do
    command -v "$tool" >/dev/null 2>&1 || die "Ferramenta obrigatória '$tool' não encontrada no live media."
done

log "Testando conectividade..."
if ! curl -fsSL --max-time 5 -o /dev/null https://distfiles.gentoo.org; then
    warn "Não consegui alcançar distfiles.gentoo.org. Verifique a rede (dhcpcd, net-setup, wpa_supplicant, etc)."
    confirm "Continuar mesmo assim?" || die "Instalação abortada."
fi

# ==================================================================
# 1. Seleção de disco
# ==================================================================
step "$(t step_disk)"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E 'disk$'
DISK=$(ask "$(t disk_prompt)")
[ -b "$DISK" ] || die "Dispositivo $DISK não encontrado."

warn "$(tf disk_wipe_warn "$DISK")"
confirm "$(tf confirm_continue_disk "$DISK")" || die "Instalação abortada pelo usuário."

# ==================================================================
# 2. Modo de boot
# ==================================================================
step "$(t step_bootmode)"
opt "1) UEFI (recomendado em máquinas modernas)"
opt "2) BIOS legado / MBR"
while true; do
    opt=$(ask "$(t bootmode_prompt)")
    case "$opt" in
        1) BOOT_MODE="uefi"; break ;;
        2) BOOT_MODE="bios"; break ;;
        *) warn "$(t opt_invalid)" ;;
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
step "$(t step_partitioning)"

if [ "$BOOT_MODE" = "bios" ]; then
    DISK_LABEL="msdos"
else
    DISK_LABEL="gpt"
fi

SKIP_PARTITIONING=0
if confirm "$(tf existing_parts_confirm "$DISK")"; then
    SKIP_PARTITIONING=1
    log "Particionamento pulado. Usando as partições já existentes em $DISK."
else
    if confirm "$(tf create_label_confirm "$DISK_LABEL" "$DISK")"; then
        command -v parted >/dev/null 2>&1 || die "parted não está disponível para criar a tabela de partição."

        [ "$BOOT_MODE" = "bios" ] && warn "Legacy BIOS: deixe pelo menos 1MiB de espaço livre antes da primeira partição (o GRUB embute o core.img nesse gap). As ferramentas modernas já alinham em 1MiB por padrão, então normalmente não precisa se preocupar."

        log "Criando tabela de partição $DISK_LABEL em $DISK..."
        parted -s "$DISK" mklabel "$DISK_LABEL" || die "Falha ao criar a tabela de partição $DISK_LABEL."
    else
        log "Criação automática da tabela pulada. Mantendo a tabela de partição existente em $DISK."
    fi

    opt "1) cfdisk (interface ncurses simples)"
    opt "2) fdisk (linha de comando, MBR/GPT)"
    opt "3) parted (linha de comando, GPT recomendado)"
    while true; do
        opt=$(ask "$(t tool_choice_prompt)")
        case "$opt" in
            1) PART_TABLE_TOOL="cfdisk"; break ;;
            2) PART_TABLE_TOOL="fdisk"; break ;;
            3) PART_TABLE_TOOL="parted"; break ;;
            *) warn "$(t opt_invalid)" ;;
        esac
    done

    command -v "$PART_TABLE_TOOL" >/dev/null 2>&1 || die "$PART_TABLE_TOOL não está disponível neste live media."

    log "Abrindo $PART_TABLE_TOOL em $DISK. Crie suas partições e salve antes de sair."
    sleep 1
    "$PART_TABLE_TOOL" "$DISK"
fi

# Detecta a tabela de partição atual e avisa sobre incompatibilidade com o boot mode escolhido
CURRENT_PTTYPE=$(blkid -o value -s PTTYPE "$DISK" 2>/dev/null || true)
if [ "$BOOT_MODE" = "uefi" ] && [ "$CURRENT_PTTYPE" != "gpt" ]; then
    warn "A tabela de partição em $DISK é '${CURRENT_PTTYPE:-desconhecida}', não 'gpt'. Boot UEFI normalmente exige GPT."
    confirm "Continuar mesmo assim?" || die "Instalação abortada."
elif [ "$BOOT_MODE" = "bios" ] && [ "$CURRENT_PTTYPE" = "gpt" ]; then
    warn "A tabela de partição em $DISK é GPT, mas você escolheu boot BIOS legacy. Isso exige uma partição BIOS Boot (bios_grub) além da raiz, senão o grub-install falha."
    confirm "Continuar mesmo assim?" || die "Instalação abortada."
fi

lsblk "$DISK"

# ==================================================================
# 4. Definição de filesystem e mountpoint por partição
# ==================================================================
step "$(t step_fsmount)"
echo "Informe cada partição criada. Digite 'fim' no campo do dispositivo para encerrar."
echo "Filesystems suportados: ext4, btrfs, xfs, vfat, swap"
echo

while true; do
    dev=$(ask "$(tf dev_prompt "$DISK")")
    [ "$dev" = "fim" ] && break
    [ -b "$dev" ] || { warn "Dispositivo $dev não existe."; continue; }

    fstype=$(ask "$(tf fstype_prompt "$dev")")
    case "$fstype" in
        ext4|btrfs|xfs|vfat|swap) ;;
        *) warn "Filesystem inválido."; continue ;;
    esac

    if [ "$fstype" = "swap" ]; then
        mnt="swap"
    else
        mnt=$(ask "$(tf mount_prompt "$dev")")
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

# Validações extras para UEFI: precisa de uma ESP (vfat) montada em /boot
if [ "$BOOT_MODE" = "uefi" ]; then
    esp_found=0
    esp_dev=""
    for p in "${PARTS[@]}"; do
        IFS=':' read -r dev mnt fstype <<< "$p"
        if [ "$mnt" = "/boot" ] && [ "$fstype" = "vfat" ]; then
            esp_found=1
            esp_dev="$dev"
        fi
    done

    if [ "$esp_found" -eq 0 ]; then
        warn "Nenhuma partição vfat montada em /boot foi definida. Em UEFI, o GRUB precisa de uma ESP (vfat) em /boot para --efi-directory=/boot funcionar."
        confirm "Continuar mesmo assim?" || die "Instalação abortada."
    else
        esp_size_bytes=$(blockdev --getsize64 "$esp_dev" 2>/dev/null || echo 0)
        esp_size_mib=$(( esp_size_bytes / 1024 / 1024 ))
        if [ "$esp_size_mib" -gt 0 ] && [ "$esp_size_mib" -lt 100 ]; then
            warn "A ESP ($esp_dev) tem só ${esp_size_mib}MiB. Recomendado pelo menos 260MiB para evitar problemas com alguns firmwares."
        fi
    fi
fi

# ==================================================================
# 5. Formatação
# ==================================================================
step "$(t step_format)"
for p in "${PARTS[@]}"; do
    IFS=':' read -r dev mnt fstype <<< "$p"
    case "$fstype" in
        ext4)  log "mkfs.ext4 $dev";  mkfs.ext4 -F "$dev" ;;
        btrfs) log "mkfs.btrfs $dev"; mkfs.btrfs -f "$dev" ;;
        xfs)   log "mkfs.xfs $dev";   mkfs.xfs -f "$dev" ;;
        vfat)
            log "mkfs.vfat $dev"
            mkfs.vfat -F32 "$dev"
            if [ "$BOOT_MODE" = "uefi" ] && [ "$mnt" = "/boot" ]; then
                partnum=$(echo "$dev" | grep -o '[0-9]*$')
                if [ -n "$partnum" ]; then
                    log "Marcando $dev (partição $partnum) com a flag esp..."
                    parted -s "$DISK" set "$partnum" esp on 2>/dev/null \
                        || warn "Não foi possível marcar a flag esp em $dev automaticamente; confira com 'parted $DISK print'."
                fi
            fi
            ;;
        swap)  log "mkswap $dev";     mkswap "$dev"; swapon "$dev" ;;
    esac
done

# ==================================================================
# 6. Montagem (raiz primeiro, depois demais em ordem de profundidade)
# ==================================================================
step "$(tf step_mount "$ROOT_MNT")"
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
step "$(t step_stage3)"

ARCH=$(ask "$(t arch_prompt)" "amd64")

case "$ARCH" in
    amd64|arm64)
        opt "1) openrc"
        opt "2) systemd"
        while true; do
            opt=$(ask "$(t init_prompt)")
            case "$opt" in
                1) INIT_SYSTEM="openrc"; break ;;
                2) INIT_SYSTEM="systemd"; break ;;
                *) warn "Opção inválida." ;;
            esac
        done

        opt "1) minimal"
        opt "2) desktop"
        while true; do
            opt=$(ask "$(t variant_prompt)")
            case "$opt" in
                1) VARIANT="minimal"; break ;;
                2) VARIANT="desktop"; break ;;
                *) warn "Opção inválida." ;;
            esac
        done
        ;;
    x86)
        opt "1) openrc"
        opt "2) systemd"
        while true; do
            opt=$(ask "$(t init_prompt)")
            case "$opt" in
                1) INIT_SYSTEM="openrc"; break ;;
                2) INIT_SYSTEM="systemd"; break ;;
                *) warn "Opção inválida." ;;
            esac
        done

        opt "1) i686"
        opt "2) i486"
        while true; do
            opt=$(ask "$(t subarch_prompt)")
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
step "$(t step_makeconf)"
NPROC=$(nproc)
MAKE_CONF="$ROOT_MNT/etc/portage/make.conf"

MARCH_CHOICE="generic"
confirm "$(t march_confirm)" \
    && MARCH_CHOICE="native"

if ! grep -q '^MAKEOPTS' "$MAKE_CONF" 2>/dev/null; then
    echo "MAKEOPTS=\"-j${NPROC}\"" >> "$MAKE_CONF"
fi
if ! grep -q '^EMERGE_DEFAULT_OPTS' "$MAKE_CONF" 2>/dev/null; then
    echo "EMERGE_DEFAULT_OPTS=\"--jobs=$(( NPROC > 2 ? NPROC/2 : 1 )) --load-average=${NPROC}\"" >> "$MAKE_CONF"
fi

if [ "$MARCH_CHOICE" = "native" ]; then
    if grep -q '^COMMON_FLAGS' "$MAKE_CONF" 2>/dev/null; then
        sed -i 's/^COMMON_FLAGS=.*/COMMON_FLAGS="-march=native -O2 -pipe"/' "$MAKE_CONF"
    else
        echo 'COMMON_FLAGS="-march=native -O2 -pipe"' >> "$MAKE_CONF"
    fi
    log "CFLAGS configuradas com -march=native."
fi

# Sem isso, o emerge do intel-microcode/linux-firmware para no meio pedindo
# aceite de licença manual, o que trava um script não-interativo.
if ! grep -q '^ACCEPT_LICENSE' "$MAKE_CONF" 2>/dev/null; then
    echo 'ACCEPT_LICENSE="*"' >> "$MAKE_CONF"
    log "ACCEPT_LICENSE=\"*\" adicionado (necessário para microcode/firmware não-livres)."
fi

# GRUB_PLATFORMS precisa bater com o modo de boot escolhido, senão o
# sys-boot/grub é compilado sem o target certo e o grub-install falha.
if ! grep -q '^GRUB_PLATFORMS' "$MAKE_CONF" 2>/dev/null; then
    if [ "$BOOT_MODE" = "uefi" ]; then
        echo 'GRUB_PLATFORMS="efi-64"' >> "$MAKE_CONF"
    else
        echo 'GRUB_PLATFORMS="pc"' >> "$MAKE_CONF"
    fi
    log "GRUB_PLATFORMS definido para o modo de boot ($BOOT_MODE)."
fi

step "$(t step_useflags)"
USE_FLAGS=""
VIDEO_CARDS_VALUE=""
INPUT_DEVICES_VALUE=""
X11_CHOSEN=0

if [ "$INIT_SYSTEM" = "openrc" ]; then
    USE_FLAGS="elogind -systemd"
else
    USE_FLAGS="systemd -elogind"
fi

opt "1) us (padrão americano)"
opt "2) br (ABNT2)"
while true; do
    kopt=$(ask "$(t keymap_prompt)")
    case "$kopt" in
        1) KEYMAP="us"; break ;;
        2) KEYMAP="br-abnt2"; break ;;
        *) warn "Opção inválida." ;;
    esac
done

if [ "${VARIANT:-}" = "desktop" ]; then
    opt "1) X11 (Xorg)"
    opt "2) Wayland"
    while true; do
        opt=$(ask "$(t display_prompt)")
        case "$opt" in
            1) USE_FLAGS="$USE_FLAGS X -wayland"; X11_CHOSEN=1; break ;;
            2) USE_FLAGS="$USE_FLAGS wayland -X"; break ;;
            *) warn "Opção inválida." ;;
        esac
    done

    opt "1) PipeWire"
    opt "2) PulseAudio"
    while true; do
        opt=$(ask "$(t audio_prompt)")
        case "$opt" in
            1) USE_FLAGS="$USE_FLAGS pipewire -pulseaudio"; break ;;
            2) USE_FLAGS="$USE_FLAGS pulseaudio -pipewire"; break ;;
            *) warn "Opção inválida." ;;
        esac
    done

    # libinput cobre mouse, teclado e touchpad num driver só (substitui
    # synaptics/evdev, que estão obsoletos)
    INPUT_DEVICES_VALUE="libinput"
    USE_FLAGS="$USE_FLAGS libinput"

    log "Detectando placa de vídeo..."
    GPU_INFO=$(lspci -nnk 2>/dev/null | grep -Ei 'vga|3d|display' || true)
    [ -n "$GPU_INFO" ] && echo "$GPU_INFO"
    DETECTED_VIDEO_CARDS=""
    echo "$GPU_INFO" | grep -qi intel      && DETECTED_VIDEO_CARDS="$DETECTED_VIDEO_CARDS i915 intel"
    echo "$GPU_INFO" | grep -qi amd        && DETECTED_VIDEO_CARDS="$DETECTED_VIDEO_CARDS amdgpu radeonsi radeon"
    echo "$GPU_INFO" | grep -qi nvidia     && DETECTED_VIDEO_CARDS="$DETECTED_VIDEO_CARDS nouveau"
    echo "$GPU_INFO" | grep -qiE 'virtio|qxl|vmware|bochs|cirrus' && DETECTED_VIDEO_CARDS="$DETECTED_VIDEO_CARDS virtio qxl vmware fbdev"
    VIDEO_CARDS_VALUE=$(ask "$(t videocards_prompt)" "${DETECTED_VIDEO_CARDS# }")
fi

if ! grep -q '^USE=' "$MAKE_CONF" 2>/dev/null; then
    echo "USE=\"${USE_FLAGS}\"" >> "$MAKE_CONF"
else
    sed -i "s/^USE=\"/USE=\"${USE_FLAGS} /" "$MAKE_CONF"
fi
log "USE flags definidas: ${USE_FLAGS}"

if [ -n "$VIDEO_CARDS_VALUE" ]; then
    if ! grep -q '^VIDEO_CARDS=' "$MAKE_CONF" 2>/dev/null; then
        echo "VIDEO_CARDS=\"${VIDEO_CARDS_VALUE}\"" >> "$MAKE_CONF"
    fi
    log "VIDEO_CARDS definidas: ${VIDEO_CARDS_VALUE}"
fi

if [ -n "$INPUT_DEVICES_VALUE" ]; then
    if ! grep -q '^INPUT_DEVICES=' "$MAKE_CONF" 2>/dev/null; then
        echo "INPUT_DEVICES=\"${INPUT_DEVICES_VALUE}\"" >> "$MAKE_CONF"
    fi
    log "INPUT_DEVICES definidas: ${INPUT_DEVICES_VALUE} (mouse, teclado e touchpad)"
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
step "$(t step_finalconfig)"
HOSTNAME=$(ask "$(t hostname_prompt)" "gentoo")
TIMEZONE=$(ask "$(t timezone_prompt)" "America/Fortaleza")
LOCALE_GEN=$(ask "$(t locale_prompt)" "pt_BR.UTF-8 UTF-8")
NEW_USER=$(ask "$(t newuser_prompt)")

step "$(t step_network)"
CONFIGURE_WIFI=0
WIFI_IFACE=""
WIFI_SSID=""
WIFI_PASS=""
if confirm "$(t wifi_confirm)"; then
    echo "Interfaces de rede detectadas:"
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$'
    WIFI_IFACE=$(ask "$(t wifi_iface_prompt)")
    WIFI_SSID=$(ask "$(t wifi_ssid_prompt)")
    WIFI_PASS=$(ask "$(t wifi_pass_prompt)")
    CONFIGURE_WIFI=1
else
    log "Configuração de WiFi pulada. A rede cabeada (DHCP) já é habilitada por padrão."
fi

step "$(t step_kernel)"
opt "1) gentoo-kernel-bin (binário pré-compilado — mais rápido, módulos e initramfs prontos)"
opt "2) genkernel (compila da fonte, configuração automática)"
opt "3) fonte manual (gentoo-sources + make menuconfig, você controla o .config)"
while true; do
    opt=$(ask "$(t kernel_mode_prompt)")
    case "$opt" in
        1) KERNEL_MODE="bin"; break ;;
        2) KERNEL_MODE="genkernel"; break ;;
        3) KERNEL_MODE="manual"; break ;;
        *) warn "Opção inválida." ;;
    esac
done

if [ "$KERNEL_MODE" = "manual" ]; then
    KERNEL_CONFIG_PATH=$(ask "$(t kernel_config_prompt)" "")
    if [ -n "$KERNEL_CONFIG_PATH" ]; then
        [ -f "$KERNEL_CONFIG_PATH" ] || die "Arquivo de config '$KERNEL_CONFIG_PATH' não encontrado."
        mkdir -p "$ROOT_MNT/root"
        cp "$KERNEL_CONFIG_PATH" "$ROOT_MNT/root/kernel.config"
        log "Config copiado para dentro do chroot (será aplicado com 'make olddefconfig')."
    fi
fi

BOOTLOADER_PKG="grub"

# ==================================================================
# 10. Script que roda dentro do chroot
# ==================================================================
step "$(t step_genscript)"
cat > "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF
#!/bin/bash
set -euo pipefail

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

log "Definindo layout de teclado do console: ${KEYMAP}"
if [ "${INIT_SYSTEM}" = "openrc" ]; then
    sed -i "s/^keymap=.*/keymap=\"${KEYMAP}\"/" /etc/conf.d/keymaps 2>/dev/null \
        || echo "keymap=\"${KEYMAP}\"" >> /etc/conf.d/keymaps
else
    echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
fi

log "Instalando firmware..."
emerge --ask=n sys-kernel/linux-firmware

CPU_VENDOR=\$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print \$NF}')
if [ "\$CPU_VENDOR" = "GenuineIntel" ]; then
    log "CPU Intel detectada, instalando sys-firmware/intel-microcode..."
    emerge --ask=n sys-firmware/intel-microcode
elif [ "\$CPU_VENDOR" = "AuthenticAMD" ]; then
    log "CPU AMD detectada: o microcode já vem embutido via sys-kernel/linux-firmware."
else
    warn "Não foi possível identificar o fabricante da CPU; pulando microcode dedicado."
fi

log "Instalando kernel (modo: ${KERNEL_MODE})..."
case "${KERNEL_MODE}" in
    bin)
        emerge --ask=n sys-kernel/gentoo-kernel-bin
        # o eclass dist-kernel já instala vmlinuz-*, os módulos e o
        # initramfs (via dracut) em /boot automaticamente no merge.
        ;;

    genkernel)
        emerge --ask=n sys-kernel/gentoo-sources sys-kernel/genkernel
        log "Selecionando fonte do kernel instalada..."
        eselect kernel list
        eselect kernel set 1
        log "Compilando kernel com genkernel (pode demorar bastante)..."
        genkernel --install all \
            || die "genkernel falhou. Rode 'genkernel --install all' manualmente no chroot para ver o log completo."
        ;;

    manual)
        emerge --ask=n sys-kernel/gentoo-sources sys-kernel/genkernel
        log "Selecionando fonte do kernel instalada..."
        eselect kernel list
        eselect kernel set 1
        cd /usr/src/linux || die "Diretório /usr/src/linux não encontrado após eselect kernel."

        if [ -f /root/kernel.config ]; then
            log "Aplicando .config fornecido..."
            cp /root/kernel.config .config
            make olddefconfig
        else
            log "Abrindo make menuconfig — configure e salve (Save > Exit) para continuar."
            make menuconfig
        fi

        log "Compilando kernel (\$(nproc) jobs)..."
        make -j\$(nproc) || die "Falha ao compilar o kernel. Rode 'make' manualmente em /usr/src/linux para ver o erro completo."

        log "Instalando módulos..."
        make modules_install || die "Falha em 'make modules_install'."

        log "Instalando vmlinuz, System.map e config em /boot..."
        make install || die "Falha em 'make install'. Confira se /boot está montado."

        KVER=\$(make -s kernelrelease)
        log "Gerando initramfs para o kernel \$KVER (necessário se algum driver de disco/storage foi compilado como módulo)..."
        genkernel --kernel-config=/usr/src/linux/.config --no-clean initramfs \
            || warn "Falha ao gerar o initramfs. Se todo o driver de disco estiver embutido (=y) no .config, isso não é obrigatório; caso contrário, rode 'genkernel initramfs' manualmente antes de reiniciar."
        ;;

    *)
        die "Modo de kernel desconhecido: ${KERNEL_MODE}"
        ;;
esac

log "Conferindo arquivos gerados em /boot..."
if ls /boot | grep -qE '^(vmlinuz|kernel)-'; then
    log "Kernel encontrado em /boot:"
    ls -la /boot | grep -E '^-.*(vmlinuz|kernel|initramfs|initrd|System.map)'
else
    warn "Não encontrei vmlinuz/kernel-* em /boot. O bootloader não vai ter o que carregar — confira antes de reiniciar."
fi

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

    if [ -d /sys/firmware/efi ] && ! mountpoint -q /sys/firmware/efi/efivars; then
        log "Montando efivarfs..."
        mount -t efivarfs efivarfs /sys/firmware/efi/efivars \
            || warn "Não foi possível montar efivarfs; grub-install pode falhar."
    fi

    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GENTOO --recheck \
        || die "grub-install falhou (UEFI). Confira se a partição EFI (vfat) está montada em /boot e se efivarfs está disponível."

    # Fallback removable: alguns firmwares (comum em VMs e algumas placas)
    # ignoram a entrada criada no NVRAM e só respeitam o caminho padrão
    # \\EFI\\BOOT\\BOOTX64.EFI. Copiamos para lá também, sem custo nenhum.
    if [ -f /boot/EFI/GENTOO/grubx64.efi ]; then
        mkdir -p /boot/EFI/BOOT
        cp /boot/EFI/GENTOO/grubx64.efi /boot/EFI/BOOT/BOOTX64.EFI \
            || warn "Não foi possível criar o fallback removable BOOTX64.EFI."
        log "Fallback removable criado em /boot/EFI/BOOT/BOOTX64.EFI."
    fi

    if command -v efibootmgr >/dev/null 2>&1; then
        log "Entradas de boot UEFI atuais:"
        efibootmgr -v || warn "efibootmgr não conseguiu listar as entradas (comum em algumas VMs sem suporte a NVRAM)."
    fi
else
    grub-install --target=i386-pc "${DISK}" \
        || die "grub-install falhou (BIOS legacy) no disco ${DISK}. Confira se sobrou espaço (~1MiB) antes da primeira partição para o core.img."
fi

grub-mkconfig -o /boot/grub/grub.cfg \
    || die "grub-mkconfig falhou ao gerar /boot/grub/grub.cfg."

[ -s /boot/grub/grub.cfg ] || die "/boot/grub/grub.cfg foi gerado vazio, algo deu errado."
log "grub.cfg gerado com sucesso."

log "Defina a senha de root:"
passwd

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
    emerge --ask=n net-misc/dhcpcd app-admin/sysklogd sys-process/cronie
    rc-update add dhcpcd default
    rc-update add sysklogd default
    rc-update add cronie default
    rc-update add sshd default 2>/dev/null || true

    if [ "${VARIANT}" = "desktop" ]; then
        log "Variante desktop: instalando e habilitando dbus..."
        emerge --ask=n sys-apps/dbus
        rc-update add dbus default
    fi
else
    log "Habilitando serviços systemd básicos..."
    systemctl enable systemd-networkd
    systemctl enable systemd-resolved
    systemctl enable sshd 2>/dev/null || true

    log "Configurando DHCP via systemd-networkd..."
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/20-wired.network <<'NET_EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
NET_EOF

    log "Apontando /etc/resolv.conf para o systemd-resolved..."
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    if [ "${VARIANT}" = "desktop" ]; then
        log "Variante desktop: dbus já é ativado automaticamente via socket no systemd."
    fi
fi
CHROOT_EOF

if [ "$X11_CHOSEN" -eq 1 ]; then
    cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Instalando driver libinput (mouse, teclado e touchpad) para o X11..."
emerge --ask=n x11-drivers/xf86-input-libinput
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/30-touchpad.conf <<'TOUCHPAD_EOF'
Section "InputClass"
    Identifier "libinput touchpad"
    MatchIsTouchpad "on"
    Driver "libinput"
    Option "Tapping" "on"
    Option "NaturalScrolling" "true"
EndSection

Section "InputClass"
    Identifier "libinput pointer"
    MatchIsPointer "on"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "libinput keyboard"
    MatchIsKeyboard "on"
    Driver "libinput"
    Option "XkbLayout" "${KEYMAP%%-*}"
EndSection
TOUCHPAD_EOF
CHROOT_EOF
fi

if [ "$CONFIGURE_WIFI" -eq 1 ]; then
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Configurando WiFi ($WIFI_SSID em $WIFI_IFACE)..."
emerge --ask=n net-wireless/wpa_supplicant
mkdir -p /etc/wpa_supplicant
CHROOT_EOF
        if [ -n "$WIFI_PASS" ]; then
            echo "wpa_passphrase \"$WIFI_SSID\" \"$WIFI_PASS\" > /etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf" \
                >> "$ROOT_MNT/root/chroot-setup.sh"
        else
            cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF
cat > /etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf <<'WPA_EOF'
network={
    ssid="$WIFI_SSID"
    key_mgmt=NONE
}
WPA_EOF
CHROOT_EOF
        fi
        cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF
ln -sf net.lo /etc/init.d/net.${WIFI_IFACE}
{
    echo "modules_${WIFI_IFACE}=\"wpa_supplicant\""
    echo "config_${WIFI_IFACE}=\"dhcp\""
} >> /etc/conf.d/net
rc-update add net.${WIFI_IFACE} default
log "WiFi configurado. A interface ${WIFI_IFACE} vai conectar automaticamente no boot."
CHROOT_EOF
    else
        cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Configurando WiFi ($WIFI_SSID em $WIFI_IFACE)..."
emerge --ask=n net-wireless/wpa_supplicant
mkdir -p /etc/wpa_supplicant
CHROOT_EOF
        if [ -n "$WIFI_PASS" ]; then
            echo "wpa_passphrase \"$WIFI_SSID\" \"$WIFI_PASS\" > /etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf" \
                >> "$ROOT_MNT/root/chroot-setup.sh"
        else
            cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF
cat > /etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf <<'WPA_EOF'
network={
    ssid="$WIFI_SSID"
    key_mgmt=NONE
}
WPA_EOF
CHROOT_EOF
        fi
        cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF
systemctl enable wpa_supplicant@${WIFI_IFACE}.service
cat > /etc/systemd/network/25-wireless.network <<'NET_EOF'
[Match]
Name=${WIFI_IFACE}

[Network]
DHCP=yes
NET_EOF
log "WiFi configurado. A interface ${WIFI_IFACE} vai conectar automaticamente no boot."
CHROOT_EOF
    fi
fi

cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Etapa dentro do chroot concluída."
CHROOT_EOF

chmod +x "$ROOT_MNT/root/chroot-setup.sh"

# ==================================================================
# 11. Entrando no chroot e executando
# ==================================================================
step "$(t step_enterchroot)"
chroot "$ROOT_MNT" /bin/bash /root/chroot-setup.sh || die "Falha durante a configuração no chroot."

# ==================================================================
# 12. Pós-instalação: chroot manual, reiniciar, desligar ou sair
# ==================================================================
cleanup_mounts() {
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
}

step "$(t step_installdone)"
rm -f "$ROOT_MNT/root/chroot-setup.sh"

while true; do
    echo
    opt "1) Entrar no chroot (shell interativo para ajustes manuais)"
    opt "2) Reiniciar"
    opt "3) Desligar"
    opt "4) Sair (desmontar tudo e encerrar o script)"
    opt=$(ask "$(t finalmenu_prompt)")
    case "$opt" in
        1)
            log "Entrando no chroot interativo. Digite 'exit' para voltar a este menu."
            chroot "$ROOT_MNT" /bin/bash || warn "O chroot terminou com erro."
            ;;
        2)
            cleanup_mounts
            log "Reiniciando..."
            reboot
            break
            ;;
        3)
            cleanup_mounts
            log "Desligando..."
            poweroff
            break
            ;;
        4)
            cleanup_mounts
            log "Gentoo instalado em $DISK. Filesystems desmontados."
            break
            ;;
        *) warn "Opção inválida." ;;
    esac
done
