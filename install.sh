#!/bin/bash
# WARNING: this script will destroy data on the selected disk.
# This script can be run by executing the following:
#   curl -sL https://git.io/vNxbN | bash
set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

REPO_URL="https://s3-eu-west-1.amazonaws.com/couldinho-arch-aur/x86_64"

### Get infomation from user ###
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter admin username" 0 0) || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter admin password" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Enter admin password again" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

passphrase=$(dialog --stdout --passwordbox "Enter passphrase for encrypted volume" 0 0) || exit 1
clear
: ${passphrase:?"passphrase cannot be empty"}
passphrase2=$(dialog --stdout --passwordbox "Enter passphrase for encrypted volume again" 0 0) || exit 1
clear
[[ "$passphrase" == "$passphrase2" ]] || ( echo "Passphrases did not match"; exit 1; )

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1
clear

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

timedatectl set-ntp true

### Setup the disk and partitions ###
echo "[*] Setting up partitions"
swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
swap_end=$(( $swap_size + 129 + 1 ))MiB

parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib 129MiB \
  set 1 boot on \
  mkpart primary linux-swap 129MiB ${swap_end} \
  mkpart primary ${swap_end} 100%

# Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1
# but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
part_swap="$(ls ${device}* | grep -E "^${device}p?2$")"
part_root="$(ls ${device}* | grep -E "^${device}p?3$")"

wipefs "${part_boot}"
wipefs "${part_swap}"
wipefs "${part_root}"

mkfs.vfat -F32 "${part_boot}"
mkswap "${part_swap}"
echo -n ${passphrase} | cryptsetup luksFormat "${part_root}"
echo -n ${passphrase} | cryptsetup luksOpen "${part_root}" luks
mkfs.btrfs -L btrfs /dev/mapper/luks

swapon "${part_swap}"

# Set up the BTRFS subvolumes
mount /dev/mapper/luks /mnt
btrfs subvolume create /mnt/root
btrfs subvolume create /mnt/home
btrfs subvolume create /mnt/pkgs
btrfs subvolume create /mnt/logs
btrfs subvolume create /mnt/tmp
btrfs subvolume create /mnt/snapshots
umount /mnt

mount -o noatime,nodiratime,discard,compress=lzo,subvol=root /dev/mapper/luks /mnt
mkdir -p /mnt/{mnt/btrfs-root,boot/efi,home,var/{cache/pacman,log,tmp},.snapshots}
mount "${part_boot}" /mnt/boot/efi
mount -o noatime,nodiratime,discard,compress=lzo,subvol=/ /dev/mapper/luks /mnt/mnt/btrfs-root
mount -o noatime,nodiratime,discard,compress=lzo,subvol=home /dev/mapper/luks /mnt/home
mount -o noatime,nodiratime,discard,compress=lzo,subvol=pkgs /dev/mapper/luks /mnt/var/cache/pacman
mount -o noatime,nodiratime,discard,compress=lzo,subvol=logs /dev/mapper/luks /mnt/var/log
mount -o noatime,nodiratime,discard,compress=lzo,subvol=tmp /dev/mapper/luks /mnt/var/tmp
mount -o noatime,nodiratime,discard,compress=lzo,subvol=snapshots /dev/mapper/luks /mnt/.snapshots

### Set up encrypted key for booting ###
echo "[*] Creating an encrypted key for booting"
dd bs=512 count=4 if=/dev/urandom of=/mnt/crypto_keyfile.bin
chmod 000 /mnt/crypto_keyfile.bin
echo -n ${passphrase} | cryptsetup luksAddKey ${part_root} /mnt/crypto_keyfile.bin

### Install and configure the basic system ###
echo "[*] Installing packages"
cat >>/etc/pacman.d/couldinho-arch-aur <<EOF
[options]
CacheDir = /var/cache/pacman/pkg
CacheDir = /var/cache/pacman/couldinho-arch-aur

[couldinho-arch-aur]
Server = $REPO_URL
SigLevel = Optional TrustAll
EOF

cat >>/etc/pacman.conf <<EOF
Include = /etc/pacman.d/couldinho-arch-aur
EOF

pacstrap /mnt couldinho-desktop

### Generate config files ###
echo "[*] Generating base config files"
genfstab -t PARTUUID /mnt >> /mnt/etc/fstab
echo "${hostname}" > /mnt/etc/hostname
echo "FONT=ter-112n" > /mnt/etc/vconsole.conf
echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
echo "en_IE.UTF-8 UTF-8" >> /mnt/etc/locale.gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "LC_MONETARY=en_IE.UTF-8" >> /mnt/etc/locale.conf
ln -sf /usr/share/zoneinfo/Europe/Dublin /mnt/etc/localtime
chmod 600 /mnt/boot/initramfs-linux*
sed -i "s|#PART_ROOT#|${part_root}|g" /mnt/etc/default/grub

echo "[*] Creating user and shell"
arch-chroot /mnt useradd -mU -s /usr/bin/zsh -G wheel,uucp,video,audio,storage,games,input "$user"
arch-chroot /mnt chsh -s /usr/bin/zsh
arch-chroot /mnt locale-gen

echo "[*] Installing grub"
arch-chroot /mnt grub-install
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

echo "[*] Cloning dotfiles to home folder"
git clone https://github.com/kontax/dotfiles.git /mnt/home/$user/dotfiles

echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt
echo "[*] DONE - Install setup from HOME/dotfiles"

