; -*- fundamental -*- (asm-mode sucks)
; ****************************************************************************
;
;  isolinux.asm
;
;  Программа для загрузки Linux с CD-ROM через стандарт El Torito в режиме
;  "без эмуляции", что делает доступной всю файловую систему. Базируется на
;  загрузчике SYSLINUX для дискет MS-DOS.
;
;   Copyright 1994-2009 H. Peter Anvin - Все права защищены
;   Copyright 2009 Intel Corporation; автор: H. Peter Anvin
;
;  Программа распространяется по лицензии GNU GPL, версия 2 или более поздняя.
;
; ****************************************************************************

%define IS_ISOLINUX 1  ; Определяем, что это ISOLINUX
%include "head.inc"    ; Включаем заголовочный файл с общими директивами и макросами

;
; Некоторые полуконфигурируемые константы. Меняйте их на свой страх и риск.
;
my_id         equ isolinux_id    ; Идентификатор программы ISOLINUX
NULLFILE      equ 0              ; Ноль байт — это имя файла null
NULLOFFSET    equ 0              ; Позиция для поиска
retry_count   equ 6              ; Количество попыток доступа к BIOS
%assign HIGHMEM_SLOP 128*1024    ; Резервируем память в верхней области (128 КБ)
SECTOR_SHIFT  equ 11             ; 2048 байт/сектор (требование El Torito)
SECTOR_SIZE   equ (1 << SECTOR_SHIFT)  ; Размер сектора

ROOT_DIR_WORD equ 0x002F  ; Слово для корневого каталога (используется при чтении)

; ---------------------------------------------------------------------------
;   НАЧАЛО КОДА
; ---------------------------------------------------------------------------

;
; Память ниже этой точки зарезервирована для BIOS и MBR
;
        section .earlybss  ; Секция для данных, которые нужны на ранних этапах
        global trackbuf    ; Буфер для чтения данных с диска
trackbufsize  equ 8192      ; Размер буфера для чтения треков (8 КБ)
trackbuf      resb trackbufsize  ; Зарезервируем 8 КБ под буфер

        ; Некоторые данные используются до загрузки всего образа. 
        ; НЕ перемещайте их в секции .bss16 или .uibss.
        section .earlybss
        global BIOSName
        alignb 4
FirstSecSum   resd 1    ; Контрольная сумма байтов 64-2048 (для проверки данных)
ImageDwords   resd 1    ; Размер файла isolinux.bin в DWORD
InitStack     resd 1    ; Начальный указатель стека (SS:SP)
DiskSys       resw 1    ; Последний вызов INT 13h (для работы с диском)
ImageSectors  resw 1    ; Размер файла isolinux.bin в секторах

        ; Эти два используются как одно слово (dword)...
GetlinsecPtr  resw 1    ; Указатель на сектор, который будет прочитан
BIOSName      resw 1    ; Строка для отображения типа BIOS
%define HAVE_BIOSNAME 1
        global BIOSType
BIOSType      resw 1    ; Тип BIOS (идентификация)
DiskError     resb 1    ; Код ошибки при работе с диском (если есть)
        global DriveNumber
DriveNumber   resb 1    ; Номер привода CD-ROM, полученный от BIOS
ISOFlags      resb 1    ; Флаги для поиска каталога ISO
RetryCount    resb 1    ; Счётчик для повторных попыток доступа к диску

        alignb 8  ; Выровняем следующие данные по границе 8 байт
        global Hidden
Hidden        resq 1    ; Используется в гибридном режиме
bsSecPerTrack resw 1    ; Секторов на трек (для гибридного режима)
bsHeads       resw 1    ; Количество головок (для гибридного режима)

;
; Пакет по спецификации El Torito
;

        alignb 8
_spec_start   equ $  ; Начало спецификации
        global spec_packet
spec_packet:  resb 1    ; Размер пакета
sp_media:     resb 1    ; Тип носителя
sp_drive:     resb 1    ; Номер привода
sp_controller:resb 1    ; Индекс контроллера
sp_lba:       resd 1    ; LBA для эмулируемого образа диска
sp_devspec:   resw 1    ; Информация об устройстве IDE/SCSI
sp_buffer:    resw 1    ; Буфер, предоставленный пользователем
sp_loadseg:   resw 1    ; Сегмент загрузки
sp_sectors:   resw 1    ; Количество секторов
sp_chs:       resb 3    ; Симулированная геометрия CHS
sp_dummy:     resb 1    ; Вспомогательная переменная, которую можно перезаписать

;
; Пакет параметров привода для EBIOS
;
        alignb 8
drive_params: resw 1    ; Размер буфера
dp_flags:     resw 1    ; Флаги информации
dp_cyl:       resd 1    ; Физические цилиндры
dp_head:      resd 1    ; Физические головки
dp_sec:       resd 1    ; Физические секторы на трек
dp_totalsec:  resd 2    ; Общее количество секторов
dp_secsize:   resw 1    ; Размер сектора в байтах
dp_dpte:      resd 1    ; Таблица параметров устройства
dp_dpi_key:   resw 1    ; Ключ DPI (0xBEDD, если остальная информация валидна)
dp_dpi_len:   resb 1    ; Длина DPI
        resb 1
        resw 1
dp_bus:       resb 4    ; Тип шины (например, PCI)
dp_interface: resb 8    ; Тип интерфейса (например, ATA, SCSI)
db_i_path:    resd 2    ; Путь интерфейса
db_d_path:    resd 2    ; Путь устройства
        resb 1
db_dpi_csum:  resb 1    ; Контрольная сумма информации DPI

;
; Пакет адресации диска для EBIOS
;
        alignb 8
dapa:         resw 1    ; Размер пакета
.count:       resw 1    ; Количество блоков
.off:         resw 1    ; Смещение буфера
.seg:         resw 1    ; Сегмент буфера
.lba:         resd 2    ; LBA (младшее и старшее слово)

;
; Пакет спецификации для эмуляции образа диска
;
        alignb 8
dspec_packet: resb 1    ; Размер пакета
dsp_media:    resb 1    ; Тип носителя
dsp_drive:    resb 1    ; Номер привода
dsp_controller:resb 1    ; Индекс контроллера
dsp_lba:      resd 1    ; LBA для эмулируемого образа диска
dsp_devspec:  resw 1    ; Информация об устройстве IDE/SCSI
dsp_buffer:   resw 1    ; Буфер, предоставленный пользователем
dsp_loadseg:  resw 1    ; Сегмент загрузки
dsp_sectors:  resw 1    ; Количество секторов
dsp_chs:      resb 3    ; Симулированная геометрия CHS
dsp_dummy:    resb 1    ; Вспомогательная переменная, которую можно перезаписать

        alignb 4
