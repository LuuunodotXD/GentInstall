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
    read -rp "$(echo -e "${C_BOLD}$1${C_RESET} [y/N]: ")" reply
    [[ "$reply" =~ ^[yY]$ ]]
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
EN_COVERAGE=80

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
# -2. Bem-vindo / Welcome
# ==================================================================
echo -e "${C_BLUE} Welcome to GenInstall, the Gentoo Installer that sucks never!${C_RESET}"
echo -e "${C_BLUE} This solution was written in ShellScript by LuuunoXD.${C_RESET}"
echo -e "${C_BLUE} All content in this script is in the public domain under the Unlicense.${C_RESET}"
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
MSGS[pt:dev_prompt]="Dispositivo da partição (ex: %s1) ou 'end' para terminar"
MSGS[en:dev_prompt]="Partition device (e.g: %s1) or 'end' to finish"
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

MSGS[pt:continue_anyway]="Continuar mesmo assim?"
MSGS[en:continue_anyway]="Continue anyway?"
MSGS[pt:testing_connectivity]="Testando conectividade..."
MSGS[en:testing_connectivity]="Testing connectivity..."
MSGS[pt:connectivity_fail_warn]="Não consegui alcançar distfiles.gentoo.org. Verifique a rede (dhcpcd, net-setup, wpa_supplicant, etc)."
MSGS[en:connectivity_fail_warn]="Couldn't reach distfiles.gentoo.org. Check the network (dhcpcd, net-setup, wpa_supplicant, etc)."
MSGS[pt:disk_type_warn]="%s parece ser uma partição (tipo: %s), não um disco inteiro. Isso provavelmente é um erro de digitação."
MSGS[en:disk_type_warn]="%s looks like a partition (type: %s), not a whole disk. This is probably a typo."
MSGS[pt:opt_uefi]="1) UEFI (recomendado em máquinas modernas)"
MSGS[en:opt_uefi]="1) UEFI (recommended on modern machines)"
MSGS[pt:opt_bios]="2) BIOS legado / MBR"
MSGS[en:opt_bios]="2) Legacy BIOS / MBR"
MSGS[pt:bootmode_selected_log]="Modo de boot selecionado: %s"
MSGS[en:bootmode_selected_log]="Boot mode selected: %s"
MSGS[pt:efi_warn]="O live media atual não parece estar rodando em modo EFI."
MSGS[en:efi_warn]="The current live media doesn't seem to be running in EFI mode."
MSGS[pt:skip_part_log]="Particionamento pulado. Usando as partições já existentes em %s."
MSGS[en:skip_part_log]="Partitioning skipped. Using the partitions that already exist on %s."
MSGS[pt:creating_label_log]="Criando tabela de partição %s em %s..."
MSGS[en:creating_label_log]="Creating %s partition table on %s..."
MSGS[pt:skip_label_log]="Criação automática da tabela pulada. Mantendo a tabela de partição existente em %s."
MSGS[en:skip_label_log]="Automatic table creation skipped. Keeping the existing partition table on %s."
MSGS[pt:opt_cfdisk]="1) cfdisk (interface ncurses simples)"
MSGS[en:opt_cfdisk]="1) cfdisk (simple ncurses interface)"
MSGS[pt:opt_fdisk]="2) fdisk (linha de comando, MBR/GPT)"
MSGS[en:opt_fdisk]="2) fdisk (command line, MBR/GPT)"
MSGS[pt:opt_parted]="3) parted (linha de comando, GPT recomendado)"
MSGS[en:opt_parted]="3) parted (command line, GPT recommended)"
MSGS[pt:opening_tool_log]="Abrindo %s em %s. Crie suas partições e salve antes de sair."
MSGS[en:opening_tool_log]="Opening %s on %s. Create your partitions and save before exiting."
MSGS[pt:pttype_uefi_warn]="A tabela de partição em %s é '%s', não 'gpt'. Boot UEFI normalmente exige GPT."
MSGS[en:pttype_uefi_warn]="The partition table on %s is '%s', not 'gpt'. UEFI boot normally requires GPT."
MSGS[pt:pttype_bios_warn]="A tabela de partição em %s é GPT, mas você escolheu boot BIOS legacy. Isso exige uma partição BIOS Boot (bios_grub) além da raiz, senão o grub-install falha."
MSGS[en:pttype_bios_warn]="The partition table on %s is GPT, but you chose legacy BIOS boot. That requires a BIOS Boot partition (bios_grub) besides root, or grub-install will fail."
MSGS[pt:added_part_log]="Adicionado: %s -> %s (%s)"
MSGS[en:added_part_log]="Added: %s -> %s (%s)"
MSGS[pt:esp_missing_warn]="Nenhuma partição vfat montada em /boot foi definida. Em UEFI, o GRUB precisa de uma ESP (vfat) em /boot para --efi-directory=/boot funcionar."
MSGS[en:esp_missing_warn]="No vfat partition mounted on /boot was defined. On UEFI, GRUB needs an ESP (vfat) on /boot for --efi-directory=/boot to work."
MSGS[pt:esp_small_warn]="A ESP (%s) tem só %sMiB. Recomendado pelo menos 260MiB para evitar problemas com alguns firmwares."
MSGS[en:esp_small_warn]="The ESP (%s) is only %sMiB. At least 260MiB is recommended to avoid issues with some firmwares."
MSGS[pt:mkfs_log]="%s %s"
MSGS[en:mkfs_log]="%s %s"
MSGS[pt:esp_flag_log]="Marcando %s (partição %s) com a flag esp..."
MSGS[en:esp_flag_log]="Marking %s (partition %s) with the esp flag..."
MSGS[pt:unknown_fs_die]="Filesystem desconhecido '%s' para %s."
MSGS[en:unknown_fs_die]="Unknown filesystem '%s' for %s."
MSGS[pt:root_mounted_log]="Raiz montada: %s -> %s"
MSGS[en:root_mounted_log]="Root mounted: %s -> %s"
MSGS[pt:mounted_log]="Montado: %s -> %s"
MSGS[en:mounted_log]="Mounted: %s -> %s"
MSGS[pt:opt_openrc]="1) openrc"
MSGS[en:opt_openrc]="1) openrc"
MSGS[pt:opt_systemd]="2) systemd"
MSGS[en:opt_systemd]="2) systemd"
MSGS[pt:opt_minimal]="1) minimal"
MSGS[en:opt_minimal]="1) minimal"
MSGS[pt:opt_desktop]="2) desktop"
MSGS[en:opt_desktop]="2) desktop"
MSGS[pt:opt_i686]="1) i686"
MSGS[en:opt_i686]="1) i686"
MSGS[pt:opt_i486]="2) i486"
MSGS[en:opt_i486]="2) i486"
MSGS[pt:invalid_arch_die]="Arquitetura inválida: %s"
MSGS[en:invalid_arch_die]="Invalid architecture: %s"
MSGS[pt:downloading_log]="Baixando: %s"
MSGS[en:downloading_log]="Downloading: %s"
MSGS[pt:extracting_log]="Extraindo stage3..."
MSGS[en:extracting_log]="Extracting stage3..."
MSGS[pt:cpu_detected_log]="CPU detectada: -march=%s"
MSGS[en:cpu_detected_log]="CPU detected: -march=%s"
MSGS[pt:march_detect_fail_warn]="Não deu pra detectar o modelo exato da CPU automaticamente (gcc ausente no live media, ou só reconheceu 'x86-64' genérico)."
MSGS[en:march_detect_fail_warn]="Couldn't auto-detect the exact CPU model (gcc missing on the live media, or it only recognized generic 'x86-64')."
MSGS[pt:cflags_set_log]="CFLAGS configuradas com -march=%s."
MSGS[en:cflags_set_log]="CFLAGS configured with -march=%s."
MSGS[pt:accept_license_log]="ACCEPT_LICENSE=\"*\" adicionado (necessário para microcode/firmware não-livres)."
MSGS[en:accept_license_log]="ACCEPT_LICENSE=\"*\" added (needed for non-free microcode/firmware)."
MSGS[pt:grub_platforms_log]="GRUB_PLATFORMS definido para o modo de boot (%s)."
MSGS[en:grub_platforms_log]="GRUB_PLATFORMS set for the boot mode (%s)."
MSGS[pt:opt_x11]="1) X11 (Xorg)"
MSGS[en:opt_x11]="1) X11 (Xorg)"
MSGS[pt:opt_wayland]="2) Wayland"
MSGS[en:opt_wayland]="2) Wayland"
MSGS[pt:opt_pipewire]="1) PipeWire"
MSGS[en:opt_pipewire]="1) PipeWire"
MSGS[pt:opt_pulseaudio]="2) PulseAudio"
MSGS[en:opt_pulseaudio]="2) PulseAudio"
MSGS[pt:opt_libinput]="1) libinput (recomendado, moderno, cobre mouse/teclado/touchpad)"
MSGS[en:opt_libinput]="1) libinput (recommended, modern, covers mouse/keyboard/touchpad)"
MSGS[pt:opt_evdev]="2) evdev + synaptics (driver antigo, separado por tipo de dispositivo)"
MSGS[en:opt_evdev]="2) evdev + synaptics (older driver, split by device type)"
MSGS[pt:detecting_gpu_log]="Detectando placa de vídeo..."
MSGS[en:detecting_gpu_log]="Detecting graphics card..."
MSGS[pt:gpu_detected_log]="GPU detectada com confiança: %s"
MSGS[en:gpu_detected_log]="GPU detected with confidence: %s"
MSGS[pt:use_flags_log]="USE flags definidas: %s"
MSGS[en:use_flags_log]="USE flags set: %s"
MSGS[pt:video_cards_log]="VIDEO_CARDS definidas: %s"
MSGS[en:video_cards_log]="VIDEO_CARDS set: %s"
MSGS[pt:input_devices_log]="INPUT_DEVICES definidas: %s (mouse, teclado e touchpad)"
MSGS[en:input_devices_log]="INPUT_DEVICES set: %s (mouse, keyboard and touchpad)"
MSGS[pt:opt_sudo]="1) sudo"
MSGS[en:opt_sudo]="1) sudo"
MSGS[pt:opt_doas]="2) doas (com persist — não pede senha de novo por um tempo, como sudo)"
MSGS[en:opt_doas]="2) doas (with persist — doesn't ask for the password again for a while, like sudo)"
MSGS[pt:wifi_skip_log]="Configuração de WiFi pulada. A rede cabeada (DHCP) já é habilitada por padrão."
MSGS[en:wifi_skip_log]="WiFi configuration skipped. Wired networking (DHCP) is already enabled by default."
MSGS[pt:opt_kernel_bin]="1) gentoo-kernel-bin (binário pré-compilado — mais rápido, módulos e initramfs prontos)"
MSGS[en:opt_kernel_bin]="1) gentoo-kernel-bin (precompiled binary — faster, modules and initramfs already set up)"
MSGS[pt:opt_kernel_genkernel]="2) genkernel (compila da fonte, configuração automática)"
MSGS[en:opt_kernel_genkernel]="2) genkernel (compiles from source, automatic configuration)"
MSGS[pt:opt_kernel_manual]="3) fonte manual (gentoo-sources + make menuconfig, você controla o .config)"
MSGS[en:opt_kernel_manual]="3) manual source (gentoo-sources + make menuconfig, you control the .config)"
MSGS[pt:kernel_config_copied_log]="Config copiado para dentro do chroot (será aplicado com 'make olddefconfig')."
MSGS[en:kernel_config_copied_log]="Config copied into the chroot (will be applied with 'make olddefconfig')."
MSGS[pt:unmounting_log]="Desmontando filesystems..."
MSGS[en:unmounting_log]="Unmounting filesystems..."
MSGS[pt:opt_chroot]="1) Entrar no chroot (shell interativo para ajustes manuais)"
MSGS[en:opt_chroot]="1) Enter the chroot (interactive shell for manual tweaks)"
MSGS[pt:opt_reboot]="2) Reiniciar"
MSGS[en:opt_reboot]="2) Reboot"
MSGS[pt:opt_poweroff]="3) Desligar"
MSGS[en:opt_poweroff]="3) Power off"
MSGS[pt:opt_exit]="4) Sair (desmontar tudo e encerrar o script)"
MSGS[en:opt_exit]="4) Exit (unmount everything and end the script)"
MSGS[pt:entering_chroot_log]="Entrando no chroot interativo. Digite 'exit' para voltar a este menu."
MSGS[en:entering_chroot_log]="Entering the interactive chroot. Type 'exit' to return to this menu."
MSGS[pt:rebooting_log]="Reiniciando..."
MSGS[en:rebooting_log]="Rebooting..."
MSGS[pt:poweroff_log]="Desligando..."
MSGS[en:poweroff_log]="Powering off..."
MSGS[pt:install_finished_log]="Gentoo instalado em %s. Filesystems desmontados."
MSGS[en:install_finished_log]="Gentoo installed on %s. Filesystems unmounted."


