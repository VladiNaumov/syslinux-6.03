* ----------------------------------------------------------------------- *
 *
 *   Copyright 1998-2008 H. Peter Anvin - Все права защищены
 *   Copyright 2009-2010 Intel Corporation; автор: H. Peter Anvin
 *
 *   Эта программа является свободным программным обеспечением; вы можете
 *   перераспределять её и/или модифицировать её в соответствии с условиями
 *   GNU General Public License, опубликованной Free Software Foundation, Inc.,
 *   53 Temple Place Ste 330, Boston MA 02111-1307, США; либо версии 2 Лицензии,
 *   или (по вашему выбору) любой более поздней версии; включенной сюда по ссылке.
 *
 * ----------------------------------------------------------------------- */

/*
 * syslinux.c - Программа установки Linux для SYSLINUX
 *
 * Это конкретная версия для Linux.
 *
 * Это альтернативная версия установщика, которая не требует
 * mtools, но требует прав суперпользователя.
 */

/*
 * Если DO_DIRECT_MOUNT равно 0, вызывается mount(8)
 * Если DO_DIRECT_MOUNT равно 1, вызывается mount(2)
 */
#ifdef __KLIBC__
# define DO_DIRECT_MOUNT 1
#else
# define DO_DIRECT_MOUNT 0	/* glibc имеет неисправные ioctls для losetup */
#endif

#define _GNU_SOURCE
#define _XOPEN_SOURCE 500	/* Для pread() pwrite() */
#define _FILE_OFFSET_BITS 64
#include <alloca.h>
#include <errno.h>
#include <fcntl.h>
#include <paths.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <inttypes.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mount.h>

#include "linuxioctl.h"

#include <paths.h>
#ifndef _PATH_MOUNT
# define _PATH_MOUNT "/bin/mount"
#endif
#ifndef _PATH_UMOUNT
# define _PATH_UMOUNT "/bin/umount"
#endif
#ifndef _PATH_TMP
# define _PATH_TMP "/tmp/"
#endif

#include "syslinux.h"

#if DO_DIRECT_MOUNT
# include <linux/loop.h>
#endif

#include <getopt.h>
#include <sysexits.h>
#include "syslxcom.h"
#include "syslxfs.h"
#include "setadv.h"
#include "syslxopt.h" /* единые опции */

extern const char *program;	/* Имя программы */

pid_t mypid;
char *mntpath = NULL;		/* Путь для монтирования */

#if DO_DIRECT_MOUNT
int loop_fd = -1;		/* Дескриптор устройства loop */
#endif

void __attribute__ ((noreturn)) die(const char *msg)
{
    fprintf(stderr, "%s: %s\n", program, msg);

#if DO_DIRECT_MOUNT
    if (loop_fd != -1) {
	ioctl(loop_fd, LOOP_CLR_FD, 0);	/* Освобождение устройства loop */
	close(loop_fd);
	loop_fd = -1;
    }
#endif

    if (mntpath)
	unlink(mntpath);

    exit(1);
}

/*
 * Функция для монтирования
 */
int do_mount(int dev_fd, int *cookie, const char *mntpath, const char *fstype)
{
    struct stat st;

    (void)cookie;

    if (fstat(dev_fd, &st) < 0)
	return errno;

#if DO_DIRECT_MOUNT
    {
	if (!S_ISBLK(st.st_mode)) {
	    /* Это файл, нужно смонтировать его как loop */
	    unsigned int n = 0;
	    struct loop_info64 loopinfo;
	    int loop_fd;

	    for (n = 0; loop_fd < 0; n++) {
		snprintf(devfdname, sizeof devfdname, "/dev/loop%u", n);
		loop_fd = open(devfdname, O_RDWR);
		if (loop_fd < 0 && errno == ENOENT) {
		    die("нет доступных устройств loop!");
		}
		if (ioctl(loop_fd, LOOP_SET_FD, (void *)dev_fd)) {
		    close(loop_fd);
		    loop_fd = -1;
		    if (errno != EBUSY)
			die("невозможно настроить устройство loop");
		    else
			continue;
		}

		if (ioctl(loop_fd, LOOP_GET_STATUS64, &loopinfo) ||
		    (loopinfo.lo_offset = opt.offset,
		     ioctl(loop_fd, LOOP_SET_STATUS64, &loopinfo)))
		    die("невозможно настроить устройство loop");
	    }

	    *cookie = loop_fd;
	} else {
	    snprintf(devfdname, sizeof devfdname, "/proc/%lu/fd/%d",
		     (unsigned long)mypid, dev_fd);
	    *cookie = -1;
	}

	return mount(devfdname, mntpath, fstype,
		     MS_NOEXEC | MS_NOSUID, "umask=077,quiet");
    }
#else
    {
	char devfdname[128], mnt_opts[128];
	pid_t f, w;
	int status;

	snprintf(devfdname, sizeof devfdname, "/proc/%lu/fd/%d",
		 (unsigned long)mypid, dev_fd);

	f = fork();
	if (f < 0) {
	    return -1;
	} else if (f == 0) {
	    if (!S_ISBLK(st.st_mode)) {
		snprintf(mnt_opts, sizeof mnt_opts,
			 "rw,nodev,noexec,loop,offset=%llu,umask=077,quiet",
			 (unsigned long long)opt.offset);
	    } else {
		snprintf(mnt_opts, sizeof mnt_opts,
			 "rw,nodev,noexec,umask=077,quiet");
	    }
	    execl(_PATH_MOUNT, _PATH_MOUNT, "-t", fstype, "-o", mnt_opts,
		  devfdname, mntpath, NULL);
	    _exit(255);		/* execl не удался */
	}

	w = waitpid(f, &status, 0);
	return (w != f || status) ? -1 : 0;
    }
#endif
}