_spec_end     equ $      ; Конец спецификации
_spec_len     equ _spec_end - _spec_start  ; Длина спецификации

        section .init  ; Секция инициализации


;Зарезервированные области памяти: код задаёт различные области памяти (секции .earlybss и .init) для хранения переменных и данных, которые нужны для взаимодействия с BIOS и загрузки данных с диска. Эта память должна быть инициализирована до того, как загрузчик начнёт загрузку основной операционной системы.

;Буферизация данных: создаётся буфер для чтения данных с CD-ROM. Данные из сектора диска загружаются в этот буфер, а затем обрабатываются загрузчиком.

;Взаимодействие с BIOS и CD-ROM: создаются структуры данных, которые BIOS использует для чтения данных с CD-ROM в режиме "без эмуляции" через стандарт El Torito. BIOS передаёт информацию об устройстве (например, номер привода и параметры диска), что позволяет загрузчику корректно загружать операционную систему.


;  2. ####

;; ###################################################
;; Основная точка входа программы. 
;; Поскольку BIOS содержит баги, сначала загружается только первый сектор CD-ROM (2K),
;; и основная задача загрузчика — загрузить остальную часть данных.
;;
        global StackBuf
StackBuf equ STACK_TOP-44        ; Буфер для стека (44 байта нужно для
                                 ; выполнения цепной загрузки с загрузочного сектора)
        global OrigESDI
OrigESDI equ StackBuf-4          ; Верхний dword на стеке
StackHome equ OrigESDI           ; Начальный адрес стека

;; Начало загрузчика
bootsec equ $

_start:
        cli                      ; Отключить прерывания
        jmp 0:_start1            ; Длинный прыжок, чтобы канонизировать адрес
        times 8-($-$$) nop       ; Заполнение до смещения файла 8 байт

;; Эта таблица заполняется утилитой mkisofs с использованием опции -boot-info-table.
;; Если таблица не заполняется, используются значения по умолчанию.
        global iso_boot_info
iso_boot_info:
bi_pvd:      dd 16               ; LBA (логический блок) основного тома
bi_file:     dd 0                ; LBA загрузочного файла
bi_length:   dd 0xdeadbeef       ; Длина загрузочного файла
bi_csum:     dd 0xdeadbeef       ; Контрольная сумма загрузочного файла
bi_reserved: times 10 dd 0xdeadbeef ; Зарезервировано
bi_end:

;; Специальная точка входа для режима гибридного диска (гибридный режим).
;; Значения, которые были сохранены в стек:
;; - смещение раздела (qword)
;; - ES
;; - DI
;; - DX (с номером привода)
;; - Число головок и секторов CBIOS
;; - Флаг EBIOS
;; (верх стека)
;; Если используется старая версия isohybrid, смещение раздела может отсутствовать.
;; Можно проверить это, сравнив значение sp с 0x7c00.
%ifndef DEBUG_MESSAGES
_hybrid_signature:
           dd 0x7078c0fb         ; Произвольное число

_start_hybrid:
        pop cx                   ; Флаг EBIOS
        pop word [cs:bsSecPerTrack] ; Число секторов на трек
        pop word [cs:bsHeads]     ; Число головок
        pop dx                    ; Регистр DX (содержит номер привода)
        pop di                    ; Регистр DI
        pop es                    ; Сегментный регистр ES
        xor eax, eax              ; Обнуление регистра EAX
        xor ebx, ebx              ; Обнуление регистра EBX
        cmp sp,7C00h              ; Проверка на наличие смещения раздела
        jae .nooffset             ; Переход, если смещения нет
        pop eax                   ; Считывание смещения раздела в EAX
        pop ebx                   ; Считывание дополнительного смещения в EBX
.nooffset:
        mov si,bios_cbios         ; Указатель на BIOS CBIOS
        jcxz _start_common        ; Если CX=0, переход к общему коду
        mov si,bios_ebios         ; Указатель на BIOS EBIOS
        jmp _start_common         ; Переход к общему коду
%endif

_start1:
        mov si,bios_cdrom         ; Указатель на BIOS CD-ROM
        xor eax,eax               ; Обнуление регистра EAX
        xor ebx,ebx               ; Обнуление регистра EBX
_start_common:
        mov [cs:InitStack],sp     ; Сохранение начального указателя стека
        mov [cs:InitStack+2],ss   ; Сохранение сегмента стека
        xor cx,cx                 ; CX = 0
        mov ss,cx                 ; Установка сегмента стека на 0
        mov sp,StackBuf           ; Установка стека на буфер стека
        push es                   ; Сохранение начального ES:DI -> $PnP указателя
        push di
        mov ds,cx                 ; DS = 0
        mov es,cx                 ; ES = 0
        mov fs,cx                 ; FS = 0
        mov gs,cx                 ; GS = 0
        sti                       ; Включение прерываний
        cld                       ; Сброс флага направления

        mov [Hidden],eax          ; Сохранение EAX в Hidden
        mov [Hidden+4],ebx        ; Сохранение EBX в Hidden+4

        mov [BIOSType],si         ; Сохранение типа BIOS
        mov eax,[si]              ; Получение типа BIOS
        mov [GetlinsecPtr],eax    ; Сохранение указателя на функцию чтения сектора

        ;; Отображение информации о загрузке
        mov si,syslinux_banner    ; Указатель на баннер SYSLINUX
        call writestr_early       ; Вывод строки

%ifdef DEBUG_MESSAGES
        mov si,copyright_str      ; Если включен режим отладки, вывод копирайта
%else
        mov si,[BIOSName]         ; Иначе выводим имя BIOS
%endif
        call writestr_early       ; Вывод строки

        ;; Подсчёт контрольной суммы для байт 64-2048
initial_csum:
        xor edi,edi               ; Обнуление регистра EDI
        mov si,bi_end             ; Указатель на конец блока iso_boot_info
        mov cx,(SECTOR_SIZE-64) >> 2 ; CX = количество dword'ов для подсчёта контрольной суммы
.loop:
        lodsd                     ; Чтение dword из сегмента DS:SI в EAX
        add edi,eax               ; Добавление к сумме
        loop .loop                ; Цикл, пока CX != 0
        mov [FirstSecSum],edi     ; Сохранение контрольной суммы

        mov [DriveNumber],dl      ; Сохранение номера привода

%ifdef DEBUG_MESSAGES
        mov si,startup_msg        ; Сообщение при старте (для отладки)
        call writemsg
        mov al,dl                 ; Вывод номера привода
        call writehex2
        call crlf_early