# ==================================================================
# 0. Checagens iniciais
# ==================================================================
step "$(t step_checks)"
require_root

for tool in curl tar chroot blkid lsblk mkswap; do
    command -v "$tool" >/dev/null 2>&1 || die "Ferramenta obrigatória '$tool' não encontrada no live media."
done

log "$(t testing_connectivity)"
if ! curl -fsSL --max-time 5 -o /dev/null https://distfiles.gentoo.org; then
    warn "$(t connectivity_fail_warn)"
    confirm "$(t continue_anyway)" || die "Instalação abortada."
fi

# ==================================================================
# 1. Seleção de disco
# ==================================================================
step "$(t step_disk)"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E 'disk$'
DISK=$(ask "$(t disk_prompt)")
[ -b "$DISK" ] || die "Dispositivo $DISK não encontrado."

DISK_TYPE=$(lsblk -no TYPE "$DISK" 2>/dev/null | head -n1)
if [ "$DISK_TYPE" != "disk" ]; then
    warn "$(tf disk_type_warn "$DISK" "${DISK_TYPE:-desconhecido}")"
    confirm "$(t continue_anyway)" || die "Instalação abortada."
fi

warn "$(tf disk_wipe_warn "$DISK")"
confirm "$(tf confirm_continue_disk "$DISK")" || die "Instalação abortada pelo usuário."

