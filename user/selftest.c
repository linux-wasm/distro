/*
 * selftest: checks that parts of libc and the kernel that the demo init
 * does not touch work on this system. Run it with "run /bin/selftest".
 *
 * Every check prints one line, "ok <name>" or "FAIL <name>"; the exit
 * status is the number of failures.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int failures;

static void check(const char *name, int ok)
{
	printf("%s %s\n", ok ? "ok" : "FAIL", name);
	fflush(stdout);
	if (!ok)
		failures++;
}

/* setjmp/longjmp across several frames, with a live local. */
static jmp_buf jb;

static void jump_from(int depth)
{
	volatile char pad[64];

	pad[0] = depth;
	if (depth)
		jump_from(depth - 1);
	longjmp(jb, 42 + pad[0]);
}

static void test_setjmp(void)
{
	volatile int before = 7;
	int r = setjmp(jb);

	if (!r) {
		before = 8;
		jump_from(5);
		check("setjmp: longjmp returned", 0);
		return;
	}
	check("setjmp/longjmp", r == 42 && before == 8);
}

/* Files on the root ramfs, including a 64-bit offset. */
static void test_files(void)
{
	static const char text[] = "written by selftest\n";
	char buf[64] = "";
	struct stat st;
	int fd = open("/tmp/selftest.txt", O_CREAT | O_TRUNC | O_RDWR, 0644);

	check("open(O_CREAT)", fd >= 0);
	if (fd < 0)
		return;
	check("write", write(fd, text, sizeof text - 1) == sizeof text - 1);
	check("lseek", lseek(fd, 0, SEEK_SET) == 0);
	check("read back", read(fd, buf, sizeof buf) == sizeof text - 1 &&
			   !strcmp(buf, text));
	check("fstat size", !fstat(fd, &st) && st.st_size == sizeof text - 1);
	check("pwrite at 5 GiB", pwrite(fd, "x", 1, 5LL << 30) == 1 &&
				 !fstat(fd, &st) && st.st_size == (5LL << 30) + 1);
	check("ftruncate", !ftruncate(fd, 3) && !fstat(fd, &st) && st.st_size == 3);
	close(fd);
	check("unlink", !unlink("/tmp/selftest.txt") &&
			access("/tmp/selftest.txt", F_OK) == -1 && errno == ENOENT);
}

static void test_pipe(void)
{
	char buf[8] = "";
	int fds[2];

	check("pipe", !pipe(fds));
	check("pipe write/read", write(fds[1], "ping", 4) == 4 &&
				 read(fds[0], buf, sizeof buf) == 4 &&
				 !strcmp(buf, "ping"));
	close(fds[0]);
	close(fds[1]);
}

static void test_malloc(void)
{
	size_t size = 8 << 20;
	char *big = malloc(size);
	char *small[100];
	int ok = 1;

	check("malloc 8 MiB", big != 0);
	if (big) {
		memset(big, 0x5a, size);
		check("8 MiB usable", big[0] == 0x5a && big[size - 1] == 0x5a);
		free(big);
	}
	for (int i = 0; i < 100; i++) {
		small[i] = malloc(i * 37 + 1);
		if (!small[i])
			ok = 0;
		else
			memset(small[i], i, i * 37 + 1);
	}
	for (int i = 0; i < 100; i++) {
		if (small[i] && small[i][0] != (char)i)
			ok = 0;
		free(small[i]);
	}
	check("many small mallocs", ok);
}

static void test_time(void)
{
	struct timespec a, b, delay = { 0, 20 * 1000 * 1000 };
	long long ns;

	check("clock_gettime", !clock_gettime(CLOCK_MONOTONIC, &a));
	check("nanosleep 20 ms", !nanosleep(&delay, 0));
	clock_gettime(CLOCK_MONOTONIC, &b);
	ns = (b.tv_sec - a.tv_sec) * 1000000000LL + (b.tv_nsec - a.tv_nsec);
	check("sleep took 20..500 ms", ns >= 20 * 1000 * 1000 && ns < 500 * 1000 * 1000);
	check("time() after 2025", time(0) > 1735689600);
}

/* Threads: two workers increment a shared counter under a mutex. */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int counter;

static void *worker(void *arg)
{
	for (int i = 0; i < 1000; i++) {
		pthread_mutex_lock(&lock);
		counter++;
		pthread_mutex_unlock(&lock);
		if (i % 100 == 0)
			sched_yield();
	}
	return (char *)arg + 1;
}

static void test_threads(void)
{
	pthread_t t[2];
	void *ret[2] = { 0, 0 };
	int created = 1, joined = 1;

	for (int i = 0; i < 2; i++)
		if (pthread_create(&t[i], 0, worker, (void *)(long)(i * 10)))
			created = 0;
	check("pthread_create x2", created);
	if (!created)
		return;
	for (int i = 0; i < 2; i++)
		if (pthread_join(t[i], &ret[i]))
			joined = 0;
	check("pthread_join x2", joined);
	check("thread return values", ret[0] == (void *)1 && ret[1] == (void *)11);
	check("mutex-protected counter", counter == 2000);
}

int main(void)
{
	test_setjmp();
	test_files();
	test_pipe();
	test_malloc();
	test_time();
	test_threads();

	if (failures)
		printf("selftest: %d FAILED\n", failures);
	else
		printf("selftest: all passed\n");
	return failures;
}