%endif

        ;; Инициализация буферов пакетов spec
        mov di,_spec_start
        mov cx,_spec_len >> 2
        xor eax,eax
        rep stosd

        ;; Инициализация длины полей в различных пакетах
        mov byte [spec_packet],13h ; Размер пакета spec_packet
        mov byte [drive_params],30 ; Размер пакета drive_params
        mov byte [dapa],16         ; Размер пакета dapa
        mov byte [dspec_packet],13h; Размер пакета dspec_packet

        ;; Инициализация остальных полей
        inc word [dsp_sectors]     ; Увеличение числа секторов

        ;; Проверка, не эмулируем ли мы CD-ROM
        cmp word [BIOSType],bios_cdrom
        jne found_drive            ; Если это CD-ROM, пропустить обработку пакета spec

        ;; Получение статуса эмуляции диска
        mov ax,4B01h               ; Команда для получения статуса эмуляции
        mov dl,[DriveNumber]       ; Загрузка номера привода в DL
        mov si,spec_packet         ; Указатель на пакет spec_packet
        call int13                 ; Вызов прерывания 13h для работы с BIOS
        jc award_hack              ; Переход в случае ошибки (Award BIOS)

        ;; Проверка правильности номера привода в spec_packet
        mov dl,[DriveNumber]
        cmp [sp_drive],dl          ; Сравнение с номером привода
        jne spec_query_failed      ; Ошибка, если номера не совпадают

%ifdef DEBUG_MESSAGES
        mov si,spec_ok_msg         ; Сообщение об успешной обработке пакета spec
        call writemsg
        mov al,byte [sp_drive]
        call writehex2
        call crlf_early
%endif


;1. Основная точка входа (_start):
;Код начинается с отключения прерываний (cli) и подготовки памяти и стека для дальнейшей загрузки.
;Используется длинный прыжок (jmp 0:_start1) для канонизации адреса (установки точного сегмента и смещения).

;2. Инициализация стека и переменных:
;В этой части загружается и инициализируется стек, который будет использоваться в процессе загрузки.
;Сохраняются важные регистры, такие как ES:DI, и подготавливаются сегменты памяти (DS, ES, FS, GS).

;3. Подсчёт контрольной суммы:
;Рассчитывается контрольная сумма загруженных данных, что важно для проверки целостности и корректности загрузочных файлов.

;4. Работа с BIOS и определение типа диска:
;Используется вызов BIOS через прерывание int13h, чтобы получить информацию о статусе эмуляции диска.
;В зависимости от типа устройства (CD-ROM или диск), выполняются разные операции.

;5. Инициализация буферов пакетов:
;Подготавливаются буферы для различных пакетов данных, таких как spec_packet, используемые при работе с BIOS и устройствами.

;  3. ####

found_drive:
	
	; Если у нас есть таблица загрузочной информации (Boot Info Table), 
	; то всё упрощается. Если нет, придётся делать предположения, 
	; такие как:
	; - только одна сессия на диске
	; - один загрузочный файл (без меню)

	cmp dword [bi_file],0		; Проверяем, есть ли адрес кода для загрузки
	jne found_file			; Если есть таблица загрузочной информации

%ifdef DEBUG_MESSAGES
	mov si,noinfotable_msg
	call writemsg
%endif

	; Если таблицы нет, пробуем найти адрес в пакете spec_packet.
	mov eax,[sp_lba]
	and eax,eax
	jz set_file			; Если адрес найден, продолжаем

%ifdef DEBUG_MESSAGES
	mov si,noinfoinspec_msg
	call writemsg
%endif

	; Если spec_packet тоже не помог, пробуем считать адрес Boot Record Volume (BRV).
	mov eax,17			; Предполагаемый адрес BRV
	mov bx,trackbuf
	call getonesec			; Считываем один сектор

	mov eax,[trackbuf+47h]		; Получаем адрес загрузочного каталога
	mov bx,trackbuf
	call getonesec			; Считываем загрузочный каталог

	mov eax,[trackbuf+28h]		; Получаем первый загрузочный файл
	; Надеемся, что это правильный файл.

set_file:
	mov [bi_file],eax			; Устанавливаем адрес загрузочного файла

found_file:
	; Устанавливаем размеры загружаемого файла
	mov eax,[bi_length]
	sub eax,SECTOR_SIZE-3		; Вычитаем размер загруженного сектора
	shr eax,2			; Преобразуем байты в dword'ы
	mov [ImageDwords],eax		; Сохраняем размер файла в dword'ах
	add eax,((SECTOR_SIZE-1) >> 2)
	shr eax,SECTOR_SHIFT-2		; Преобразуем dword'ы в сектора
	mov [ImageSectors],ax		; Сохраняем размер файла в секторах

	mov eax,[bi_file]		; Адрес кода для загрузки
	inc eax				; Не загружаем bootstrap код повторно
%ifdef DEBUG_MESSAGES
	mov si,offset_msg
	call writemsg
	call writehex8
	call crlf_early
%endif

	; Загружаем остальную часть файла. Учитываем возможные проблемы BIOS с
	; загрузкой больших файлов, используя собственный механизм.

MaxLMA equ 384*1024		; Ограничение на загрузку (384 Кб)

	mov bx,((TEXT_START+2*SECTOR_SIZE-1) & ~(SECTOR_SIZE-1)) >> 4
	mov bp,[ImageSectors]
	push bx			; Сохраняем сегментный адрес для загрузки

.more:
	push bx			; Сегментный адрес
	push bp			; Количество секторов
	mov es,bx
	mov cx,0xfff
	and bx,cx
	inc cx
	sub cx,bx
	shr cx,SECTOR_SHIFT - 4
	jnz .notaligned
	mov cx,0x10000 >> SECTOR_SHIFT	; Возможен полный 64К сегмент
.notaligned:
	cmp bp,cx
	jbe .ok
	mov bp,cx
.ok:
	xor bx,bx
	push bp
	push eax
	call getlinsec		; Считываем сектора с диска
	pop eax
	pop cx
	movzx edx,cx
	pop bp
	pop bx

	shl cx,SECTOR_SHIFT - 4
	add bx,cx
	add eax,edx
	sub bp,dx
	jnz .more

	; Перемещаем загруженный образ и проверяем контрольную сумму
	pop ax				; Загружаем сегментный адрес
	mov bx,(TEXT_START + SECTOR_SIZE) >> 4
	mov ecx,[ImageDwords]
	mov edi,[FirstSecSum]		; Контрольная сумма первого сектора
	xor si,si

move_verify_image:
.setseg:
	mov ds,ax
	mov es,bx
.loop:
	mov edx,[si]
	add edi,edx
	dec ecx
	mov [es:si],edx
	jz .done
	add si,4
	jnz .loop
	add ax,1000h
	add bx,1000h
	jmp .setseg
.done:
	mov ax,cs
	mov ds,ax
	mov es,ax

	; Проверяем контрольную сумму загруженного образа
	cmp [bi_csum],edi
	je integrity_ok

	mov si,checkerr_msg
	call writemsg
	jmp kaboom