# ==================================================================
# 2. Modo de boot
# ==================================================================
step "$(t step_bootmode)"
opt "$(t opt_uefi)"
opt "$(t opt_bios)"
while true; do
    opt=$(ask "$(t bootmode_prompt)")
    case "$opt" in
        1) BOOT_MODE="uefi"; break ;;
        2) BOOT_MODE="bios"; break ;;
        *) warn "$(t opt_invalid)" ;;
    esac
done
log "$(tf bootmode_selected_log "$BOOT_MODE")"

if [ "$BOOT_MODE" = "uefi" ] && [ ! -d /sys/firmware/efi ]; then
    warn "$(t efi_warn)"
    confirm "$(t continue_anyway)" || die "Instalação abortada."
fi

if [ "$BOOT_MODE" = "uefi" ]; then
    SECUREBOOT_STATE=""
    if command -v mokutil >/dev/null 2>&1; then
        mokutil --sb-state 2>/dev/null | grep -qi "enabled" && SECUREBOOT_STATE="enabled"
    elif [ -d /sys/firmware/efi/efivars ]; then
        sb_var=$(find /sys/firmware/efi/efivars -maxdepth 1 -iname 'SecureBoot-*' 2>/dev/null | head -n1)
        if [ -n "$sb_var" ]; then
            # o 5º byte do arquivo é o valor: 1 = habilitado, 0 = desabilitado
            sb_byte=$(od -An -tu1 -j4 -N1 "$sb_var" 2>/dev/null | tr -d ' ')
            [ "$sb_byte" = "1" ] && SECUREBOOT_STATE="enabled"
        fi
    fi
    if [ "$SECUREBOOT_STATE" = "enabled" ]; then
        warn "Secure Boot está ATIVADO na firmware. O GRUB do Gentoo não vem assinado por padrão e não vai bootar com Secure Boot ligado."
        warn "Desative o Secure Boot na BIOS/UEFI antes de reiniciar, ou configure shim+chaves MOK depois (fora do escopo deste script)."
        confirm "$(t continue_anyway)" || die "Instalação abortada."
    fi
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
    log "$(tf skip_part_log "$DISK")"
else
    if confirm "$(tf create_label_confirm "$DISK_LABEL" "$DISK")"; then
        command -v parted >/dev/null 2>&1 || die "parted não está disponível para criar a tabela de partição."

        [ "$BOOT_MODE" = "bios" ] && warn "Legacy BIOS: deixe pelo menos 1MiB de espaço livre antes da primeira partição (o GRUB embute o core.img nesse gap). As ferramentas modernas já alinham em 1MiB por padrão, então normalmente não precisa se preocupar."

        log "$(tf creating_label_log "$DISK_LABEL" "$DISK")"
        parted -s "$DISK" mklabel "$DISK_LABEL" || die "Falha ao criar a tabela de partição $DISK_LABEL."
    else
        log "$(tf skip_label_log "$DISK")"
    fi

    opt "$(t opt_cfdisk)"
    opt "$(t opt_fdisk)"
    opt "$(t opt_parted)"
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

    log "$(tf opening_tool_log "$PART_TABLE_TOOL" "$DISK")"
    sleep 1
    "$PART_TABLE_TOOL" "$DISK"
fi

