#include <stdio.h>

int main(int argc, char **argv, char **envp) {
    printf("content-type: text/plain\n");
    putchar('\n');
    for (char **env = envp; *env != 0; env++) {
        char *thisEnv = *env;
        printf("%s\n", thisEnv);
    }
    return 0;
}