integrity_ok:
%ifdef DEBUG_MESSAGES
	mov si,allread_msg
	call writemsg
%endif
	jmp all_read			; Переход к основному коду

;Поиск загрузочного файла:
;Сначала проверяется наличие таблицы загрузочной информации (Boot Info Table). Если она есть, поиск файла упрощается.
;Если таблицы нет, пытается найти файл, используя другие методы, такие как spec_packet.

;Чтение загрузочного каталога:
;В случае неудачи программа пытается считать загрузочный каталог, который содержит информацию о загрузочном файле.

;Загрузка файла:
;Программа загружает файл по частям, учитывая возможные ограничения BIOS. Для этого код разбивает файл на сектора и загружает их последовательно.
;Проверка контрольной суммы:

;После загрузки всего файла производится проверка контрольной суммы, чтобы убедиться, что данные не были повреждены.

;  4. ###

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Начало BrokenAwardHack --- 10-ноя-2002           Knut_Petersen@t-online.de
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Проблема с некоторыми версиями BIOS AWARD ...
;; сектор загрузки будет загружен и выполнен корректно, но, поскольку
;; вектор int 13 указывает на неверный код в BIOS, каждая попытка
;; загрузить спецификационный пакет будет неудачной. Мы сканируем на
;; наличие эквивалента кода:
;;
;;	mov	ax,0201h
;;	mov	bx,7c00h
;;	mov	cx,0006h
;;	mov	dx,0180h
;;	pushf
;;	call	<direct far>
;;
;; и используем <direct far> как новый вектор для int 13. Этот код
;; используется для загрузки кода загрузчика в память, и не должно
;; быть причин для его изменения сейчас или в будущем. Нет кодов,
;; которые используют кодировки относительно IP, так что сканирование
;; просто. Если мы найдем указанный код в BIOS, мы можем быть уверены,
;; что работаем на машине с неисправным BIOS AWARD ...
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

%ifdef DEBUG_MESSAGES
award_notice	db	"Попытка использования BrokenAwardHack ...",CR,LF,0
award_not_orig	db	"BAH: Оригинальный вектор Int 13   : ",0
award_not_new	db	"BAH: Вектор Int 13 изменен на    : ",0
award_not_succ	db	"BAH: УСПЕХ",CR,LF,0
award_not_fail	db	"BAH: НЕУДАЧА",0
award_not_crlf	db	CR,LF,0
%endif

award_oldint13	dd	0	; Переменная для хранения оригинального вектора INT 13
award_string	db	0b8h,1,2,0bbh,0,7ch,0b9h,6,0,0bah,80h,1,09ch,09ah ; Строка для поиска

award_hack:
	mov	si,spec_err_msg		; Устанавливаем сообщение об ошибке для неудачи с пакетом спецификаций
	call	writemsg		; Выводим сообщение об ошибке

%ifdef DEBUG_MESSAGES
	mov	si,award_notice		; Информируем о попытке использования BrokenAwardHack
	call	writemsg
	mov	si,award_not_orig	; Отображаем оригинальный адрес вектора INT 13
	call	writemsg
%endif

	mov	eax,[13h*4]		; Получаем оригинальный адрес вектора INT 13
	mov	[award_oldint13],eax	; Сохраняем его для последующего восстановления

%ifdef DEBUG_MESSAGES
	call	writehex8		; Показываем оригинальный адрес вектора
	mov	si,award_not_crlf	; Добавляем перевод строки
	call	writestr_early
%endif

	push	es			; Сохраняем регистр ES
	mov	ax,0f000h		; Устанавливаем ES в сегмент BIOS
	mov	es,ax
	cld				; Очищаем флаг направления
	xor	di,di			; Начинаем сканирование с ES:DI = f000:0
award_loop:
	push	di			; Сохраняем регистр DI
	mov	si,award_string		; Загружаем строку для поиска
	mov	cx,7			; Длина строки
	repz	cmpsw			; Сравниваем строку
	pop	di			; Восстанавливаем регистр DI
	jcxz	award_found		; Если строка найдена, переходим к award_found
	inc	di			; Увеличиваем DI
	jno	award_loop		; Продолжаем сканирование, если нет переполнения

award_failed:
	pop	es			; Восстанавливаем регистр ES

%ifdef DEBUG_MESSAGES
	mov	si,award_not_fail	; Показываем сообщение о неудаче поиска строки
	call	writemsg
%endif

	mov	eax,[award_oldint13]	; Восстанавливаем оригинальный вектор INT 13
	or	eax,eax
	jz	spec_query_failed	; Если нет оригинального вектора, пробуем другие методы
	mov	[13h*4],eax		; Устанавливаем вектор INT 13 обратно
	jmp	spec_query_failed	; Переходим к обработке ошибок

award_found:
	mov	eax,[es:di+0eh]		; Загружаем возможный новый адрес вектора INT 13
	pop	es			; Восстанавливаем регистр ES

	cmp	eax,[award_oldint13]	; Проверяем, совпадает ли новый адрес с оригинальным
	jz	award_failed		; Если совпадает, завершаем
	mov	[13h*4],eax		; Устанавливаем новый вектор INT 13

%ifdef DEBUG_MESSAGES
	push	eax			; Показываем новый вектор INT 13
	mov	si,award_not_new	; Отображаем новый адрес
	call	writemsg
	pop	eax
	call	writehex8		; Показываем новый адрес
	mov	si,award_not_crlf	; Добавляем перевод строки
	call	writestr_early
%endif

	mov	ax,4B01h		; Пытаемся прочитать спецификационный пакет
	mov	dl,[DriveNumber]	; Номер диска для чтения
	mov	si,spec_packet		; Адрес спецификационного пакета
	int	13h			; Вызов прерывания BIOS
	jc	award_fail2		; Переходим к неудаче, если чтение не удалось

%ifdef DEBUG_MESSAGES
	mov	si,award_not_succ	; Показываем успешное чтение спецификационного пакета
	call	writemsg
%endif

	jmp	found_drive		; Переходим к разделу, где найден диск


;Функциональность этой части кода
;Этот фрагмент кода реализует хак "BrokenAwardHack", предназначенный для исправления проблем с некоторыми версиями BIOS AWARD. Проблема заключается в том, что BIOS может неправильно обрабатывать операции, связанные с чтением спецификационных пакетов (например, с CD-ROM).

;Вывод сообщений: Если включены отладочные сообщения, выводится информация о попытке использования хаков и состояние оригинального вектора INT 13.

;Сохранение оригинального вектора INT 13: Код сохраняет текущий адрес вектора INT 13 для последующего восстановления.

;Сканирование BIOS на наличие проблемы: Код сканирует память BIOS на наличие определенного кода, который указывает на неисправную версию BIOS AWARD.

