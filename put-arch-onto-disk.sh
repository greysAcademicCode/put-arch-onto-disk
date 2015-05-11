#!/usr/bin/env bash
set -e #break on error
set -vx #echo on

: ${ROOT_FS_TYPE:=f2fs}
: ${MAKE_SWAP_PARTITION:=false}
: ${SWAP_SIZE_IS_RAM_SIZE:=false}
: ${SWAP_SIZE:=100MiB}
: ${GET_SIZE_FROM_TARGET:=false}
: ${TARGET_DISK:=/dev/sdX}
: ${IMG_SIZE:=2GiB}
: ${IMG_NAME:=bootable_arch.img}
: ${TIME_ZONE:=Europe/Copenhagen}
: ${LANGUAGE:=en_US}
: ${TEXT_ENCODING:=UTF-8}
: ${ROOT_PASSWORD:=toor}
: ${MAKE_ADMIN_USER:=true}
: ${ADMIN_USER_NAME:=l3iggs}
: ${ADMIN_USER_PASSWORD:=sggi3l}
: ${THIS_HOSTNAME:=bootdisk}
: ${PACKAGE_LIST:=""}
: ${AUR_PACKAGE_LIST:=""}
: ${DD_TO_TARGET:=false}
: ${CLEAN_UP:=false}
: ${ENABLE_AUR:=true}
: ${TARGET_IS_REMOVABLE:=false}
: ${SUPPORT_UEFI:=false}

rm -f "${IMG_NAME}"
if [ "$GET_SIZE_FROM_TARGET" = true ] ; then
  DISK_INFO=$(lsblk -n -b -o SIZE,PHY-SEC ${TARGET_DISK})
  IFS=' ' read -a DISK_INFO_A <<< "$DISK_INFO"
  IMG_SIZE=$(numfmt --to-unit=K ${DISK_INFO_A[0]})KiB
  PHY_SEC_BYTES=${DISK_INFO_A[1]}
fi
fallocate -l $IMG_SIZE "${IMG_NAME}"
wipefs -a -f "${IMG_NAME}"

NEXT_PARTITION=1
[ "$SUPPORT_UEFI" = false ] && sgdisk -n 0:+0:+1MiB -t 0:ef02 -c 0:biosGrub "${IMG_NAME}" && ((NEXT_PARTITION++))
sgdisk -n 0:+0:+512MiB -t 0:ef00 -c 0:boot "${IMG_NAME}"; BOOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  if [ "$SWAP_SIZE_IS_RAM_SIZE" = true ] ; then
    SWAP_SIZE=`free -b | grep Mem: | awk '{print $2}' | numfmt --to-unit=K`KiB
  fi
  sgdisk -n 0:+0:+${SWAP_SIZE} -t 0:8200 -c 0:swap "${IMG_NAME}"; SWAP_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
fi
#sgdisk -N 0 -t 0:8300 -c 0:${ROOT_FS_TYPE}Root "${IMG_NAME}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
sgdisk -N ${NEXT_PARTITION} -t ${NEXT_PARTITION}:8300 -c ${NEXT_PARTITION}:${ROOT_FS_TYPE}Root "${IMG_NAME}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))

LOOPDEV=$(sudo losetup --find)
sudo losetup -P ${LOOPDEV} "${IMG_NAME}"
sudo wipefs -a -f ${LOOPDEV}p${BOOT_PARTITION}
sudo mkfs.fat -F32 -n BOOT ${LOOPDEV}p${BOOT_PARTITION}
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  sudo wipefs -a -f ${LOOPDEV}p${SWAP_PARTITION}
  sudo mkswap -L swap ${LOOPDEV}p${SWAP_PARTITION}
fi
sudo wipefs -a -f ${LOOPDEV}p${ROOT_PARTITION}
ELL=L
[ "$ROOT_FS_TYPE" = "f2fs" ] && ELL=l
sudo mkfs.${ROOT_FS_TYPE} -${ELL} ${ROOT_FS_TYPE}Root ${LOOPDEV}p${ROOT_PARTITION}
sgdisk -p "${IMG_NAME}"
TMP_ROOT=/tmp/diskRootTarget
mkdir -p ${TMP_ROOT}
sudo mount -t${ROOT_FS_TYPE} ${LOOPDEV}p${ROOT_PARTITION} ${TMP_ROOT}
sudo mkdir ${TMP_ROOT}/boot
sudo mount ${LOOPDEV}p${BOOT_PARTITION} ${TMP_ROOT}/boot
sudo pacstrap ${TMP_ROOT} base grub btrfs-progs dosfstools exfat-utils f2fs-tools gpart parted jfsutils mtools nilfs-utils ntfs-3g hfsprogs ${PACKAGE_LIST}
sudo sh -c "genfstab -U ${TMP_ROOT} >> ${TMP_ROOT}/etc/fstab"
sudo sed -i '/swap/d' ${TMP_ROOT}/etc/fstab
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  SWAP_UUID=$(lsblk -n -b -o UUID ${LOOPDEV}p${SWAP_PARTITION})
  sudo sed -i '$a #swap' ${TMP_ROOT}/etc/fstab
  sudo sed -i '$a UUID='${SWAP_UUID}'	none      	swap      	defaults  	0 0' ${TMP_ROOT}/etc/fstab
fi

cat > /tmp/chroot.sh <<EOF
#!/usr/bin/env bash
set -e #break on error
#set -vx #echo on
set -x

