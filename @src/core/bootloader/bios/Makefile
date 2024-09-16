# Названия исходных файлов и бинарных файлов
ASFILES = mbr.s ldlinux.asm
CFILES = syslinux.c
BINFILES = mbr.bin ldlinux.bin syslinux.bin

# Компиляторы
AS = nasm
CC = gcc

# Опции компилятора
ASFLAGS = -f bin
CFLAGS = -ffreestanding -nostdlib -nostartfiles -nodefaultlibs

# Правило по умолчанию
all: $(BINFILES)

# Правило для компиляции файлов ассемблера
%.bin: %.s
	$(AS) $(ASFLAGS) $< -o $@

%.bin: %.asm
	$(AS) $(ASFLAGS) $< -o $@

# Правило для компиляции файлов C
syslinux.bin: syslinux.c
	$(CC) $(CFLAGS) -o $@ $<

# Очистка сгенерированных файлов
clean:
	rm -f $(BINFILES)

.PHONY: all clean
```

### Как использовать:

#1. **Сохраните** этот Makefile в директорию, где находятся ваши исходные файлы (`mbr.s`, `ldlinux.asm`, и `syslinux.c`).

#2. **Запустите** команду `make` в этой директории для компиляции файлов.

#3. **Очистите** созданные файлы с помощью `make clean`, если это потребуется.

# Этот Makefile будет компилировать ассемблерные файлы в бинарные файлы с расширением `.bin` и C-файл в бинарный файл `syslinux.bin`.