# Detecta a tabela de partição atual e avisa sobre incompatibilidade com o boot mode escolhido
CURRENT_PTTYPE=$(blkid -o value -s PTTYPE "$DISK" 2>/dev/null || true)
if [ "$BOOT_MODE" = "uefi" ] && [ "$CURRENT_PTTYPE" != "gpt" ]; then
    warn "$(tf pttype_uefi_warn "$DISK" "${CURRENT_PTTYPE:-desconhecida}")"
    confirm "$(t continue_anyway)" || die "Instalação abortada."
elif [ "$BOOT_MODE" = "bios" ] && [ "$CURRENT_PTTYPE" = "gpt" ]; then
    warn "$(tf pttype_bios_warn "$DISK")"
    confirm "$(t continue_anyway)" || die "Instalação abortada."
fi

lsblk "$DISK"

# ==================================================================
# 4. Definição de filesystem e mountpoint por partição
# ==================================================================
step "$(t step_fsmount)"
echo "Informe cada partição criada. Digite 'end' no campo do dispositivo para encerrar."
echo "Filesystems suportados: ext4, btrfs, xfs, vfat, swap"
echo

while true; do
    dev=$(ask "$(tf dev_prompt "$DISK")")
    [ "$dev" = "end" ] && break
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
    log "$(tf added_part_log "$dev" "$mnt" "$fstype")"
done

[ "${#PARTS[@]}" -gt 0 ] || die "Nenhuma partição definida. Abortando."

# Detecta dispositivo ou mountpoint repetido (erro comum de digitação)
seen_devs=" "
seen_mnts=" "
for p in "${PARTS[@]}"; do
    IFS=':' read -r dev mnt _ <<< "$p"
    case "$seen_devs" in *" $dev "*) die "Dispositivo $dev foi informado mais de uma vez." ;; esac
    if [ "$mnt" != "swap" ]; then
        case "$seen_mnts" in *" $mnt "*) die "Mountpoint $mnt foi informado mais de uma vez." ;; esac
        seen_mnts="$seen_mnts$mnt "
    fi
    seen_devs="$seen_devs$dev "
done

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
        warn "$(t esp_missing_warn)"
        confirm "$(t continue_anyway)" || die "Instalação abortada."
    else
        esp_size_bytes=$(blockdev --getsize64 "$esp_dev" 2>/dev/null || echo 0)
        esp_size_mib=$(( esp_size_bytes / 1024 / 1024 ))
        if [ "$esp_size_mib" -gt 0 ] && [ "$esp_size_mib" -lt 100 ]; then
            warn "$(tf esp_small_warn "$esp_dev" "$esp_size_mib")"
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
        ext4)
            log "$(tf mkfs_log "mkfs.ext4" "$dev")"
            mkfs.ext4 -F "$dev" || die "Falha ao formatar $dev como ext4."
            ;;
        btrfs)
            log "$(tf mkfs_log "mkfs.btrfs" "$dev")"
            mkfs.btrfs -f "$dev" || die "Falha ao formatar $dev como btrfs."
            ;;
        xfs)
            log "$(tf mkfs_log "mkfs.xfs" "$dev")"
            mkfs.xfs -f "$dev" || die "Falha ao formatar $dev como xfs."
            ;;
        vfat)
            log "$(tf mkfs_log "mkfs.vfat" "$dev")"
            mkfs.vfat -F32 "$dev" || die "Falha ao formatar $dev como vfat."
            if [ "$BOOT_MODE" = "uefi" ] && [ "$mnt" = "/boot" ]; then
                partnum=$(echo "$dev" | grep -o '[0-9]*$')
                if [ -n "$partnum" ]; then
                    log "$(tf esp_flag_log "$dev" "$partnum")"
                    parted -s "$DISK" set "$partnum" esp on 2>/dev/null \
                        || warn "Não foi possível marcar a flag esp em $dev automaticamente; confira com 'parted $DISK print'."
                fi
            fi
            ;;
        swap)
            log "$(tf mkfs_log "mkswap" "$dev")"
            mkswap "$dev" || die "Falha ao preparar swap em $dev."
            swapon "$dev" || die "Falha ao ativar swap em $dev."
            ;;
        *)
            die "$(tf unknown_fs_die "$fstype" "$dev")"
            ;;
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
        log "$(tf root_mounted_log "$dev" "$ROOT_MNT")"
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
    log "$(tf mounted_log "$dev" "${ROOT_MNT}${mnt}")"
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

if [ "$ARCH" = "arm64" ] && [ "$BOOT_MODE" = "bios" ]; then
    die "arm64 não suporta BIOS legado (não existe BIOS em hardware ARM) — reinicie o script e escolha UEFI no modo de boot."
fi

case "$ARCH" in
    amd64|arm64)
        opt "$(t opt_openrc)"
        opt "$(t opt_systemd)"
        while true; do
            opt=$(ask "$(t init_prompt)")
            case "$opt" in
                1) INIT_SYSTEM="openrc"; break ;;
                2) INIT_SYSTEM="systemd"; break ;;
                *) warn "Opção inválida." ;;
            esac
        done

        opt "$(t opt_minimal)"
        opt "$(t opt_desktop)"
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
        opt "$(t opt_openrc)"
        opt "$(t opt_systemd)"
        while true; do
            opt=$(ask "$(t init_prompt)")
            case "$opt" in
                1) INIT_SYSTEM="openrc"; break ;;
                2) INIT_SYSTEM="systemd"; break ;;
                *) warn "Opção inválida." ;;
            esac
        done

        opt "$(t opt_i686)"
        opt "$(t opt_i486)"
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
        die "$(tf invalid_arch_die "$ARCH")"
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

log "$(tf downloading_log "$STAGE3_URL")"
cd "$ROOT_MNT" || die "Não foi possível acessar $ROOT_MNT"
curl -fL -o stage3.tar.xz "$STAGE3_URL" || die "Falha no download do stage3."

