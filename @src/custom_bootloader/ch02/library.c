/* library.c (обновленное "ядро")
Теперь это "ядро" — простая программа на C, которая выполняется после передачи ей управления загрузчиком.  */


void main() {
    // Простая функция, которая выполняется как "ядро"
    int result = 2 + 2;

    // В реальной системе здесь бы происходила инициализация ядра
    // и запуск ядра ОС, но для примера просто остаемся здесь в цикле
    while (1) {
        // Заглушка, чтобы не завершать программу (вместо реального ядра)
    }
}


/*

десь функция main выступает как условное ядро, которое начинает работу после загрузки.
Для простоты результат 2 + 2 не выводится на экран, так как при загрузке ОС обычно нет операционной системы или стандартной библиотеки для вывода текста. 
Вместо этого программа просто выполняется в бесконечном цикле

*/