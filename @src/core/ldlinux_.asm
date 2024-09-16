; ****************************************************************************
;
;  ldlinux.asm
;
;  Программа для загрузки ядер Linux с дискеты, отформатированной для MS-DOS.
;
; ****************************************************************************

%define IS_SYSLINUX 1
%include "head.inc"

; Определения операций файловых систем
ROOT_FS_OPS:
        extern vfat_fs_ops
        dd vfat_fs_ops         ; Операции файловой системы VFAT
        extern ext2_fs_ops
        dd ext2_fs_ops        ; Операции файловой системы ext2
        extern ntfs_fs_ops
        dd ntfs_fs_ops        ; Операции файловой системы NTFS
        extern xfs_fs_ops
        dd xfs_fs_ops         ; Операции файловой системы XFS
        extern btrfs_fs_ops
        dd btrfs_fs_ops       ; Операции файловой системы Btrfs
        extern ufs_fs_ops
        dd ufs_fs_ops         ; Операции файловой системы UFS
        dd 0                  ; Конец списка операций файловых систем

%include "diskfs.inc"       ; Подключение файла с определениями для работы с дисковыми файловыми системами

; Основной процесс
find_kernel:
    ; Код для поиска и чтения ядра
    call read_kernel   ; Вызов функции для чтения ядра

; Передача управления ядру
jmp kernel_start_address   ; Передача управления ядру

; Если произошла ошибка
error_handler:
    ; Обработка ошибок
    call handle_error



;Общие Сведения:

;Инициализация и настройка среды происходит в начале кода, где устанавливаются операции для работы с различными файловыми системами и подключаются необходимые определения.
;Поиск и загрузка ядра происходят в find_kernel, где происходит чтение ядра из файловой системы.
;Передача управления осуществляется командой jmp на адрес ядра.
;Этот пример является упрощенным и демонстрирует, где в коде выполняются указанные операции. В реальном коде Syslinux может быть намного сложнее, включая обработку ошибок, дополнительные проверки и другие функции.

;В коде определяются идентификаторы и операции для различных файловых систем, которые поддерживает Syslinux. Это позволяет загрузчику взаимодействовать с различными типами файловых систем.
;Операции Файловых Систем:

;ROOT_FS_OPS содержит ссылки на функции для работы с различными файловыми системами. Эти ссылки подключаются к соответствующим операциям в diskfs.inc.
;Основной Процесс:
;Этот код настраивает и инициализирует функции для работы с дисковыми файловыми системами, что позволяет загрузчику находить и загружать необходимые файлы (включая ядро) с диска. После выполнения всех начальных настроек, код передает управление ядру.