log "$(t extracting_log)"
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
MARCH_VALUE=""
if confirm "$(t march_confirm)"; then
    MARCH_CHOICE="native"
    DETECTED_MARCH=""
    if command -v gcc >/dev/null 2>&1; then
        DETECTED_MARCH=$(gcc -march=native -Q --help=target 2>/dev/null | awk '/^[[:space:]]*-march=/{print $2; exit}')
    fi
    if [ -n "$DETECTED_MARCH" ] && [ "$DETECTED_MARCH" != "native" ] && [ "$DETECTED_MARCH" != "x86-64" ]; then
        log "$(tf cpu_detected_log "$DETECTED_MARCH")"
        MARCH_VALUE=$(ask "Valor de -march (detectado automaticamente; troque para 'native' se preferir)" "$DETECTED_MARCH")
    else
        warn "$(t march_detect_fail_warn)"
        if [ "$ARCH" = "arm64" ]; then
            MARCH_VALUE=$(ask "Digite o valor de -march/-mcpu manualmente (ex: armv8-a, cortex-a72, neoverse-n1, ou 'native' — veja /proc/cpuinfo)" "native")
        else
            MARCH_VALUE=$(ask "Digite o valor de -march manualmente (ex: skylake, alderlake, znver3, ou 'native' — veja /proc/cpuinfo ou 'gcc -march=native -Q --help=target' se tiver gcc)" "native")
        fi
    fi
fi

if ! grep -q '^MAKEOPTS' "$MAKE_CONF" 2>/dev/null; then
    echo "MAKEOPTS=\"-j${NPROC}\"" >> "$MAKE_CONF"
fi
if ! grep -q '^EMERGE_DEFAULT_OPTS' "$MAKE_CONF" 2>/dev/null; then
    echo "EMERGE_DEFAULT_OPTS=\"--jobs=$(( NPROC > 2 ? NPROC/2 : 1 )) --load-average=${NPROC}\"" >> "$MAKE_CONF"
fi

if [ "$MARCH_CHOICE" = "native" ] && [ -n "$MARCH_VALUE" ]; then
    if grep -q '^COMMON_FLAGS' "$MAKE_CONF" 2>/dev/null; then
        sed -i "s/^COMMON_FLAGS=.*/COMMON_FLAGS=\"-march=${MARCH_VALUE} -O2 -pipe\"/" "$MAKE_CONF"
    else
        echo "COMMON_FLAGS=\"-march=${MARCH_VALUE} -O2 -pipe\"" >> "$MAKE_CONF"
    fi
    log "$(tf cflags_set_log "$MARCH_VALUE")"
fi

# Sem isso, o emerge do intel-microcode/linux-firmware para no meio pedindo
# aceite de licença manual, o que trava um script não-interativo.
if ! grep -q '^ACCEPT_LICENSE' "$MAKE_CONF" 2>/dev/null; then
    echo 'ACCEPT_LICENSE="*"' >> "$MAKE_CONF"
    log "$(t accept_license_log)"
fi

# GRUB_PLATFORMS precisa bater com o modo de boot escolhido, senão o
# sys-boot/grub é compilado sem o target certo e o grub-install falha.
if ! grep -q '^GRUB_PLATFORMS' "$MAKE_CONF" 2>/dev/null; then
    if [ "$BOOT_MODE" = "uefi" ]; then
        if [ "$ARCH" = "x86" ]; then
            echo 'GRUB_PLATFORMS="efi-32"' >> "$MAKE_CONF"
        else
            echo 'GRUB_PLATFORMS="efi-64"' >> "$MAKE_CONF"
        fi
    else
        echo 'GRUB_PLATFORMS="pc"' >> "$MAKE_CONF"
    fi
    log "$(tf grub_platforms_log "$BOOT_MODE")"
fi

step "$(t step_useflags)"
USE_FLAGS=""
VIDEO_CARDS_VALUE=""
INPUT_DEVICES_VALUE=""
INPUT_DRIVER_MODE=""
X11_CHOSEN=0

if [ "$INIT_SYSTEM" = "openrc" ]; then
    USE_FLAGS="elogind -systemd"
else
    USE_FLAGS="systemd -elogind"
fi

KEYMAP_DEFAULT="us"
[ "$LANG_CHOICE" = "pt" ] && KEYMAP_DEFAULT="br-abnt2"
KEYMAP=$(ask "Layout de teclado do console (ex: us, br-abnt2, de, dvorak — qualquer nome válido de 'kbd')" "$KEYMAP_DEFAULT")