/*
 * Функция для размонтирования
 */
void do_umount(const char *mntpath, int cookie)
{
#if DO_DIRECT_MOUNT
    int loop_fd = cookie;

    if (umount2(mntpath, 0))
	die("невозможно размонтировать путь");

    if (loop_fd != -1) {
	ioctl(loop_fd, LOOP_CLR_FD, 0);	/* Освобождение устройства loop */
	close(loop_fd);
	loop_fd = -1;
    }
#else
    pid_t f = fork();
    pid_t w;
    int status;
    (void)cookie;

    if (f < 0) {
	perror("fork");
	exit(1);
    } else if (f == 0) {
	execl(_PATH_UMOUNT, _PATH_UMOUNT, mntpath, NULL);
    }

    w = waitpid(f, &status, 0);
    if (w != f || status) {
	exit(1);
    }
#endif
}

// 2

/*
 * Изменение ADV существующей установки
 */
int modify_existing_adv(const char *path)
{
    if (opt.reset_adv)
	syslinux_reset_adv(syslinux_adv);
    else if (read_adv(path, "ldlinux.sys") < 0)
	return 1;

    if (modify_adv() < 0)
	return 1;

    if (write_adv(path, "ldlinux.sys") < 0)
	return 1;

    return 0;
}

/*
 * Открытие файла
 */
int do_open_file(char *name)
{
    int fd;

    // Открываем файл только для чтения и устанавливаем атрибуты
    if ((fd = open(name, O_RDONLY)) >= 0) {
	uint32_t zero_attr = 0;
	ioctl(fd, FAT_IOCTL_SET_ATTRIBUTES, &zero_attr);
	close(fd);
    }

    // Удаляем файл и создаём новый с разрешениями 0444
    unlink(name);
    fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0444);
    if (fd < 0)
	perror(name);

    return fd;
}