;Обработка случая с неисправным BIOS: Если код обнаружен, он заменяет вектор INT 13 на новый адрес, который будет корректно обрабатывать операции чтения дисков. После замены вектора повторяется попытка прочитать спецификационный пакет.

;Восстановление оригинального вектора INT 13: Если новый вектор не работает или не может быть установлен, код восстанавливает оригинальный вектор INT 13 и пытается другие методы обработки ошибок.

;Этот хак помогает обеспечить совместимость загрузчика с более старыми и потенциально неисправными версиями BIOS, улучшая надежность загрузки и работы с дисками.

;### 5

; 5. ###################################################
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Конец BrokenAwardHack ----            10-ноя-2002 Knut_Petersen@t-online.de
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

		; INT 13h, AX=4B01h, DL=<переданное значение> не сработал.
		; Попробуем сканировать весь диапазон 80h-FFh от конца.

spec_query_failed:

		; некоторый код был перемещен в BrokenAwardHack

		mov dl,0FFh
.test_loop:	pusha
		mov ax,4B01h
		mov si,spec_packet
		mov byte [si],13h		; Размер буфера
		call int13
		popa
		jc .still_broken

		mov si,maybe_msg
		call writemsg
		mov al,dl
		call writehex2
		call crlf_early

		cmp byte [sp_drive],dl
		jne .maybe_broken

		; Хорошо, этого достаточно...
		mov si,alright_msg
		call writemsg
.found_drive0:	mov [DriveNumber],dl
.found_drive:	jmp found_drive

		; BIOS Award 4.51 по всей видимости передает мусор в sp_drive,
		; но если это был номер диска, переданный изначально в DL,
		; считаем его "достаточным"
.maybe_broken:
		mov al,[DriveNumber]
		cmp al,dl
		je .found_drive

		; Компьютер Intel Classic R+ с BIOS Adaptec 1542CP 1.02
		; передает мусор в sp_drive, и номер диска, переданный изначально
		; в DL, не имеет установленного бита 80h.
		or al,80h
		cmp al,dl
		je .found_drive0

.still_broken:	dec dx
		cmp dl, 80h
		jnb .test_loop

		; Не найден спецификационный пакет. Некоторые особенно
		; плохие BIOS даже не реализуют функцию 4B01h, так что
		; мы не можем запросить спецификационный пакет, как бы мы ни старались.
		; Если у нас есть номер диска в DL, попробуем использовать его,
		; и если это сработает, то ладно...
		mov dl,[DriveNumber]
		cmp dl,81h			; Должен быть хотя бы 81-FF
		jb fatal_error			; Если нет, это бесполезно

		; Напишем предупреждение, чтобы указать, что мы на *очень* тонком льду
		mov si,nospec_msg
		call writemsg
		mov al,dl
		call writehex2
		call crlf_early
		mov si,trysbm_msg
		call writemsg
		jmp .found_drive		; Надеемся, что это сработает...

fatal_error:
		mov si,nothing_msg
		call writemsg

.norge:		jmp short .norge

		; Вывод информационного сообщения (DS:SI)
		; Префикс "isolinux: "
		;
writemsg:	push ax
		push si
		mov si,isolinux_str
		call writestr_early
		pop si
		call writestr_early
		pop ax
		ret

writestr_early:
		pushfd
		pushad
.top:		lodsb
		and al,al
		jz .end
		call writechr
		jmp short .top
.end:		popad
		popfd
		ret

crlf_early:	push ax
		mov al,CR
		call writechr
		mov al,LF
		call writechr
		pop ax
		ret

;Сканирование диапазона: Код пытается сканировать весь диапазон адресов от 80h до FFh, чтобы найти рабочий спецификационный пакет.

;Обработка ошибок:

;Если обнаруживается ошибка при попытке чтения спецификационного пакета, программа пытается определить рабочий номер диска.
;Если читаемое значение совпадает с переданным в регистре DL или имеет установленный бит 80h, номер диска считается корректным, и продолжается выполнение.
;Проверка корректности номера диска:

;Если полученный номер диска ниже 81h (что указывает на ошибку), программа переходит к метке fatal_error, чтобы вывести сообщение о фатальной ошибке.
;Вывод сообщений:

;Если спецификационный пакет успешно прочитан или найден, программа выводит сообщения о результатах выполнения.
;Функция writemsg используется для вывода сообщений с префиксом "isolinux: ".
;Функции writestr_early, writechr, и crlf_early отвечают за вывод строк и символов с учетом перевода строки.
;Этот код предназначен для работы в средах с нестандартными или неисправными BIOS, обеспечивая возможность загрузки и работы с дисками, даже если некоторые функции BIOS не работают должным образом.


;### 6

; 6. ###################################################
; Запись символа на экран. Существует более "совершенная"
; версия этого кода в последующем коде, поэтому мы изменяем указатель
; при необходимости.
;
writechr:
.simple:
		pushfd
		pushad
		mov ah,0Eh
		xor bx,bx
		int 10h
		popad
		popfd
		ret

;
; int13: сохранить все сегментные регистры и вызвать INT 13h.
;	Некоторые BIOS CD-ROM были обнаружены как нарушающие
;	сегментные регистры и/или отключающие прерывания.
;
int13:
		pushf
		push bp
		push ds
		push es
		push fs
		push gs
		int 13h
		mov bp,sp
		setc [bp+10]		; Передать CF вызывающему
		pop gs
		pop fs
		pop es
		pop ds
		pop bp
		popf
		ret

;
; Получить один сектор. Точка удобного входа.
;
getonesec:
		mov bp,1
		; Переход к getlinsec

;
; Получить линейные сектора - EBIOS LBA адресация, 2048-байтные сектора.
;
; Входные данные:
;	EAX	- Линейный номер сектора
;	ES:BX	- Целевой буфер
;	BP	- Количество секторов
;
		global getlinsec
getlinsec:	jmp word [cs:GetlinsecPtr]

%ifndef DEBUG_MESSAGES

;
; Во-первых, варианты, которые мы используем при загрузке с диска
; (гибридный режим). Эти версии адаптированы из эквивалентных
; процедур в ldlinux.asm.
;

;
; getlinsec_ebios:
;
; Реализация getlinsec для дискет/ЖД EBIOS (EDD)
;
getlinsec_ebios:
		xor edx,edx
		shld edx,eax,2
		shl eax,2			; Преобразовать в сектора ЖД
		add eax,[Hidden]
		adc edx,[Hidden+4]
		shl bp,2

.loop:
                push bp                         ; Оставшиеся сектора
.retry2:
		call maxtrans			; Ограничить максимальный размер передачи
		movzx edi,bp			; Секторы, которые мы собираемся прочитать
		mov cx,retry_count