if [ "${VARIANT:-}" = "desktop" ]; then
    opt "$(t opt_x11)"
    opt "$(t opt_wayland)"
    while true; do
        opt=$(ask "$(t display_prompt)")
        case "$opt" in
            1) USE_FLAGS="$USE_FLAGS X -wayland"; X11_CHOSEN=1; break ;;
            2) USE_FLAGS="$USE_FLAGS wayland -X"; break ;;
            *) warn "Opção inválida." ;;
        esac
    done

    opt "$(t opt_pipewire)"
    opt "$(t opt_pulseaudio)"
    while true; do
        opt=$(ask "$(t audio_prompt)")
        case "$opt" in
            1) USE_FLAGS="$USE_FLAGS pipewire -pulseaudio"; break ;;
            2) USE_FLAGS="$USE_FLAGS pulseaudio -pipewire"; break ;;
            *) warn "Opção inválida." ;;
        esac
    done

    # INPUT_DEVICES só é relevante pra X11 (drivers do Xorg); Wayland usa
    # libinput direto via compositor, sem precisar dessa variável.
    INPUT_DRIVER_MODE=""
    if [ "$X11_CHOSEN" -eq 1 ]; then
        opt "$(t opt_libinput)"
        opt "$(t opt_evdev)"
        while true; do
            iopt=$(ask "Driver de input para mouse/teclado/touchpad (1/2)")
            case "$iopt" in
                1) INPUT_DEVICES_VALUE="libinput"; INPUT_DRIVER_MODE="libinput"; USE_FLAGS="$USE_FLAGS libinput"; break ;;
                2) INPUT_DEVICES_VALUE="evdev synaptics"; INPUT_DRIVER_MODE="evdev_synaptics"; break ;;
                *) warn "Opção inválida." ;;
            esac
        done
    fi

    log "$(t detecting_gpu_log)"
    GPU_INFO=$(lspci -nnk 2>/dev/null | grep -Ei 'vga|3d|display' || true)
    [ -n "$GPU_INFO" ] && echo "$GPU_INFO"
    DETECTED_VIDEO_CARDS=""
    GPU_MATCHES=0
    if echo "$GPU_INFO" | grep -qi intel; then
        DETECTED_VIDEO_CARDS="i915 intel"; GPU_MATCHES=$((GPU_MATCHES + 1))
    fi
    if echo "$GPU_INFO" | grep -qi amd; then
        DETECTED_VIDEO_CARDS="amdgpu radeonsi radeon"; GPU_MATCHES=$((GPU_MATCHES + 1))
    fi
    if echo "$GPU_INFO" | grep -qi nvidia; then
        DETECTED_VIDEO_CARDS="nouveau"; GPU_MATCHES=$((GPU_MATCHES + 1))
    fi
    if echo "$GPU_INFO" | grep -qiE 'virtio|qxl|vmware|bochs|cirrus'; then
        DETECTED_VIDEO_CARDS="virtio qxl vmware fbdev"; GPU_MATCHES=$((GPU_MATCHES + 1))
    fi

    if [ "$GPU_MATCHES" -eq 1 ]; then
        log "$(tf gpu_detected_log "$DETECTED_VIDEO_CARDS")"
        VIDEO_CARDS_VALUE=$(ask "$(t videocards_prompt)" "$DETECTED_VIDEO_CARDS")
    else
        [ "$GPU_MATCHES" -gt 1 ] && warn "Mais de um fabricante de GPU detectado (setup híbrido/multi-GPU?); informe manualmente pra não errar o valor."
        if [ "$GPU_MATCHES" -eq 0 ]; then
            warn "Não consegui detectar a GPU automaticamente."
            if [ "$ARCH" = "arm64" ]; then
                warn "Em placas ARM a GPU geralmente não aparece via PCI (é integrada via device tree). Valores comuns: panfrost (Mali), lima (Mali antiga), vc4+v3d (Raspberry Pi), fbdev (genérico)."
            fi
        fi
        VIDEO_CARDS_VALUE=$(ask "$(t videocards_prompt)" "")
    fi
fi

if ! grep -q '^USE=' "$MAKE_CONF" 2>/dev/null; then
    echo "USE=\"${USE_FLAGS}\"" >> "$MAKE_CONF"
else
    sed -i "s/^USE=\"/USE=\"${USE_FLAGS} /" "$MAKE_CONF"
fi
log "$(tf use_flags_log "$USE_FLAGS")"

if [ -n "$VIDEO_CARDS_VALUE" ]; then
    if ! grep -q '^VIDEO_CARDS=' "$MAKE_CONF" 2>/dev/null; then
        echo "VIDEO_CARDS=\"${VIDEO_CARDS_VALUE}\"" >> "$MAKE_CONF"
    fi
    log "$(tf video_cards_log "$VIDEO_CARDS_VALUE")"
fi

if [ -n "$INPUT_DEVICES_VALUE" ]; then
    if ! grep -q '^INPUT_DEVICES=' "$MAKE_CONF" 2>/dev/null; then
        echo "INPUT_DEVICES=\"${INPUT_DEVICES_VALUE}\"" >> "$MAKE_CONF"
    fi
    log "$(tf input_devices_log "$INPUT_DEVICES_VALUE")"
fi

step "Copiando resolv.conf"
cp --dereference /etc/resolv.conf "$ROOT_MNT/etc/" || warn "Não foi possível copiar resolv.conf."

step "Montando filesystems virtuais"
mount --types proc /proc "$ROOT_MNT/proc" || die "Falha ao montar /proc."
mount --rbind /sys "$ROOT_MNT/sys" || die "Falha ao montar /sys."
mount --make-rslave "$ROOT_MNT/sys" || die "Falha em 'mount --make-rslave' em /sys."
mount --rbind /dev "$ROOT_MNT/dev" || die "Falha ao montar /dev."
mount --make-rslave "$ROOT_MNT/dev" || die "Falha em 'mount --make-rslave' em /dev."
mount --bind /run "$ROOT_MNT/run" 2>/dev/null || true
mount --make-slave "$ROOT_MNT/run" 2>/dev/null || true

# ==================================================================
# 9. Coleta de dados para dentro do chroot
# ==================================================================
step "$(t step_finalconfig)"
HOSTNAME=$(ask "$(t hostname_prompt)" "gentoo")
TIMEZONE=$(ask "$(t timezone_prompt)" "America/Fortaleza")
LOCALE_DEFAULT="pt_BR.UTF-8 UTF-8"
[ "$LANG_CHOICE" = "en" ] && LOCALE_DEFAULT="en_US.UTF-8 UTF-8"
LOCALE_GEN=$(ask "$(t locale_prompt)" "$LOCALE_DEFAULT")
NEW_USER=$(ask "$(t newuser_prompt)")

PRIV_TOOL="sudo"
if [ -n "$NEW_USER" ]; then
    opt "$(t opt_sudo)"
    opt "$(t opt_doas)"
    while true; do
        popt=$(ask "Ferramenta de escalonamento de privilégio (1/2)" "1")
        case "$popt" in
            1|"") PRIV_TOOL="sudo"; break ;;
            2) PRIV_TOOL="doas"; break ;;
            *) warn "$(t opt_invalid)" ;;
        esac
    done
fi

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
    log "$(t wifi_skip_log)"
fi

step "$(t step_kernel)"
opt "$(t opt_kernel_bin)"
opt "$(t opt_kernel_genkernel)"
opt "$(t opt_kernel_manual)"
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
        log "$(t kernel_config_copied_log)"
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

