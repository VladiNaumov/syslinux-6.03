This is syslinux-6.03, downloaded and pristine in its current form from the upstream distro on kernel.org.

See the files in the doc directory for documentation about SYSLINUX:

	syslinux.txt	    - Usage instructions; manual.
	distrib.txt	    - For creators of Linux distributions.
	pxelinux.txt	    - Documentation specific to PXELINUX.
	isolinux.txt	    - Documentation specific to ISOLINUX.
	extlinux.txt	    - Documentation specific to EXTLINUX.
	menu.txt	    - About the menu systems.
	usbkey.txt	    - About using SYSLINUX on USB keys.
	memdisk.txt         - Documentation about MEMDISK.

Also see the files:

	NEWS		    - List of changes from previous releases.
	TODO		    - About features planned for future releases.
	COPYING		    - For the license terms of this software.

SYSLINUX now builds in a Linux environment, using nasm.  You need nasm
version 2.03 or later (2.07 or later recommended) to build SYSLINUX
from source.  See http://www.nasm.us/ for information about nasm.

"utils/isohybrid" needs the UUID library and following header file,

	/usr/include/uuid/uuid.h

You can get them from the "uuid-dev" package on Debian based systems
or from the "libuuid-devel" package on RPM based distributions.

There is now a mailing list for SYSLINUX.  See the end of syslinux.txt
for details.

SYSLINUX is:

Copyright 1994-2011 H. Peter Anvin et al - All Rights Reserved

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, Inc., 53 Temple Place Ste 330,
Boston MA 02111-1307, USA; either version 2 of the License, or
(at your option) any later version; incorporated herein by reference.


### Каталоги Syslinux

- @src/: это мой каталог, для моих экспериментов
- bios/: Это основной каталог для BIOS-версии Syslinux.
- bios/core/ — здесь находятся исходные файлы для основной части BIOS-загрузчика.
- bios/com32/ — содержит модули на C, такие как menu.c32 и другие утилиты, которые используются для дополнительных функций загрузчика (например, текстовые меню).
- efi/: Этот каталог содержит файлы для версии Syslinux, работающей на системах с UEFI.
- efi/core/ — аналогично папке bios/core/, здесь находятся исходные файлы для загрузчика в UEFI.
- mbr/: Здесь находятся файлы для работы с Master Boot Record (MBR). Они содержат код для начального этапа загрузки с диска.
- ldlinux/: Эта папка содержит образы и исходные файлы для создания ldlinux.sys, файла, который Syslinux использует для продолжения загрузки после выполнения начального загрузчика.
- doc/: Документация по Syslinux. Полезно для чтения описания возможностей и настройки системы.
- memdisk/: Memdisk — это инструмент, используемый Syslinux для загрузки дисков или дискет (обычно используется для загрузки образов дискет или старых ОС, таких как DOS).
- libinstaller/: В этом каталоге находятся файлы для установки Syslinux на носители (например, на USB-диски или другие накопители).
- utils/: Утилиты для разработки и отладки, такие как генераторы образов, скрипты для компиляции и сборки загрузчика.
- extlinux/: Это версия Syslinux для работы с ext2/ext3/ext4 файловыми системами. Она работает с разделами на дисках, которые используют эти файловые системы, и загружает ядро из них.
- pxelinux/: Загрузчик для сетевой загрузки через PXE. Здесь находятся файлы для загрузки по сети.

