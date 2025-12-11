#include <stdio.h>

int main(void) {
    printf("content-type: text/plain\n");
    printf("another-header: value\n");
    putchar('\n');
    fprintf(stderr, "log from the binary\n");
    printf("hello, world\n");
    return 0;
}