log "Verificando news items do Portage..."
NEWS_COUNT=\$(eselect news count new 2>/dev/null || echo 0)
if [ "\${NEWS_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    log "\$NEWS_COUNT news item(ns) novo(s):"
    eselect news list 2>/dev/null || true
    log "Marcando os news items como lidos (eselect news read all)..."
    eselect news read all >/dev/null 2>&1 || warn "Não consegui marcar os news items como lidos; rode 'eselect news read' manualmente depois."
else
    log "Nenhum news item novo."
fi

log "Selecionando perfil..."
eselect profile list
log "Perfil atual: \$(eselect profile show 2>/dev/null | tail -n1)"
read -rp "Número do perfil a usar (Enter para manter o atual): " profile_choice
if [ -n "\$profile_choice" ]; then
    eselect profile set "\$profile_choice" || warn "Não foi possível definir o perfil \$profile_choice; mantendo o atual."
fi

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
emerge --ask=n --autounmask-write --autounmask-continue sys-kernel/linux-firmware

CPU_VENDOR=\$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print \$NF}')
if [ "\$CPU_VENDOR" = "GenuineIntel" ]; then
    log "CPU Intel detectada, instalando sys-firmware/intel-microcode..."
    emerge --ask=n --autounmask-write --autounmask-continue sys-firmware/intel-microcode
elif [ "\$CPU_VENDOR" = "AuthenticAMD" ]; then
    log "CPU AMD detectada: o microcode já vem embutido via sys-kernel/linux-firmware."
elif [ "\$(uname -m)" = "aarch64" ]; then
    log "CPU ARM detectada: não existe microcode dedicado no mesmo formato do x86 (não se aplica)."
else
    warn "Não foi possível identificar o fabricante da CPU; pulando microcode dedicado."
fi

log "Instalando kernel (modo: ${KERNEL_MODE})..."
case "${KERNEL_MODE}" in
    bin)
        # gentoo-kernel-bin[initramfs] exige sys-kernel/installkernel com a
        # USE dracut habilitada; sem isso o emerge trava pedindo autounmask.
        mkdir -p /etc/portage/package.use
        echo "sys-kernel/installkernel dracut" > /etc/portage/package.use/installkernel
        emerge --ask=n --autounmask-write --autounmask-continue sys-kernel/gentoo-kernel-bin \
            || die "Falha ao instalar sys-kernel/gentoo-kernel-bin. Rode 'emerge sys-kernel/gentoo-kernel-bin' manualmente para ver o erro completo."
        # o eclass dist-kernel já instala vmlinuz-*, os módulos e o
        # initramfs (via dracut) em /boot automaticamente no merge.
        ;;

    genkernel)
        emerge --ask=n --autounmask-write --autounmask-continue sys-kernel/gentoo-sources sys-kernel/genkernel
        log "Selecionando fonte do kernel instalada..."
        eselect kernel list
        eselect kernel set 1
        log "Compilando kernel com genkernel (pode demorar bastante)..."
        genkernel --install all \
            || die "genkernel falhou. Rode 'genkernel --install all' manualmente no chroot para ver o log completo."
        ;;

    manual)
        emerge --ask=n --autounmask-write --autounmask-continue sys-kernel/gentoo-sources sys-kernel/genkernel
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

# Target e nomes de arquivo do GRUB EFI variam por arquitetura
GRUB_EFI_TARGET="x86_64-efi"
EFI_GRUB_BIN="grubx64.efi"
EFI_FALLBACK_NAME="BOOTX64.EFI"
if [ "$ARCH" = "arm64" ]; then
    GRUB_EFI_TARGET="arm64-efi"
    EFI_GRUB_BIN="grubaa64.efi"
    EFI_FALLBACK_NAME="BOOTAA64.EFI"
elif [ "$ARCH" = "x86" ]; then
    GRUB_EFI_TARGET="i386-efi"
    EFI_GRUB_BIN="grubia32.efi"
    EFI_FALLBACK_NAME="BOOTIA32.EFI"
fi

cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Instalando bootloader ($BOOTLOADER_PKG)..."
emerge --ask=n --autounmask-write --autounmask-continue sys-boot/grub

if [ "${BOOT_MODE}" = "uefi" ]; then
    emerge --ask=n --autounmask-write --autounmask-continue sys-boot/efibootmgr

    if [ -d /sys/firmware/efi ] && ! mountpoint -q /sys/firmware/efi/efivars; then
        log "Montando efivarfs..."
        mount -t efivarfs efivarfs /sys/firmware/efi/efivars \
            || warn "Não foi possível montar efivarfs; grub-install pode falhar."
    fi

    grub-install --target=${GRUB_EFI_TARGET} --efi-directory=/boot --bootloader-id=GENTOO --recheck \
        || die "grub-install falhou (UEFI). Confira se a partição EFI (vfat) está montada em /boot e se efivarfs está disponível."

    # Fallback removable: alguns firmwares (comum em VMs e algumas placas)
    # ignoram a entrada criada no NVRAM e só respeitam o caminho padrão
    # \\EFI\\BOOT\\${EFI_FALLBACK_NAME}. Copiamos para lá também, sem custo nenhum.
    if [ -f /boot/EFI/GENTOO/${EFI_GRUB_BIN} ]; then
        mkdir -p /boot/EFI/BOOT
        cp /boot/EFI/GENTOO/${EFI_GRUB_BIN} /boot/EFI/BOOT/${EFI_FALLBACK_NAME} \
            || warn "Não foi possível criar o fallback removable ${EFI_FALLBACK_NAME}."
        log "Fallback removable criado em /boot/EFI/BOOT/${EFI_FALLBACK_NAME}."
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
    EXTRA_GROUPS="users,wheel"
    for g in audio video tty usb input; do
        getent group "\$g" >/dev/null 2>&1 || groupadd "\$g" 2>/dev/null || true
        getent group "\$g" >/dev/null 2>&1 && EXTRA_GROUPS="\$EXTRA_GROUPS,\$g"
    done
    useradd -m -G "\$EXTRA_GROUPS" -s /bin/bash "${NEW_USER}" || die "Falha ao criar o usuário ${NEW_USER}."
    echo "Defina a senha para ${NEW_USER}:"
    passwd "${NEW_USER}"