.retry:

		; Формируем DAPA в стеке
		push edx
		push eax
		push es
		push bx
		push di
		push word 16
		mov si,sp
		pushad
                mov dl,[DriveNumber]
		push ds
		push ss
		pop ds				; DS <- SS
		mov ah,42h			; Расширенное чтение
		call int13
		pop ds
		popad
		lea sp,[si+16]			; Удалить DAPA
		jc .error
		pop bp
		add eax,edi			; Переместить указатель сектора
		adc edx,0
		sub bp,di			; Осталось секторов
                shl di,9			; Сектора по 512 байт
                add bx,di			; Переместить указатель буфера
                and bp,bp
                jnz .loop

                ret

.error:
		; Некоторые системы, похоже, застревают в состоянии ошибки при
		; использовании EBIOS. Это не происходит при использовании CBIOS,
		; что хорошо, так как некоторые другие системы получают сбои
		; при ожидании запуска дискет.

		pushad				; Попробовать сбросить устройство
		xor ax,ax
		mov dl,[DriveNumber]
		call int13
		popad
		loop .retry			; CX-- и переход, если не ноль

		;shr word [MaxTransfer],1	; Уменьшить размер передачи
		;jnz .retry2

		; Полный сбой. Попробовать переключиться на CBIOS.
		mov word [GetlinsecPtr], getlinsec_cbios
		;mov byte [MaxTransfer],63	; Максимальный возможный размер передачи CBIOS

		pop bp
		jmp getlinsec_cbios.loop

;
; getlinsec_cbios:
;
; Реализация getlinsec для старого CBIOS
;
getlinsec_cbios:
		xor edx,edx
		shl eax,2			; Преобразовать в сектора ЖД
		add eax,[Hidden]
		shl bp,2

.loop:
		push edx
		push eax
		push bp
		push bx

		movzx esi,word [bsSecPerTrack]
		movzx edi,word [bsHeads]
		;
		; Деление на сектора для получения (трек, сектор): мы можем иметь
		; до 2^18 треков, поэтому нам нужно использовать 32-битную арифметику.
		;
		div esi
		xor cx,cx
		xchg cx,dx		; CX <- индекс сектора (начиная с 0)
					; EDX <- 0
		; eax = номер трека
		div edi			; Преобразовать трек в головку/цил

		; Мы должны это протестировать, но это не помещается...
		; cmp eax,1023
		; ja .error

		;
		; Теперь у нас есть AX = цил, DX = головка, CX = сектор (начиная с 0),
		; BP = количество секторов, SI = bsSecPerTrack,
		; ES:BX = целевые данные
		;

		call maxtrans			; Ограничить максимальный размер передачи

		; Не должно пересекать границы трека, поэтому BP <= SI-CX
		sub si,cx
		cmp bp,si
		jna .bp_ok
		mov bp,si
.bp_ok:

		shl ah,6		; Потому что IBM был СТУПЫМ
					; и думал, что 8 бит было достаточно,
					; а затем думал, что 10 бит было достаточно...
		inc cx			; Номера секторов начинаются с 1, увы
		or cl,ah
		mov ch,al
		mov dh,dl
		mov dl,[DriveNumber]
		xchg ax,bp		; Количество секторов для передачи
		mov ah,02h		; Чтение секторов
		mov bp,retry_count
.retry:
		pushad
		call int13
		popad
		jc .error
.resume:
		movzx ecx,al		; ECX <- переданные сектора
		shl ax,9		; Преобразовать сектора в AL в байты в AX
		pop bx
		add bx,ax
		pop bp
		pop eax
		pop edx
		add eax,ecx
		sub bp,cx
		jnz .loop
		ret

.error:
		dec bp
		jnz .retry

		xchg ax,bp		; Переданные сектора <- 0
		shr word [MaxTransfer],1
		jnz .resume
		jmp disk_error

;
; Уменьшить BP до MaxTransfer
;
maxtrans:
		cmp bp,[MaxTransfer]
		jna .ok
		mov bp,[MaxTransfer]
.ok:		ret

%endif

;Функциональность этой части кода
;writechr:

;Функция: Записывает один символ на экран, используя прерывание INT 10h с функцией 0Eh (вывод символа в текстовом режиме).
;Примечание: Это упрощенная версия функции записи символа, предназначенная для использования в случае, если более сложная версия не доступна.
;int13:

;Функция: Выполняет вызов прерывания INT 13h, сохраняя и восстанавливая все сегментные регистры. Это важно для обеспечения корректной работы при взаимодействии с некоторыми CD-ROM BIOS, которые могут нарушать состояние сегментных регистров или отключать прерывания.
;getonesec:

;Функция: Устанавливает количество секторов в 1 и переходит к функции getlinsec, которая будет заниматься получением секторов.
;getlinsec:

;Функция: Указывает на конкретную реализацию функции получения линейных секторов. Вызывается через указатель GetlinsecPtr, который может указывать на разные реализации в зависимости от контекста.
;getlinsec_ebios:

;Функция: Реализует чтение секторов с дисков через EBIOS (Extended BIOS). Преобразует линейный номер сектора в сектор ЖД, а затем читает данные, проверяя и обрабатывая ошибки.
;Примечания: Использует расширенные функции для чтения и может повторять попытки в случае ошибок. Если чтение через EBIOS не удается, переключается на альтернативный метод (CBIOS).
;getlinsec_cbios:

;Функция: Реализует чтение секторов через старый CBIOS (Legacy BIOS). Преобразует номер сектора в трек и головку, затем выполняет чтение секторов, проверяя и обрабатывая ошибки.
;Примечания: Выполняет чтение секторов, разделяя их по трекам и головкам. Если возникает ошибка, пытается повторить попытку чтения или переключается на обработку ошибки.
;maxtrans:

;Функция: Ограничивает количество секторов для передачи до значения, указанного в MaxTransfer.


;### 7

;;;  7. ###################################################
; Это вариант для реальных CD-ROM-дисков:
; LBA, 2К секторов, специальная обработка ошибок.
;

getlinsec_cdrom:
    mov si, dapa            ; Загрузить DAPA (структура адресации)
    mov [si+4], bx          ; Установить указатель на буфер
    mov [si+6], es
    mov [si+8], eax         ; Установить указатель на сектор
.loop:
    push bp                 ; Сохранить количество оставшихся секторов
    cmp bp, [MaxTransferCD] ; Проверить, не превышает ли bp максимальный размер передачи
    jbe .bp_ok              ; Если bp <= MaxTransferCD, переход к .bp_ok
    mov bp, [MaxTransferCD] ; Иначе установить bp в MaxTransferCD
