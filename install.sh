#!/bin/bash

# Získání potřebných informací
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
echo -e "\nZadejte jméno nového uživatele:\n"
read user

echo -e "\nZadejte heslo pro $user:\n"
read -s uspw

echo -e "\nZadejte heslo pro root uživatele:\n"
read -s rtpw

echo -e "\nNázev zařízení (hostname):\n"
read host

echo -e "\nDoména (example.cz):\n"
read domain

echo -e "\nZadejte požadovanou časovou zónu ve formátu Country/Region (např. Europe/Prague):\n"
read tmzn

iname=$(ls -1 /sys/class/net | grep -i en) # hledání síťového rozhraní

# Síťová konfigurace
echo -e "\nChcete použít DHCP pro síť? (y/n)"
read -r dhcp_choice

if [[ "$dhcp_choice" =~ ^[Yy]$ ]]; then
    dhcp=true
    ipv4_address=""
    ipv4_gateway=""
    ipv6_address=""
    ipv6_gateway=""
else
    dhcp=false
    echo -e "Zadejte IPv4 adresu a masku (0.0.0.0/0):"
    read -r ipv4_address
    echo -e "Zadejte bránu pro IPv4:"
    read -r ipv4_gateway
    echo -e "Zadejte IPv6 adresu a masku (0::/0) (nevyplňujte pro vynechání):"
    read -r ipv6_address
    if [[ -n "$ipv6_address" ]]; then
        echo -e "Zadejte bránu pro IPv6:"
        read -r ipv6_gateway
    else
        ipv6_gateway=""
    fi
fi

# Dotazy na DNS
echo -e "\nChcete nastavit DNS servery? (y/n)"
read -r dns_choice

if [[ "$dns_choice" =~ ^[Yy]$ ]]; then
    echo -e "Zadejte DNS server pro IPv4:"
    read -r ipv4_dns
    echo -e "Zadejte DNS server pro IPv6 (nevyplňujte pro vynechání):"
    read -r ipv6_dns
else
    ipv4_dns=""
    ipv6_dns=""
fi

# Dotaz na DNS server (např. AdGuard, Pi-hole)
echo -e "\nBude tento server poskytovat DNS služby (např. AdGuard, Pi-hole)? (y/n)"
read -r dns_server_choice

# Dotaz na instalaci yay-bin (AUR helper)
echo -e "\nChcete nainstalovat yay-bin (AUR helper) pro instalaci balíčků z AUR? (y/n)"
read -r install_yay

# Uložení konfigurace do souboru pro použití ve skriptu
cat <<EOF > ./confidentials
user=$user
uspw=$uspw
rtpw=$rtpw
host=$host
domain=$domain
tmzn=$tmzn
iname=$iname
dhcp=$dhcp
ipv4_address=$ipv4_address
ipv4_gateway=$ipv4_gateway
ipv6_address=$ipv6_address
ipv6_gateway=$ipv6_gateway
ipv4_dns=$ipv4_dns
ipv6_dns=$ipv6_dns
dns_server_choice=$dns_server_choice
install_yay=$install_yay
EOF

echo -e "\nKonfigurace uložena. Začínáme s instalací...\n"
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

# Začátek instalace
# Smazání existujícího disku
wipefs --all /dev/sda

# Vytvoření oddílů
sgdisk -n 0:0:+512M -t 0:ef00 /dev/sda
sgdisk -n 0:0:0 -t 0:8300 /dev/sda

# Formátování oddílů
mkfs.fat -F 32 /dev/sda1
mkfs.ext4 -F /dev/sda2

echo -e "\nHotovo.\n\n"

# Nastavení NTP
timedatectl set-ntp true

# Nastavení pacman konfigurace
sed -i 's/#Color/Color/; s/#ParallelDownloads/ParallelDownloads/; s/#\[multilib\]/\[multilib\]/; /\[multilib\]/{n;s/#Include/Include/}' /etc/pacman.conf

# Mount oddílů
mount /dev/sda2 /mnt
mount --mkdir /dev/sda1 /mnt/EFI

# Instalace balíčků
pacman-key --init
pacman-key --populate archlinux
pacman -Sy --noconfirm -S archlinux-keyring
pacstrap /mnt $(cat pkgs | sed 's/#.*$//' | tr '\n' ' ')

# Generování FSTab
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/relatime/relatime,discard/g' /mnt/etc/fstab

# Nastavení Pacman konfigurace a aktualizací (pro nový systém)
sed -i 's/#Color/Color/; s/#ParallelDownloads/ParallelDownloads/; s/#\[multilib\]/\[multilib\]/; /\[multilib\]/{n;s/#Include/Include/}' /mnt/etc/pacman.conf
arch-chroot /mnt pacman -Syyu --noconfirm