CHROOT_EOF

if [ "$PRIV_TOOL" = "doas" ]; then
    cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF
    log "Instalando doas (com persist)..."
    mkdir -p /etc/portage/package.use
    echo "app-admin/doas persist" > /etc/portage/package.use/doas
    emerge --ask=n --autounmask-write --autounmask-continue app-admin/doas
    echo "permit persist :wheel" > /etc/doas.conf
    chown root:root /etc/doas.conf
    chmod 0400 /etc/doas.conf
    log "doas configurado. Uso: 'doas comando' (grupo wheel, com persist)."
CHROOT_EOF
else
    cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF
    log "Instalando sudo..."
    emerge --ask=n --autounmask-write --autounmask-continue app-admin/sudo
    mkdir -p /etc/sudoers.d
    echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
    chown root:root /etc/sudoers.d/wheel
    chmod 0440 /etc/sudoers.d/wheel
    visudo -cf /etc/sudoers.d/wheel || die "Sintaxe inválida em /etc/sudoers.d/wheel."
CHROOT_EOF
fi

cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF
fi

if [ "${INIT_SYSTEM}" = "openrc" ]; then
    log "Configurando serviços OpenRC básicos..."
    emerge --ask=n --autounmask-write --autounmask-continue net-misc/dhcpcd app-admin/sysklogd sys-process/cronie
    rc-update add dhcpcd default
    rc-update add sysklogd default
    rc-update add cronie default
    rc-update add sshd default 2>/dev/null || true

    if [ "${VARIANT}" = "desktop" ]; then
        log "Variante desktop: instalando e habilitando dbus..."
        emerge --ask=n --autounmask-write --autounmask-continue sys-apps/dbus
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

cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Aplicando hardening básico de sysctl..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-hardening.conf <<'SYSCTL_EOF'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.suid_dumpable = 0
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1
SYSCTL_EOF
CHROOT_EOF

if [ -n "$NEW_USER" ]; then
    cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Desabilitando login de root por senha via SSH (existe o usuário ${NEW_USER} para isso)..."
if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
fi
CHROOT_EOF
else
    cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

warn "Nenhum usuário normal foi criado; login de root por senha via SSH continua permitido. Considere criar um usuário e trocar PermitRootLogin em /etc/ssh/sshd_config depois."
CHROOT_EOF
fi

if [ "$X11_CHOSEN" -eq 1 ] && [ "$INPUT_DRIVER_MODE" = "libinput" ]; then
    cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Instalando driver libinput (mouse, teclado e touchpad) para o X11..."
emerge --ask=n --autounmask-write --autounmask-continue x11-drivers/xf86-input-libinput
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
elif [ "$X11_CHOSEN" -eq 1 ] && [ "$INPUT_DRIVER_MODE" = "evdev_synaptics" ]; then
    cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Instalando drivers evdev (mouse/teclado) e synaptics (touchpad) para o X11..."
emerge --ask=n --autounmask-write --autounmask-continue x11-drivers/xf86-input-evdev x11-drivers/xf86-input-synaptics
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/30-touchpad.conf <<'TOUCHPAD_EOF'
Section "InputClass"
    Identifier "synaptics touchpad"
    MatchIsTouchpad "on"
    Driver "synaptics"
    Option "TapButton1" "1"
    Option "VertEdgeScroll" "on"
EndSection

Section "InputClass"
    Identifier "evdev pointer"
    MatchIsPointer "on"
    Driver "evdev"
EndSection

Section "InputClass"
    Identifier "evdev keyboard"
    MatchIsKeyboard "on"
    Driver "evdev"
    Option "XkbLayout" "${KEYMAP%%-*}"
EndSection
TOUCHPAD_EOF
CHROOT_EOF
fi

if [ "$CONFIGURE_WIFI" -eq 1 ]; then
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        cat >> "$ROOT_MNT/root/chroot-setup.sh" <<CHROOT_EOF

log "Configurando WiFi ($WIFI_SSID em $WIFI_IFACE)..."
emerge --ask=n --autounmask-write --autounmask-continue net-wireless/wpa_supplicant
mkdir -p /etc/wpa_supplicant
chmod 700 /etc/wpa_supplicant
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
chmod 600 /etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf
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
emerge --ask=n --autounmask-write --autounmask-continue net-wireless/wpa_supplicant
mkdir -p /etc/wpa_supplicant
chmod 700 /etc/wpa_supplicant
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
chmod 600 /etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf
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

log "Checando news items novos do Portage (podem ter surgido durante a instalação)..."
NEWS_COUNT_FINAL=\$(eselect news count new 2>/dev/null || echo 0)
if [ "\${NEWS_COUNT_FINAL:-0}" -gt 0 ] 2>/dev/null; then
    log "\$NEWS_COUNT_FINAL news item(ns) pendente(s). Abrindo para leitura (pressione 'q' pra sair do pager):"
    eselect news read || warn "Não consegui abrir os news items; rode 'eselect news read' manualmente depois."
else
    log "Nenhum news item novo."
fi

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
    log "$(t unmounting_log)"
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
    opt "$(t opt_chroot)"
    opt "$(t opt_reboot)"
    opt "$(t opt_poweroff)"
    opt "$(t opt_exit)"
    opt=$(ask "$(t finalmenu_prompt)")
    case "$opt" in
        1)
            log "$(t entering_chroot_log)"
            chroot "$ROOT_MNT" /bin/bash || warn "O chroot terminou com erro."
            ;;
        2)
            cleanup_mounts
            log "$(t rebooting_log)"
            reboot
            break
            ;;
        3)
            cleanup_mounts
            log "$(t poweroff_log)"
            poweroff
            break
            ;;
        4)
            cleanup_mounts
            log "$(tf install_finished_log "$DISK")"
            break
            ;;
        *) warn "Opção inválida." ;;
    esac
done