.bp_ok:
    mov [si+2], bp          ; Установить количество секторов для передачи
    push si                 ; Сохранить указатель на DAPA
    mov dl, [DriveNumber]   ; Загрузить номер диска
    mov ah, 42h             ; Установить функцию Extended Read
    call xint13             ; Вызвать INT 13h
    pop si                  ; Восстановить указатель на DAPA
    pop bp                  ; Восстановить количество оставшихся секторов
    movzx eax, word [si+2]  ; Получить количество считанных секторов
    add [si+8], eax         ; Обновить указатель на сектор
    sub bp, ax              ; Уменьшить количество оставшихся секторов
    shl ax, SECTOR_SHIFT-4  ; Перевести 2048-байтные сектора в сегменты
    add [si+6], ax          ; Обновить указатель на буфер
    and bp, bp              ; Проверить, не ноль ли bp
    jnz .loop               ; Если bp не ноль, повторить цикл
    mov eax, [si+8]         ; Получить следующий сектор
    ret

    ; INT 13h с повторными попытками
xint13:
    mov byte [RetryCount], retry_count
.try:
    pushad
    call int13
    jc .error
    add sp, byte 8*4       ; Очистить стек
    ret
.error:
    mov [DiskError], ah    ; Сохранить код ошибки
    popad
    mov [DiskSys], ax      ; Сохранить номер системного вызова
    dec byte [RetryCount]  ; Уменьшить счетчик повторных попыток
    jz .real_error         ; Если попытки закончились, переход к .real_error
    push ax
    mov al, [RetryCount]
    mov ah, [dapa+2]       ; Количество переданных секторов
    cmp al, 2              ; Только 2 попытки осталось
    ja .nodanger
    mov ah, 1              ; Уменьшить размер передачи до 1
    jmp short .setsize
.nodanger:
    cmp al, retry_count-2  ; Проверить, не первая ли попытка
    ja .again             ; Если нет, попытаться снова
    shr ah, 1              ; Иначе уменьшить размер передачи
    adc ah, 0              ; Но не до нуля
.setsize:
    mov [MaxTransferCD], ah
    mov [dapa+2], ah
.again:
    pop ax
    jmp .try

.real_error:
    mov si, diskerr_msg
    call writemsg
    mov al, [DiskError]
    call writehex2
    mov si, oncall_str
    call writestr_early
    mov ax, [DiskSys]
    call writehex4
    mov si, ondrive_str
    call writestr_early
    mov al, dl
    call writehex2
    call crlf_early
    ; Переход к аварийному завершению

; kaboom: вывод сообщения и завершение работы. Ожидание нажатия клавиши
;	  затем выполнение жесткой перезагрузки.
;
    global kaboom
disk_error:
kaboom:
    RESET_STACK_AND_SEGS AX
    mov si, bailmsg
    pm_call pm_writestr
    pm_call pm_getchar
    cli
    mov word [BIOS_magic], 0 ; Холодная перезагрузка
    jmp 0F000h:0FFF0h       ; Адрес вектора сброса

;;;  8. ###################################################
; -----------------------------------------------------------------------------
;  Общие модули, необходимые в первом секторе
; -----------------------------------------------------------------------------

%include "writehex.inc"    ; Модули для шестнадцатеричного вывода

; -----------------------------------------------------------------------------
; Данные, которые должны быть в первом секторе
; -----------------------------------------------------------------------------

    global syslinux_banner, copyright_str
syslinux_banner   db CR, LF, MY_NAME, ' ', VERSION_STR, ' ', DATE_STR, ' ', 0
copyright_str     db ' Copyright (C) 1994-'
    asciidec YEAR
    db ' H. Peter Anvin et al', CR, LF, 0
isolinux_str      db 'isolinux: ', 0
%ifdef DEBUG_MESSAGES
startup_msg:      db 'Starting up, DL = ', 0
spec_ok_msg:      db 'Loaded spec packet OK, drive = ', 0
secsize_msg:      db 'Sector size ', 0
offset_msg:      db 'Main image LBA = ', 0
verify_msg:      db 'Image csum verified.', CR, LF, 0
allread_msg:     db 'Image read, jumping to main code...', CR, LF, 0
%endif
noinfotable_msg   db 'No boot info table, assuming single session disk...', CR, LF, 0
noinfoinspec_msg  db 'Spec packet missing LBA information, trying to wing it...', CR, LF, 0
spec_err_msg:     db 'Loading spec packet failed, trying to wing it...', CR, LF, 0
maybe_msg:       db 'Found something at drive = ', 0
alright_msg:     db 'Looks reasonable, continuing...', CR, LF, 0
nospec_msg:      db 'Extremely broken BIOS detected, last attempt with drive = ', 0
nothing_msg:     db 'Failed to locate CD-ROM device; boot failed.', CR, LF
trysbm_msg:      db 'See http://syslinux.zytor.com/sbm for more information.', CR, LF, 0
diskerr_msg:     db 'Disk error ', 0
oncall_str:      db ', AX = ',0
ondrive_str:     db ', drive ', 0
checkerr_msg:    db 'Image checksum error, sorry...', CR, LF, 0

err_bootfailed   db CR, LF, 'Boot failed: press a key to retry...'
bailmsg          equ err_bootfailed
crlf_msg         db CR, LF
null_msg         db 0

bios_cdrom_str    db 'ETCD', 0
%ifndef DEBUG_MESSAGES
bios_cbios_str    db 'CHDD', 0
bios_ebios_str    db 'EHDD' ,0
%endif

    alignz 4
    global bios_cdrom
bios_cdrom:   dw getlinsec_cdrom, bios_cdrom_str
%ifndef DEBUG_MESSAGES
bios_cbios:   dw getlinsec_cbios, bios_cbios_str
bios_ebios:   dw getlinsec_ebios, bios_ebios_str
%endif

; Максимальные размеры передачи
MaxTransfer     dw 127              ; Жесткие диски
MaxTransferCD   dw 32               ; CD-диски

rl_checkpt      equ $               ; Должен быть <= 800h

    ; Это заполняет до конца сектора 0 и выдает ошибку при переполнении.
    times 2048-($-$$) db 0

; ----------------------------------------------------------------------------
;  Конец кода и данных, которые должны быть в первом секторе
; ----------------------------------------------------------------------------

    section .text16

all_read:

; Тестовые трейсеры
    TRACER 'T'
    TRACER '>'

;
; Общий код инициализации
;
%include "init.inc"

; Сообщаем пользователю, что загрузчик запущен
%ifndef DEBUG_MESSAGES            ; Обычные сообщения загружаются только в режиме отладки
    mov si, copyright_str
    pm_call pm_writestr
%endif