# Nastavení časové zóny na $tmzn...
ln -sf /usr/share/zoneinfo/$tmzn /mnt/etc/localtime
arch-chroot /mnt hwclock --systohc

# Konfigurace vconsole...
echo -e "KEYMAP=cz-qwertz\nFONT=lat2-16\nFONT_MAP=8859-2" > /mnt/etc/vconsole.conf

# Konfigurace Locale...
sed -i 's/#cs_CZ.UTF-8/cs_CZ.UTF-8/; s/#en_US.UTF-8/en_US.UTF-8/' /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo -e "LANG=cs_CZ.UTF-8" > /mnt/etc/locale.conf

# sed -i 's/Current=/Current=breeze/' /mnt/usr/lib/sddm/sddm.conf.d/default.conf

# Nastavení hostname a domény...
echo "$host" > /mnt/etc/hostname
cat <<EOF > /mnt/etc/hosts
127.0.0.1   localhost $host $host.$domain
::1         localhost $host $host.$domain
127.0.1.1   $host.$domain $host
EOF

# Konfigurace síťového rozhraní $iname...
network_config_file="/mnt/etc/systemd/network/10-$iname.network"
cat <<EOF > $network_config_file
[Match]
Name=$iname

[Network]
EOF
if [[ "$dhcp" == "true" ]]; then
    echo "DHCP=yes" >> $network_config_file
else
    echo "Address=$ipv4_address" >> $network_config_file
    echo "Gateway=$ipv4_gateway" >> $network_config_file
    [[ -n "$ipv6_address" ]] && echo "Address=$ipv6_address" >> $network_config_file
    [[ -n "$ipv6_gateway" ]] && echo "Gateway=$ipv6_gateway" >> $network_config_file
fi

if [[ -n "$ipv4_dns" || -n "$ipv6_dns" ]]; then
    echo "DNS=$ipv4_dns" >> $network_config_file
    [[ -n "$ipv6_dns" ]] && echo "DNS=$ipv6_dns" >> $network_config_file
fi

# Nastavení DNS služeb...
resolved_conf="/mnt/etc/systemd/resolved.conf"

# Vytvoření symbolického odkazu
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf 

if [[ "$dns_server_choice" =~ ^[Yy]$ ]]; then
    # Přepsání /etc/resolv.conf vlastními DNS servery
    echo -e "nameserver $ipv4_dns" > /mnt/etc/resolv.conf
    [[ -n "$ipv6_dns" ]] && echo "nameserver $ipv6_dns" >> /mnt/etc/resolv.conf
    
    # Úprava resolved.conf pro vypnutí DNSStubListener
    sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' $resolved_conf
fi

if [[ -n "$ipv4_dns" || -n "$ipv6_dns" ]]; then
    # Ošetření proměnných pro případ prázdné IPv4 nebo IPv6
    dns_values="${ipv4_dns}${ipv4_dns:+ }${ipv6_dns}"
    
    # Použití dvojitých uvozovek pro správné nahrazení proměnných
    sed -i "s|#DNS=|DNS=$dns_values|" "$resolved_conf"
fi

# Nastavení hesla pro root...
echo "root:$rtpw" | arch-chroot /mnt chpasswd

# Vytváření uživatele $user a nastavení shellu na /bin/bash...
arch-chroot /mnt useradd -m -G wheel -s /bin/bash $user
echo "$user:$uspw" | arch-chroot /mnt chpasswd
echo -e "%wheel ALL=(ALL) ALL \n$user ALL=NOPASSWD: ALL \n" > /mnt/etc/sudoers.d/00_nopasswd

# Instalace yay-bin (AUR helper) pokud požadováno...
if [[ "$install_yay" =~ ^[Yy]$ ]]; then
    arch-chroot /mnt su - $user -c "git clone https://aur.archlinux.org/yay-bin.git"
    arch-chroot /mnt su - $user -c "cd yay-bin && makepkg -si --noconfirm"
fi

# Zapnutí systemd služeb...
arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved qemu-guest-agent.service sshd # sddm NetworkManager

# Generování initramfs pro linux-lts jádro...
arch-chroot /mnt mkinitcpio -P linux-lts

# Konfigurace Bootloaderu (GRUB)...
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/EFI --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Odstraňování dočasných souborů...
rm -f ./confidentials

# Odpojení
umount -a

# Restart systému
echo -e "\nInstalace dokončena. Systém se restartuje za 5 vteřin..."
sleep 5
reboot