echo ${THIS_HOSTNAME} > /etc/hostname
ln -sf /usr/share/zoneinfo/${TIME_ZONE} /etc/localtime
echo "${LANGUAGE}.${TEXT_ENCODING} ${TEXT_ENCODING}" >> /etc/locale.gen
locale-gen
echo LANG="${LANGUAGE}.${TEXT_ENCODING}" > /etc/locale.conf
echo "root:${ROOT_PASSWORD}"|chpasswd
if [ "$MAKE_ADMIN_USER" = true ] ; then
  useradd -m -G wheel -s /bin/bash ${ADMIN_USER_NAME}
  echo "${ADMIN_USER_NAME}:${ADMIN_USER_PASSWORD}"|chpasswd
  pacman -S --needed --noconfirm sudo
  sed -i 's/# %wheel ALL=(ALL) NOPASSWD: ALL/## %wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
  sed -i 's/# %wheel ALL=(ALL)/%wheel ALL=(ALL)/g' /etc/sudoers
fi
if [ "$ENABLE_AUR" = true ] ; then
  echo "[archlinuxfr]" >> /etc/pacman.conf
  echo "SigLevel = Never" >> /etc/pacman.conf
  echo 'Server = http://repo.archlinux.fr/\$arch' >> /etc/pacman.conf
  pacman -Sy --needed --noconfirm yaourt
  sed -i '$ d' /etc/pacman.conf
  sed -i '$ d' /etc/pacman.conf
  sed -i '$ d' /etc/pacman.conf
  pacman -Sy
fi
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet/GRUB_CMDLINE_LINUX_DEFAULT="rootwait/g' /etc/default/grub
INSTALLED_PACKAGES=\$(pacman -Qe)
if [[ \$INSTALLED_PACKAGES == *"openssh"* ]] ; then
  systemctl enable sshd.service
fi
if [[ \$INSTALLED_PACKAGES == *"networkmanager"* ]] ; then
  systemctl enable NetworkManager.service
fi
if [[ \$INSTALLED_PACKAGES == *"bcache-tools"* ]] ; then
  sed -i 's/MODULES="/MODULES="bcache /g' /etc/mkinitcpio.conf
  sed -i 's/HOOKS="base udev autodetect modconf block/HOOKS="base udev autodetect modconf block bcache/g' /etc/mkinitcpio.conf
fi
mkinitcpio -p linux
grub-mkconfig -o /boot/grub/grub.cfg
pacman -Sy --needed --noconfirm os-prober
#grub-mkconfig -o /boot/EFI/BOOT/grub.cfg
if [ "$ROOT_FS_TYPE" = "f2fs" ] ; then
  cat > /usr/sbin/fix-f2fs-grub.sh <<END
#!/usr/bin/env bash
ROOT_DEVICE=\\\$(df | grep -w / | awk {'print \\\$1'})
ROOT_UUID=\\\$(blkid -s UUID -o value \\\${ROOT_DEVICE})
sed -i 's,root=/[^ ]* ,root=UUID='\\\${ROOT_UUID}' ,g' \\\$1
END
  chmod +x /usr/sbin/fix-f2fs-grub.sh
  fix-f2fs-grub.sh /boot/grub/grub.cfg
fi
if [ "$SUPPORT_UEFI" == true ] ; then
  pacman -S --needed --noconfirm efibootmgr
  #grub-install --modules="part_gpt fat linux gzio all_video" --removable --target=x86_64-efi --efi-directory=/boot --recheck --debug > /boot/grub-install.log
  #echo 'configfile ${cmdpath}/grub.cfg' > /tmp/grub.cfg
  mkdir -p /boot/EFI/BOOT
  grub-mkstandalone -d /usr/lib/grub/x86_64-efi/ -O x86_64-efi --modules="part_gpt part_msdos" --fonts="unicode" --locales="en@quot" --themes="" -o "/boot/EFI/BOOT/BOOTX64.EFI" /boot/grub/grub.cfg=/boot/grub/grub.cfg  -v
cat > /usr/sbin/fix-efi.sh <<END
#!/usr/bin/env bash
if [ efivar --list > /dev/null ] ; then
  grub-install --removable --target=x86_64-efi --efi-directory=/boot --recheck --debug
  grub-mkconfig -o /boot/grub/grub.cfg
  if [ "$ROOT_FS_TYPE" = "f2fs" ] ; then
    fix-f2fs-grub.sh /boot/grub/grub.cfg
  fi
fi
END
chmod +x /usr/sbin/fix-efi.sh
else
  grub-install --modules=part_gpt --target=i386-pc --recheck --debug ${LOOPDEV}
  #grub-mkconfig -o /boot/grub/grub.cfg
fi
EOF
if [ "$DD_TO_TARGET" = true ] ; then
  for n in ${TARGET_DISK}* ; do sudo umount $n || true; done
  sudo wipefs -a ${TARGET_DISK}
fi
chmod +x /tmp/chroot.sh
sudo mv /tmp/chroot.sh ${TMP_ROOT}/root/chroot.sh
sudo arch-chroot ${TMP_ROOT} /root/chroot.sh
sudo rm ${TMP_ROOT}/root/chroot.sh

sync && sudo umount ${TMP_ROOT}/boot && sudo umount ${TMP_ROOT} && sudo losetup -D && sync && echo "Image sucessfully created"
if [ "$DD_TO_TARGET" = true ] ; then
  echo "Writing image to disk..."
  sudo -E bash -c 'dd if='"${IMG_NAME}"' of='${TARGET_DISK}' bs=4M && sync && sgdisk -e '${TARGET_DISK}' && sgdisk -v '${TARGET_DISK}' && [ '"$TARGET_IS_REMOVABLE"' = true ] && eject '${TARGET_DISK} && echo "Image sucessfully written. It's now safe to remove ${TARGET_DISK}"
fi

if [ "$CLEAN_UP" = true ] ; then
  rm "${IMG_NAME}"
fi
