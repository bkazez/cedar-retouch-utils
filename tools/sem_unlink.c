/* sem_unlink: Remove a named POSIX semaphore.
 * Build: cc -o sem_unlink sem_unlink.c
 */

#include <stdio.h>
#include <semaphore.h>

int main(int argc, char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "Usage: %s /name\n", argv[0]);
        return 1;
    }

    if (sem_unlink(argv[1]) != 0) {
        perror("sem_unlink");
        return 1;
    }

    printf("Unlinked semaphore %s\n", argv[1]);
    return 0;
}
