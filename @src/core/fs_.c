#include <sys/file.h>
#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dprintf.h>
#include <syslinux/sysappend.h>
#include "core.h"
#include "dev.h"
#include "fs.h"
#include "cache.h"

/* Текущая смонтированная файловая система */
__export struct fs_info *this_fs = NULL;  /* Корневая файловая система */

/* Файловые структуры (у нас пока нет malloc) */
__export struct file files[MAX_OPEN];

/* Жесткие ограничения для символических ссылок */
#define MAX_SYMLINK_CNT 20
#define MAX_SYMLINK_BUF 4096

/*
 * Получить новую структуру inode
 */
struct inode *alloc_inode(struct fs_info *fs, uint32_t ino, size_t data)
{
    struct inode *inode = zalloc(sizeof(struct inode) + data);
    if (inode) {
        inode->fs = fs;
        inode->ino = ino;
        inode->refcnt = 1;
    }
    return inode;
}

/*
 * Освободить ссылочный inode
 */
void put_inode(struct inode *inode)
{
    while (inode) {
        struct inode *dead = inode;
        int refcnt = --(dead->refcnt);
        dprintf("put_inode %p name %s refcnt %u\n", dead, dead->name, refcnt);
        if (refcnt)
            break;        /* У нас все еще есть ссылки */
        inode = dead->parent;
        if (dead->name)
            free((char *)dead->name);
        free(dead);
    }
}

/*
 * Получить пустую файловую структуру
 */
static struct file *alloc_file(void)
{
    int i;
    struct file *file = files;

    for (i = 0; i < MAX_OPEN; i++) {
        if (!file->fs)
            return file;
        file++;
    }

    return NULL;
}

/*
 * Закрыть и освободить файловую структуру
 */
static inline void free_file(struct file *file)
{
    memset(file, 0, sizeof *file);
}

__export void _close_file(struct file *file)
{
    if (file->fs)
        file->fs->fs_ops->close_file(file);
    free_file(file);
}

/*
 * Найти и открыть конфигурационный файл
 */
__export int open_config(void)
{
    int fd, handle;
    struct file_info *fp;

    fd = opendev(&__file_dev, NULL, O_RDONLY);
    if (fd < 0)
        return -1;

    fp = &__file_info[fd];

    handle = this_fs->fs_ops->open_config(&fp->i.fd);
    if (handle < 0) {
        close(fd);
        errno = ENOENT;
        return -1;
    }

    fp->i.offset = 0;
    fp->i.nbytes = 0;

    return fd;
}

__export void mangle_name(char *dst, const char *src)
{
    this_fs->fs_ops->mangle_name(dst, src);
}

size_t pmapi_read_file(uint16_t *handle, void *buf, size_t sectors)
{
    bool have_more;
    size_t bytes_read;
    struct file *file;

    file = handle_to_file(*handle);
    bytes_read = file->fs->fs_ops->getfssec(file, buf, sectors, &have_more);

    /*
     * Если достигнут конец файла, файловая система закроет
     * подлежащий файл... это на самом деле должно быть чище.
     */
    if (!have_more) {
        _close_file(file);
        *handle = 0;
    }

    return bytes_read;
}