int main(int argc, char *argv[])
{
    static unsigned char sectbuf[SECTOR_SIZE];
    int dev_fd, fd;
    struct stat st;
    int err = 0;
    char mntname[128];
    char *ldlinux_name;
    char *ldlinux_path;
    char *subdir;
    sector_t *sectors = NULL;
    int ldlinux_sectors = (boot_image_len + SECTOR_SIZE - 1) >> SECTOR_SHIFT;
    const char *errmsg;
    int mnt_cookie;
    int patch_sectors;
    int i, rv;

    mypid = getpid();
    umask(077);
    parse_options(argc, argv, MODE_SYSLINUX);

    /* Примечание: subdir гарантированно начинается и заканчивается на / */
    if (opt.directory && opt.directory[0]) {
	int len = strlen(opt.directory);
	int rv = asprintf(&subdir, "%s%s%s",
			  opt.directory[0] == '/' ? "" : "/",
			  opt.directory,
			  opt.directory[len-1] == '/' ? "" : "/");
	if (rv < 0 || !subdir) {
	    perror(program);
	    exit(1);
	}
    } else {
	subdir = "/";
    }

    if (!opt.device || opt.install_mbr || opt.activate_partition)
	usage(EX_USAGE, MODE_SYSLINUX);

    /*
     * Сначала убедимся, что мы можем открыть устройство вообще и что у нас есть
     * права на чтение/запись.
     */
    dev_fd = open(opt.device, O_RDWR);
    if (dev_fd < 0 || fstat(dev_fd, &st) < 0) {
	perror(opt.device);
	exit(1);
    }

    if (!S_ISBLK(st.st_mode) && !S_ISREG(st.st_mode) && !S_ISCHR(st.st_mode)) {
	die("не устройство и не обычный файл");
    }

    if (opt.offset && S_ISBLK(st.st_mode)) {
	die("нельзя сочетать смещение с блочным устройством");
    }

    xpread(dev_fd, sectbuf, SECTOR_SIZE, opt.offset);
    fsync(dev_fd);

    /*
     * Проверяем, что то, что мы получили, действительно является FAT/NTFS
     * загрузочным сектором/суперблоком
     */
    if ((errmsg = syslinux_check_bootsect(sectbuf, &fs_type))) {
	fprintf(stderr, "%s: %s\n", opt.device, errmsg);
	exit(1);
    }

    /*
     * Теперь монтируем устройство.
     */
    if (geteuid()) {
	die("Эта программа требует прав суперпользователя");
    } else {
	int i = 0;
	struct stat dst;
	int rv;

	/* Мы root или хотя бы setuid.
	   Создаём временную директорию и передаём все необходимые опции для монтирования. */

	if (chdir(_PATH_TMP)) {
	    fprintf(stderr, "%s: Невозможно получить доступ к директории %s.\n",
		    program, _PATH_TMP);
	    exit(1);
	}
#define TMP_MODE (S_IXUSR|S_IWUSR|S_IXGRP|S_IWGRP|S_IWOTH|S_IXOTH|S_ISVTX)

	if (stat(".", &dst) || !S_ISDIR(dst.st_mode) ||
	    (dst.st_mode & TMP_MODE) != TMP_MODE) {
	    die("возможно небезопасные разрешения для " _PATH_TMP);
	}

	for (i = 0;; i++) {
	    snprintf(mntname, sizeof mntname, "syslinux.mnt.%lu.%d",
		     (unsigned long)mypid, i);

	    if (lstat(mntname, &dst) != -1 || errno != ENOENT)
		continue;

	    rv = mkdir(mntname, 0000);

	    if (rv == -1) {
		if (errno == EEXIST || errno == EINTR)
		    continue;
		perror(program);
		exit(1);
	    }

	    if (lstat(mntname, &dst) || dst.st_mode != (S_IFDIR | 0000) ||
		dst.st_uid != 0) {
		die("попытка создания символической ссылки в нашу директорию!");
	    }
	    break;		/* Успешно получили директорию... */
	}

	mntpath = mntname;
    }

    // Монтируем устройство в зависимости от типа файловой системы
    if (fs_type == VFAT) {
        if (do_mount(dev_fd, &mnt_cookie, mntpath, "vfat") &&
            do_mount(dev_fd, &mnt_cookie, mntpath, "msdos")) {
            rmdir(mntpath);
            die("не удалось смонтировать FAT том");
        }
    } else if (fs_type == NTFS) {
        if (do_mount(dev_fd, &mnt_cookie, mntpath, "ntfs-3g")) {
            rmdir(mntpath);
            die("не удалось смонтировать NTFS том");
        }
    }

    ldlinux_path = alloca(strlen(mntpath) + strlen(subdir) + 1);
    sprintf(ldlinux_path, "%s%s", mntpath, subdir);

    ldlinux_name = alloca(strlen(ldlinux_path) + 14);

// 3

if (!ldlinux_name) {
	perror(program);
	err = 1;
	goto umount;
    }
    sprintf(ldlinux_name, "%sldlinux.sys", ldlinux_path);

    /* Обновить ADV только? */
    if (opt.update_only == -1) {
	if (opt.reset_adv || opt.set_once) {
	    modify_existing_adv(ldlinux_path);
	    do_umount(mntpath, mnt_cookie);
	    sync();
	    rmdir(mntpath);
	    exit(0);
    } else if (opt.update_only && !syslinux_already_installed(dev_fd)) {
        fprintf(stderr, "%s: предыдущий загрузочный сектор syslinux не найден\n",
                argv[0]);
        exit(1);
	} else {
	    fprintf(stderr, "%s: укажите --install или --update для дальнейших действий\n", argv[0]);
	    opt.update_only = 0;
	}
    }

    /* Прочитать уже существующий ADV, если он уже установлен */
    if (opt.reset_adv)
	syslinux_reset_adv(syslinux_adv);
    else if (read_adv(ldlinux_path, "ldlinux.sys") < 0)
	syslinux_reset_adv(syslinux_adv);
    if (modify_adv() < 0)
	exit(1);

    fd = do_open_file(ldlinux_name);
    if (fd < 0) {
	err = 1;
	goto umount;
    }

    /* Записать файл первый раз */
    if (xpwrite(fd, (const char _force *)boot_image, boot_image_len, 0)
	!= (int)boot_image_len ||
	xpwrite(fd, syslinux_adv, 2 * ADV_SIZE,
		boot_image_len) != 2 * ADV_SIZE) {
	fprintf(stderr, "%s: ошибка записи в %s\n", program, ldlinux_name);
	exit(1);
    }

    fsync(fd);
    /*
     * Установить атрибуты
     */
    {
	uint32_t attr = 0x07;	/* Скрытый+Системный+Только для чтения */
	ioctl(fd, FAT_IOCTL_SET_ATTRIBUTES, &attr);
    }

    /*
     * Создать карту блоков.
     */
    ldlinux_sectors += 2; /* 2 сектора ADV */
    sectors = calloc(ldlinux_sectors, sizeof *sectors);
    if (sectmap(fd, sectors, ldlinux_sectors)) {
	perror("bmap");
	exit(1);
    }
    close(fd);
    sync();

    sprintf(ldlinux_name, "%sldlinux.c32", ldlinux_path);
    fd = do_open_file(ldlinux_name);
    if (fd < 0) {
	err = 1;
	goto umount;
    }

    rv = xpwrite(fd, (const char _force *)syslinux_ldlinuxc32,
		 syslinux_ldlinuxc32_len, 0);
    if (rv != (int)syslinux_ldlinuxc32_len) {
	fprintf(stderr, "%s: ошибка записи в %s\n", program, ldlinux_name);
	exit(1);
    }

    fsync(fd);
    /*
     * Установить атрибуты
     */
    {
	uint32_t attr = 0x07;	/* Скрытый+Системный+Только для чтения */
	ioctl(fd, FAT_IOCTL_SET_ATTRIBUTES, &attr);
    }

    close(fd);
    sync();

umount:
    do_umount(mntpath, mnt_cookie);
    sync();
    rmdir(mntpath);

    if (err)
	exit(err);

    /*
     * Обновить ldlinux.sys и загрузочный сектор
     */
    i = syslinux_patch(sectors, ldlinux_sectors, opt.stupid_mode,
		       opt.raid_mode, subdir, NULL);
    patch_sectors = (i + SECTOR_SIZE - 1) >> SECTOR_SHIFT;

    /*
     * Записать обновлённые первые сектора ldlinux.sys
     */
    for (i = 0; i < patch_sectors; i++) {
	xpwrite(dev_fd,
		(const char _force *)boot_image + i * SECTOR_SIZE,
		SECTOR_SIZE,
		opt.offset + ((off_t) sectors[i] << SECTOR_SHIFT));
    }

    /*
     * Завершить запись загрузочного сектора
     */

    /* Считать суперблок снова, так как он мог измениться при монтировании */
    xpread(dev_fd, sectbuf, SECTOR_SIZE, opt.offset);

    /* Скопировать код syslinux в загрузочный сектор */
    syslinux_make_bootsect(sectbuf, fs_type);

    /* Записать новый загрузочный сектор */
    xpwrite(dev_fd, sectbuf, SECTOR_SIZE, opt.offset);

    close(dev_fd);
    sync();

    /* Готово! */

    return 0;
}