;
; Теперь мы готовы начать выполнение основной задачи. Сначала загружаем
; конфигурационный файл (если имеется) и разбираем его.
;
; В предыдущих версиях я избегал использования 32-битных регистров из-за
; слухов о том, что некоторые BIOS могут случайным образом изменять верхнюю
; половину 32-битных регистров. Однако, если такие BIOS еще существуют, то
; они вряд ли будут пытаться установить Linux...
;
; Код все еще содержит 16-битные операции. Удаление их было бы сложно.
; Возможно, имеет смысл вернуть их, если мы будем загружать ELKS.
;

;
; Теперь нам нужно обнаружить реальные структуры данных файловой системы.
; mkisofs дал нам указатель на основной томовой дескриптор
; (который будет на 16 только для одно-сессионного диска!); из PVD
; мы сможем найти все, что нам нужно знать.
;
init_fs:
    pushad
    mov eax, ROOT_FS_OPS
    mov dl, [DriveNumber]
    cmp word [BIOSType], bios_cdrom
    sete dh                        ; 1 для CD-ROM, 0 для гибридного режима
    jne .hybrid
    movzx ebp, word [MaxTransferCD]
    jmp .common
.hybrid:
    movzx ebp, word [MaxTransfer]
.common:
    mov ecx, [Hidden]
    mov ebx, [Hidden+4]
    mov si, [bsHeads]
    mov di, [bsSecPerTrack]
    pm_call pm_fs_init
    pm_call load_env32
enter_command:
auto_boot:
    jmp kaboom        ; load_env32() не должен возвращать управление. Если
                        ; это произойдет, то будет вызван kaboom!
    popad

    section .rodata
    alignz 4
ROOT_FS_OPS:
    extern iso_fs_ops
    dd iso_fs_ops
    dd 0

    section .text16

%ifdef DEBUG_TRACERS
;
; Отладочная функция для печати символа с минимальным влиянием на код
;
debug_tracer:   pushad
    pushfd
    mov bp, sp
    mov bx, [bp+9*4]   ; Получить адрес возврата
    mov al, [cs:bx]    ; Получить байт данных
    inc word [bp+9*4]  ; Перейти к байту данных
    call writechr
    popfd
    popad
    ret
%endif ; DEBUG_TRACERS

    section .bss16
    alignb 4
ThisKbdTo        resd 1            ; Временное хранилище для KbdTimeout
ThisTotalTo      resd 1            ; Временное хранилище для TotalTimeout
KernelExtPtr     resw 1            ; Во время поиска, конечный нулевой указатель
FuncFlag         resb 1            ; Полученные последовательности от клавиатуры
KernelType       resb 1            ; Тип ядра, если известен
    global KernelName
KernelName       resb FILENAME_MAX ; Именованное ядро

    section .text16
;
; Структура данных COM32
;
%include "com32.inc"

;
; Общий код загрузки
;
%include "localboot.inc"

; -----------------------------------------------------------------------------
;  Общие модули
; -----------------------------------------------------------------------------

%include "common.inc"        ; Универсальные модули

; -----------------------------------------------------------------------------
;  Начало секции данных
; -----------------------------------------------------------------------------

    section .data16
err_disk_image  db 'Cannot load disk image (invalid file)?', CR, LF, 0

    section .bss16
    global OrigFDCTabPtr
OrigFDCTabPtr   resd 1            ; Сохранение оригинального указателя на FDCTab



;Объяснение кода
;getlinsec_cdrom
;Этот фрагмент кода отвечает за чтение секторов с CD-ROM-диска с использованием LBA-адресации и 2K секторов. Применяется специальная обработка ошибок и попытки повторного чтения:

;DAPA (Device Address Packet Area): Загрузка структуры DAPA с адресами буфера и сектора.
;loop: Цикл чтения секторов.
;Проверяется, не превышает ли количество секторов значение MaxTransferCD.
;Запускается чтение с помощью xint13, обновляются указатели на сектор и буфер.
;xint13: Выполняет вызов INT 13h с повторными попытками в случае ошибки.
;При возникновении ошибки код уменьшает размер передачи или выполняет другие попытки.
;kaboom
;Этот раздел кода выполняет действия в случае критической ошибки чтения диска:

;Вывод сообщения об ошибке и информация о сбое.
;Перезагрузка системы: Выполняется сброс и жесткая перезагрузка.
;Общие модули и данные
;writehex.inc: Включает модули для вывода данных в шестнадцатеричном формате.

;Сегмент .text16: Основная часть кода для инициализации и выполнения загрузчика:

;init_fs: Инициализация файловой системы, определение типа BIOS (CD-ROM или гибридный режим), вызов функции load_env32 для загрузки конфигураций.
;auto_boot: Если load_env32 возвращает управление, происходит вызов функции kaboom.
;Строки и сообщения:

;syslinux_banner, copyright_str: Информация о версии и авторе.
;Ошибочные сообщения: Информируют о проблемах с загрузкой и ошибках чтения.
;bios_cdrom, bios_cbios, bios_ebios: Указатели на функции чтения секторов для различных типов BIOS.

;Максимальные размеры передачи:

;MaxTransfer: Максимальный размер передачи для жестких дисков.
;MaxTransferCD: Максимальный размер передачи для CD-ROM.
;Структуры и переменные:

;KernelName, KernelType: Хранение информации о ядре и его типе.
;OrigFDCTabPtr: Указатель на таблицу FDCTab, используется для очистки оборудования.
;Обратите внимание
;Этот код является частью загрузчика, который выполняет чтение секторов с диска, инициализацию файловой системы и обработку ошибок. Основные операции включают использование различных методов доступа к дискам, обработку ошибок и обеспечение совместимости с различными типами BIOS.

;Код, представляет собой часть загрузчика для операционной системы, но не загружает само ядро ОС непосредственно. Вместо этого он выполняет несколько важных функций, связанных с подготовкой к загрузке ядра:

;Обработка ошибок и выполнение поиска устройства: Код содержит логику для поиска и идентификации устройства, с которого будет загружаться операционная система (например, CD-ROM или жесткий диск). Он проверяет ошибки и пытается различные методы чтения данных с диска.

;Чтение данных: Присутствуют функции для чтения с диска, такие как getlinsec_cdrom для CD-ROM и getlinsec_cbios для старых систем BIOS. Эти функции отвечают за чтение сектора данных с диска в память.

;Обработка конфигурационных данных: Код инициализирует файловую систему и загружает конфигурационные данные, необходимые для дальнейшей загрузки. Например, он обращается к основным структурам данных файловой системы для поиска и загрузки конфигурационного файла.

;Инициализация и переход к основной программе: После выполнения начальной настройки и подготовки код переходит к основному коду или загрузчику ядра ОС. В примере, это обозначено как jmp kaboom, что указывает на переход к следующему этапу загрузки.

;В общем, данный код отвечает за начальную стадию загрузки и подготовки среды для загрузки ядра операционной системы. Само ядро ОС будет загружено позже, после выполнения всех необходимых проверок и настройки.