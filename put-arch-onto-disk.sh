#!/usr/bin/env bash
set -e #break on error
set -vx #echo on

: ${ROOT_FS_TYPE:=f2fs}
: ${MAKE_SWAP_PARTITION:=false}
: ${SWAP_SIZE_IS_RAM_SIZE:=false}
: ${SWAP_SIZE:=1GiB}
: ${USE_TARGET_DISK:=false}
: ${TARGET_DISK:=/dev/sdX}
: ${IMG_SIZE:=3GiB}
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

rm "${IMG_NAME}"
if [ "$USE_TARGET_DISK" = true ] ; then
  DISK_INFO=$(lsblk -n -b -o SIZE,PHY-SEC ${TARGET_DISK})
  IFS=' ' read -a DISK_INFO_A <<< "$DISK_INFO"
  IMG_SIZE=$(numfmt --to-unit=K ${DISK_INFO_A[0]})KiB
  PHY_SEC_BYTES=${DISK_INFO_A[1]}
fi
fallocate -l $IMG_SIZE "${IMG_NAME}"
wipefs -a -f "${IMG_NAME}"
sgdisk -n 0:+0:+1MiB -t 0:ef02 -c 0:biosGrub "${IMG_NAME}"
sgdisk -n 0:+0:+200MiB -t 0:8300 -c 0:ext4Boot "${IMG_NAME}"
NEXT_PARTITION=3
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  if [ "$SWAP_SIZE_IS_RAM_SIZE" = true ] ; then
    SWAP_SIZE=`free -b | grep Mem: | awk '{print $2}' | numfmt --to-unit=K`KiB
  fi
  sgdisk -n 0:+0:+${SWAP_SIZE} -t 0:8200 -c 0:swap "${IMG_NAME}"
  NEXT_PARTITION=4
fi
#sgdisk -N 0 -t 0:8300 -c 0:${ROOT_FS_TYPE}Root "${IMG_NAME}"
sgdisk -N ${NEXT_PARTITION} -t ${NEXT_PARTITION}:8300 -c ${NEXT_PARTITION}:${ROOT_FS_TYPE}Root "${IMG_NAME}"

LOOPDEV=$(sudo losetup --find)
sudo losetup -P ${LOOPDEV} "${IMG_NAME}"
sudo wipefs -a -f ${LOOPDEV}p2
sudo mkfs.ext4 -L ext4Boot ${LOOPDEV}p2
ELL=L
sudo wipefs -a -f ${LOOPDEV}p${NEXT_PARTITION}
[ "$ROOT_FS_TYPE" = "f2fs" ] && ELL=l
sudo mkfs.${ROOT_FS_TYPE} -${ELL} ${ROOT_FS_TYPE}Root ${LOOPDEV}p${NEXT_PARTITION}
sgdisk -p "${IMG_NAME}"
TMP_ROOT=/tmp/diskRootTarget
mkdir -p ${TMP_ROOT}
sudo mount -t${ROOT_FS_TYPE} ${LOOPDEV}p${NEXT_PARTITION} ${TMP_ROOT}
sudo mkdir ${TMP_ROOT}/boot
sudo mount -text4 ${LOOPDEV}p2 ${TMP_ROOT}/boot
sudo pacstrap ${TMP_ROOT} base grub ${PACKAGE_LIST}
sudo sh -c "genfstab -U ${TMP_ROOT} >> ${TMP_ROOT}/etc/fstab"
sudo sed -i '/swap/d' ${TMP_ROOT}/etc/fstab
sudo sed -i '$ d' ${TMP_ROOT}/etc/fstab
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  SWAP_UUID=$(lsblk -n -b -o UUID ${LOOPDEV}p3)
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
  sed -i 's/# %wheel ALL=(ALL)/%wheel ALL=(ALL)/g' /etc/sudoers
fi
if [ "$ROOT_FS_TYPE" = "f2fs" ] ; then
  pacman -S --needed --noconfirm f2fs-tools
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
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet/GRUB_CMDLINE_LINUX_DEFAULT="/g' /etc/default/grub
INSTALLED_PACKAGES=\$(pacman -Qe)
if [[ \$INSTALLED_PACKAGES == *"openssh"* ]] ; then
  systemctl enable sshd.service
fi
if [[ \$INSTALLED_PACKAGES == *"networkmanager"* ]] ; then
  systemctl enable NetworkManager.service
fi
if [[ \$INSTALLED_PACKAGES == *"bcache-tools"* ]] ; then
  sed -i 's/MODULES=""/MODULES="bcache"/g' /etc/mkinitcpio.conf
  sed -i 's/HOOKS="base udev autodetect modconf block/HOOKS="base udev autodetect modconf block bcache/g' /etc/mkinitcpio.conf
fi
mkinitcpio -p linux
grub-install --target=i386-pc --recheck --debug ${LOOPDEV}
grub-mkconfig -o /boot/grub/grub.cfg

if [ "$ROOT_FS_TYPE" = "f2fs" ] ; then
  ROOT_UUID=$(lsblk -n -b -o UUID ${LOOPDEV}p${NEXT_PARTITION})
  sed -i 's,root=/dev/.*,root=UUID='\$ROOT_UUID' rw,g' /boot/grub/grub.cfg
fi

EOF
chmod +x /tmp/chroot.sh
sudo mv /tmp/chroot.sh ${TMP_ROOT}/root/chroot.sh
sudo arch-chroot ${TMP_ROOT} /root/chroot.sh
sudo rm ${TMP_ROOT}/root/chroot.sh

sync
sudo umount ${TMP_ROOT}/boot
sudo umount ${TMP_ROOT}
sudo losetup -D
sync

if [ "$DD_TO_TARGET" = true ] ; then
  sudo dd if="${IMG_NAME}" of=${TARGET_DISK} bs=1M
  sync
  sudo sgdisk -e ${TARGET_DISK}
  sudo sgdisk -v ${TARGET_DISK}
fi

if [ "$CLEAN_UP" = true ] ; then
  rm "${IMG_NAME}"
fi