/*
Краткий Анализ
Функция modify_existing_adv(const char *path):

Обновляет ADV (Advanced Boot Record) для существующей установки.
В зависимости от параметров opt.reset_adv и opt.set_once, обновляет ADV, сбрасывая его или читая и модифицируя текущие записи ADV.
Функция do_open_file(char *name):

Открывает файл для записи, предварительно удаляя его, если он существует.
Устанавливает атрибуты для созданного файла.
Функция main(int argc, char *argv[]):

### Этот файл содержит код, который отвечает за некоторые из действий, связанных с загрузкой, но не является непосредственно ядром.

Роль syslinux.c
Файл syslinux.c в контексте кода SYSLINUX выполняет следующие задачи:

Настройка и инициализация:

syslinux.c настраивает среду для последующей работы. Это включает в себя инициализацию необходимых структур данных, монтирование файловых систем и подготовку для поиска ядра.
Работа с файловыми системами:

В этом файле содержится код для монтирования файловых систем, работы с файловыми дескрипторами и обработки различных файловых систем (FAT, NTFS и т. д.).
Обработка конфигурации и загрузка файлов:

syslinux.c читает конфигурационные файлы и находит ядро Linux или другие необходимые файлы. Это может включать в себя чтение ldlinux.sys и других файлов, необходимых для корректной работы загрузчика.
Запись на диск:

Файл также может содержать код для записи информации на диск, обновления сектора загрузки и выполнения других задач, связанных с установкой и настройкой загрузчика.
Передача управления:

После подготовки, syslinux.c передает управление загруженному ядру или другому компоненту системы.
Основные части syslinux.c:
Функции инициализации: Подготовка и настройка окружения.
Функции монтирования: Монтирование файловых систем и работа с ними.
Работа с файлами: Загрузка и запись файлов, необходимых для работы загрузчика.
Передача управления: Передача контроля ядру Linux или другой части системы.
Так что, хотя syslinux.c является частью кода загрузчика, он не является ядром и выполняет подготовку и настройку перед передачей управления ядру Linux.

*/