int searchdir(const char *name, int flags)
{
    static char root_name[] = "/";
    struct file *file;
    char *path, *inode_name, *next_inode_name;
    struct inode *tmp, *inode = NULL;
    int symlink_count = MAX_SYMLINK_CNT;

    dprintf("searchdir: %s  root: %p  cwd: %p\n",
            name, this_fs->root, this_fs->cwd);

    if (!(file = alloc_file()))
        goto err_no_close;
    file->fs = this_fs;

    /* если у нас есть ->searchdir метод, вызовем его */
    if (file->fs->fs_ops->searchdir) {
        file->fs->fs_ops->searchdir(name, flags, file);

        if (file->inode)
            return file_to_handle(file);
        else
            goto err;
    }

    /* иначе, попробуем общий метод поиска пути */

    /* Скопировать путь */
    path = strdup(name);
    if (!path) {
        dprintf("searchdir: Не удалось скопировать путь\n");
        goto err_path;
    }

    /* Работаем с текущей директорией по умолчанию */
    inode = get_inode(this_fs->cwd);
    if (!inode) {
        dprintf("searchdir: Не удалось использовать текущую директорию\n");
        goto err_curdir;
    }

    for (inode_name = path; inode_name; inode_name = next_inode_name) {
        /* Корневая директория? */
        if (inode_name[0] == '/') {
            next_inode_name = inode_name + 1;
            inode_name = root_name;
        } else {
            /* Найти следующее имя inode */
            next_inode_name = strchr(inode_name + 1, '/');
            if (next_inode_name) {
                /* Завершить текущее имя inode и указать на следующее */
                *next_inode_name++ = '\0';
            }
        }
        if (next_inode_name) {
            /* Перейти через лишние слэши */
            while (*next_inode_name == '/')
                next_inode_name++;

            /* Проверить, если мы в конце */
            if (*next_inode_name == '\0')
                next_inode_name = NULL;
        }
        dprintf("searchdir: inode_name: %s\n", inode_name);
        if (next_inode_name)
            dprintf("searchdir: Остальное: %s\n", next_inode_name);

        /* Корневая директория? */
        if (inode_name[0] == '/') {
            /* Освободить любую цепочку, которая уже была установлена */
            put_inode(inode);
            inode = get_inode(this_fs->root);
            continue;
        }

        /* Текущая директория? */
        if (!strncmp(inode_name, ".", sizeof ".")) {
            continue;
        }

        /* Родительская директория? */
        if (!strncmp(inode_name, "..", sizeof "..")) {
            /* Если нет родителя, просто игнорируем это */
            if (!inode->parent)
                continue;

            /* Добавляем ссылку на родителя, чтобы освободить дочерний элемент */
            tmp = get_inode(inode->parent);

            /* Освобождение дочернего элемента уменьшит количество ссылок на родителя до 1 */
            put_inode(inode);

            inode = tmp;
            continue;
        }

        /* Всё остальное */
        tmp = inode;
        inode = this_fs->fs_ops->iget(inode_name, inode);
        if (!inode) {
            /* Ошибка.  Освободить цепочку */
            put_inode(tmp);
            break;
        }

        /* Проверка на целостность */
        if (inode->parent && inode->parent != tmp) {
            dprintf("searchdir: iget вернул другого родителя\n");
            put_inode(inode);
            inode = NULL;
            put_inode(tmp);
            break;
        }
        inode->parent = tmp;
        inode->name = strdup(inode_name);
        dprintf("searchdir: компонент пути: %s\n", inode->name);

        /* Обработка символических ссылок */
        if (inode->mode == DT_LNK) {
            char *new_path;
            int new_len, copied;

            /* целевой путь + NUL */
            new_len = inode->size + 1;

            if (next_inode_name) {
                /* целевой путь + слэш + остальное + NUL */
                new_len += strlen(next_inode_name) + 1;
            }

            if (!this_fs->fs_ops->readlink ||
                /* проверки лимитов */
                --symlink_count == 0 ||
                new_len > MAX_SYMLINK_BUF)
                goto err_new_len;

            new_path = malloc(new_len);
            if (!new_path)
                goto err_new_path;

            copied = this_fs->fs_ops->readlink(inode, new_path);
            if (copied <= 0)
                goto err_copied;
            new_path[copied] = '\0';
            dprintf("searchdir: Символическая ссылка: %s\n", new_path);

            if (next_inode_name) {
                new_path[copied] = '/';
                strcpy(new_path + copied + 1, next_inode_name);
                dprintf("searchdir: Новый путь: %s\n", new_path);
            }

            free(path);
            path = next_inode_name = new_path;

            /* Добавляем ссылку на родителя, чтобы освободить дочерний элемент */
            tmp = get_inode(inode->parent);

            /* Освобождение дочернего элемента уменьшит количество ссылок на родителя до 1 */
            put_inode(inode);

            inode = tmp;
            continue;
err_copied:
            free(new_path);
err_new_path:
err_new_len:
            put_inode(inode);
            inode = NULL;
            break;
        }

        /* Если есть ещё что обрабатывать, это должна быть директория */
        if (next_inode_name && inode->mode != DT_DIR) {
            dprintf("searchdir: Ожидалась директория\n");
            put_inode(inode);
            inode = NULL;
            break;
        }
    }
err_curdir:
    free(path);
err_path:
    if (!inode) {
        dprintf("searchdir: Не найдено\n");
        goto err;
    }

    file->inode  = inode;
    file->offset = 0;

    return file_to_handle(file);

err:
    dprintf("searchdir: ошибка поиска файла %s\n", name);
    _close_file(file);
err_no_close:
    return -1;
}

