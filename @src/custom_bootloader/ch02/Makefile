# Определяем компиляторы и флаги
ASM=nasm
CC=gcc
LD=ld

# Флаги для сборки
ASMFLAGS=-f bin
CFLAGS=-m32 -ffreestanding -c
LDFLAGS=-m elf_i386

# Цель сборки
all: bootloader.bin kernel.bin

# Сборка загрузчика
bootloader.bin: bootloader.asm
	$(ASM) $(ASMFLAGS) -o bootloader.bin bootloader.asm

# Сборка ядра
kernel.o: library.c
	$(CC) $(CFLAGS) library.c -o kernel.o

kernel.bin: kernel.o
	$(LD) $(LDFLAGS) -Ttext 0x7E00 -o kernel.bin kernel.o
	objcopy -O binary kernel.bin kernel.bin

clean:
	rm -f *.o bootloader.bin kernel.bin



#bootloader.bin: Это наш загрузчик, который будет записан в начальные сектора диска.
#kernel.bin: Скомпилированный файл ядра. Мы указываем компоновщику, чтобы ядро было загружено в память по адресу 0x7E00 (тот же адрес, куда загрузчик копирует сектор).
#Флаг -ffreestanding указывает компилятору, что мы не используем стандартную библиотеку (так как мы пишем код для низкоуровневой среды без ОС).


