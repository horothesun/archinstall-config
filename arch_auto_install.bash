#!/bin/bash
# uncomment to view debugging information 
set -xeuo pipefail

# check if we're root
if [[ "$UID" -ne 0 ]]; then
    echo "This script needs to be run as root!" >&2
    exit 3
fi

# config options
TARGET="/dev/sda"
LOCALE="en_GB.UTF-8"
KEYMAP="uk"
TIMEZONE="Europe/London"
HOSTNAME="archlinux01"
USERNAME="user"

# SHA512 hash of password. To generate, run 'mkpasswd -m sha-512' (install `whois` package), don't forget to prefix any $ symbols with \
# the entry below is the hash of 'password'
USER_PASSWORD="\$6\$/VBa6GuBiFiBmi6Q\$yNALrCViVtDDNjyGBsDG7IbnNR0Y/Tda5Uz8ToyxXXpw86XuCVAlhXlIvzy1M8O.DWFB6TRCia0hMuAJiXOZy/"
ROOT_MNT="/mnt"

# to fully automate the setup, change BAD_IDEA=no to yes, and enter a cleartext password for the disk encryption 
BAD_IDEA="no"
CRYPT_PASSWORD="changeme"

# packages to pacstrap
PACSTRAP_PACKAGES=(
        amd-ucode
        base
	brtfs-progs
        cryptsetup
        dosfstools
        efibootmgr
	grub
	grub-btrfs
        linux
        linux-firmware
        networkmanager
        sbctl
        sudo
        util-linux
)
PACMAN_PACKAGES=(
        alacritty
        alsa-utils
        asciiquarium
        bash-completion
        bash-language-server
        bat
        btop
        cmatrix
        dive
        fastfetch
        figlet
        firefox
	firewalld
        fzf
        git
        github-cli
        git-filter-repo
	ipset
	iptables-nft
        jq
        lolcat
        man-db
        man-pages
	mtools
        ncdu
        neovim
        noto-fonts-emoji
	openssh
        plocate
        pipewire
        pipewire-jack
        pipewire-pulse
        python-cookiecutter
        speedtest-cli
        starship
        stow
        tldr
        translate-shell
        tree
        ttf-jetbrains-mono-nerd
        ttf-firacode-nerd
        yq
        )    
### Desktop packages #####
#HYPRLAND_PACKAGES=(
#        hyprpolkitagent
#        kwalletmanager
#        kwallet-pam
#        waybar
#        )
GUI_PACKAGES=(
        xfce4
        xfce4-terminal
        xfce4-goodies
        sddm
        nm-connection-editor
        mousepad
        )
#GUI_PACKAGES=(
#         plasma 
#         sddm 
#         kitty
#         nm-connection-editor
#         mousepad
#        )

# set locale, timezone, NTP
loadkeys "${KEYMAP}"
timedatectl set-timezone "${TIMEZONE}"
timedatectl set-ntp true

echo "Creating partitions..."
sgdisk -Z "${TARGET}"
# ef00: EFI System
# 8304: Linux x86-64 root (/)
sgdisk \
    -n1:0:+1G -t1:ef00 -c1:EFI \
    -N2       -t2:8304 -c2:linux \
    "${TARGET}"
sleep 2
echo
# reload partition table
partprobe -s "${TARGET}"
sleep 2
echo

echo "Encrypting root partition..."
# if BAD_IDEA=yes, then pipe cryptpass and carry on, if not, prompt for it
if [[ "${BAD_IDEA}" == "yes" ]]; then
    echo -n "${CRYPT_PASSWORD}" | cryptsetup luksFormat --type luks2 "/dev/disk/by-partlabel/linux" -
    echo -n "${CRYPT_PASSWORD}" | cryptsetup luksOpen "/dev/disk/by-partlabel/linux" root -
else
    cryptsetup luksFormat --type luks2 "/dev/disk/by-partlabel/linux"
    cryptsetup luksOpen "/dev/disk/by-partlabel/linux" root
fi
echo

echo "Making File Systems..."
# create file systems
mkfs.vfat -F32 -n EFI "/dev/disk/by-partlabel/EFI"
mkfs.btrfs -f -L linux /dev/mapper/root
# mount the root, and create + mount the EFI directory
echo "Mounting File Systems..."
mount "/dev/mapper/root" "${ROOT_MNT}"
mkdir "${ROOT_MNT}/efi" -p
mount -t vfat "/dev/disk/by-partlabel/EFI" "${ROOT_MNT}/efi"
echo
echo "Create BTRFS subvolumes..."
cd "${ROOT_MNT}"
btrfs subvolume create @
btrfs subvolume create @home
btrfs subvolume create /opt
btrfs subvolume create /srv
btrfs subvolume create /var/cache
btrfs subvolume create /var/lib/libvirt/images
btrfs subvolume create /var/log
btrfs subvolume create /var/spool
btrfs subvolume create /var/tmp
cd -
echo

# inspect filesystem changes
lsblk
echo
blkid
echo

# update pacman mirrors and then pacstrap base install
echo "Pacstrapping..."
reflector --country GB --age 24 --protocol http,https --sort rate --save "/etc/pacman.d/mirrorlist"
pacstrap -K "${ROOT_MNT}" "${PACSTRAP_PACKAGES[@]}" 
echo

# generate filesystem table
#genfstab -U -p "${ROOT_MNT}" >> /mnt/etc/fstab
cat /mnt/etc/fstab
echo