__export int open_file(const char *name, int flags, struct com32_filedata *filedata)
{
    int rv;
    struct file *file;
    char mangled_name[FILENAME_MAX];

    dprintf("open_file %s\n", name);

    mangle_name(mangled_name, name);
    rv = searchdir(mangled_name, flags);

    if (rv < 0)
        return rv;

    file = handle_to_file(rv);

    if (file->inode->mode != DT_REG) {
        _close_file(file);
        return -1;
    }

    filedata->size   = file->inode->size;
    filedata->blocklg2  = SECTOR_SHIFT(file->fs);
    filedata->handle    = rv;

    return rv;
}

__export void close_file(uint16_t handle)
{
    struct file *file;

    if (handle) {
        file = handle_to_file(handle);
        _close_file(file);
    }
}

__export char *fs_uuid(void)
{
    if (!this_fs || !this_fs->fs_ops || !this_fs->fs_ops->fs_uuid)
        return NULL;
    return this_fs->fs_ops->fs_uuid(this_fs);
}

/*
 * инициализирует:
 *    функцию управления памятью;
 *    структуру файловой системы vfs;
 *    структуру устройства;
 *    вызывает функцию инициализации файловой системы;
 *    инициализирует кэш, если он нужен;
 *    наконец, получает текущий inode для относительного поиска пути.
 *
 * ops - это список указателей на несколько fs_ops
 */
__bss16 uint16_t SectorSize, SectorShift;

void fs_init(const struct fs_ops **ops, void *priv)
{
    static struct fs_info fs;  /* Буфер файловой системы */
    int blk_shift = -1;
    struct device *dev = NULL;

    /* Имя по умолчанию для корневой директории */
    fs.cwd_name[0] = '/';

    while ((blk_shift < 0) && *ops) {
        /* настройка структуры fs */
        fs.fs_ops = *ops;

        /*
         * Это смело предполагает, что мы не смешиваем файловые системы FS_NODEV
         * с файловыми системами FS_DEV...
         */
        if (fs.fs_ops->fs_flags & FS_NODEV) {
            fs.fs_dev = NULL;
        } else {
            if (!dev)
                dev = device_init(priv);
            fs.fs_dev = dev;
        }
        /* вызов кода инициализации файловой системы */
        blk_shift = fs.fs_ops->fs_init(&fs);
        ops++;
    }
    if (blk_shift < 0) {
        printf("Не найдена подходящая файловая система!\n");
        while (1)
            ;
    }
    this_fs = &fs;

    /* инициализация кэша только если он не был инициализирован
     * драйвером файловой системы */
    if (fs.fs_dev && fs.fs_dev->cache_data && !fs.fs_dev->cache_init)
        cache_init(fs.fs_dev, blk_shift);

    /* начинаем с корневой директории */
    if (fs.fs_ops->iget_root) {
        fs.root = fs.fs_ops->iget_root(&fs);
        fs.cwd = get_inode(fs.root);
        dprintf("init: корневой inode %p, текущий inode %p\n", fs.root, fs.cwd);
    }

    if (fs.fs_ops->chdir_start) {
        if (fs.fs_ops->chdir_start() < 0)
            printf("Не удалось изменить директорию на начальную\n");
    }

    SectorShift = fs.sector_shift;
    SectorSize  = fs.sector_size;

    /* Добавить строку FSUUID=... к командной строке */
    sysappend_set_fs_uuid();
}