echo "Setting up environment..."
# set up locale/env: add our locale to locale.gen
sed -i -e "/^#"${LOCALE}"/s/^#//" "${ROOT_MNT}/etc/locale.gen"
# remove any existing config files that may have been pacstrapped, systemd-firstboot will then regenerate them
rm "${ROOT_MNT}"/etc/{machine-id,localtime,hostname,shadow,locale.conf} ||
systemd-firstboot \
    --root "${ROOT_MNT}" \
    --keymap="${KEYMAP}" \
    --locale="${LOCALE}" \
    --locale-messages="${LOCALE}" \
    --timezone="${TIMEZONE}" \
    --hostname="${HOSTNAME}" \
    --setup-machine-id \
    --welcome=false
arch-chroot "${ROOT_MNT}" locale-gen
echo

echo "Configuring for first boot..."
# add the local user
arch-chroot "${ROOT_MNT}" useradd -G wheel -m -p "${USER_PASSWORD}" "${USERNAME}" 
# uncomment the wheel group in the sudoers file
sed -i -e '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' "${ROOT_MNT}/etc/sudoers"
# create a basic kernel cmdline, we're using DPS so we don't need to have anything here really,
# but if the file doesn't exist, mkinitcpio will complain
echo "quiet rw" > "${ROOT_MNT}/etc/kernel/cmdline"
# change the HOOKS in mkinitcpio.conf to use systemd hooks
sed -i \
    -e 's/base udev/base systemd/g' \
    -e 's/keymap consolefont/sd-vconsole sd-encrypt/g' \
    "${ROOT_MNT}/etc/mkinitcpio.conf"
# change the preset file to generate a Unified Kernel Image instead of an initram disk + kernel
sed -i \
    -e '/^#ALL_config/s/^#//' \
    -e '/^#default_uki/s/^#//' \
    -e '/^#default_options/s/^#//' \
    -e 's/default_image=/#default_image=/g' \
    -e "s/PRESETS=('default' 'fallback')/PRESETS=('default')/g" \
    "${ROOT_MNT}/etc/mkinitcpio.d/linux.preset"
echo

# read the UKI setting and create the folder structure otherwise mkinitcpio will crash
declare $(grep default_uki "${ROOT_MNT}/etc/mkinitcpio.d/linux.preset")
arch-chroot "${ROOT_MNT}" mkdir -p "$(dirname "${default_uki//\"}")"
echo

echo "Enable pacman multilib repository..."
sed -i -e '/#\[multilib\]/,+1s/^#//' "${ROOT_MNT}/etc/pacman.conf"
echo

echo "Installing base packages..."
arch-chroot "${ROOT_MNT}" pacman -Sy "${PACMAN_PACKAGES[@]}" --noconfirm --quiet
echo

echo "Installing GUI..."
arch-chroot "${ROOT_MNT}" pacman -Sy "${GUI_PACKAGES[@]}" --noconfirm --quiet
echo

# enable the services we will need on start up
echo "Enabling services..."
systemctl --root "${ROOT_MNT}" enable systemd-resolved systemd-timesyncd NetworkManager sddm
# mask systemd-networkd as we will use NetworkManager instead
systemctl --root "${ROOT_MNT}" mask systemd-networkd
echo

# regenerate the ramdisk, this will create our UKI
echo "Generating UKI and installing Boot Loader..."
arch-chroot "${ROOT_MNT}" mkinitcpio -p linux
echo

echo "Setting up Secure Boot..."
if [[ "$(efivar -d --name 8be4df61-93ca-11d2-aa0d-00e098032b8c-SetupMode)" -eq 1 ]]; then
    arch-chroot "${ROOT_MNT}" sbctl create-keys
    arch-chroot "${ROOT_MNT}" sbctl enroll-keys --microsoft
    arch-chroot "${ROOT_MNT}" sbctl sign -s -o "/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi"
    arch-chroot "${ROOT_MNT}" sbctl sign -s "${default_uki//\"}"
else
    echo "Not in Secure Boot setup mode. Skipping..."
fi
echo

echo "GRUB setup..."
echo "Move grub/ from /efi"
arch-chroot "${ROOT_MNT}" ls -lah /efi
arch-chroot "${ROOT_MNT}" ls -lah /efi/grub
# remove grub from /efi
arch-chroot "${ROOT_MNT}" rm -rf /efi/grub
# check the arch boot-loader folder is missing from /efi/EFI
arch-chroot "${ROOT_MNT}" ls -lah /efi/EFI
# create grub
arch-chroot "${ROOT_MNT}" grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/boot --bootloader-id=arch
# check the arch boot-loader folder is now present in /efi/EFI
arch-chroot "${ROOT_MNT}" ls -lah /efi/EFI
# check the grubx64.efi boot-loader's been created
arch-chroot "${ROOT_MNT}" ls -lah /efi/EFI/arch
# check the grub/ folder is now present in /boot
arch-chroot "${ROOT_MNT}" ls -lah /boot
# check /boot/grub contains fonts/, grub.cfg, grubenv, locale/, themes/, x86_64-efi/
arch-chroot "${ROOT_MNT}" ls -lah /boot/grub
# if /boot/grub/grub.cfg is missing, create it and check again
arch-chroot "${ROOT_MNT}" grub-mkconfig -o /boot/grub/grub.cfg
arch-chroot "${ROOT_MNT}" ls -lah /boot/grub
# check the boot entry for Arch Linux has been created and its index is the first in the boot order
arch-chroot "${ROOT_MNT}" efibootmgr
echo

# install the systemd-boot bootloader
#arch-chroot "${ROOT_MNT}" bootctl install --esp-path=/efi

# lock the root account
arch-chroot "${ROOT_MNT}" usermod -L root
echo

echo "-----------------------------------"
echo "- Install complete. Please reboot -"
echo "-----------------------------------"
sleep 10
sync
echo
# reboot
