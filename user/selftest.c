/*
 * selftest: checks parts of libc and the kernel on this system from a
 * real program. Run it from the shell: /bin/selftest
 *
 * Every check prints one line, "ok <name>" or "FAIL <name>"; the exit
 * status is the number of failures.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
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

/*
 * vfork: the child runs in this function, on this stack, until it execs or
 * exits; then vfork() returns a second time, in the parent, with its pid.
 */
static void test_vfork(void)
{
	volatile int marker = 1;
	int status = 0;
	pid_t pid;

	/* A child that exits without exec. */
	pid = vfork();
	if (pid == 0) {
		marker = 2;	/* shared memory: the parent must see this */
		_exit(33);
	}
	check("vfork returns the child pid", pid > 0 && pid != getpid());
	check("vfork child ran first, sharing memory", marker == 2);
	check("vfork child exit status", waitpid(pid, &status, 0) == pid &&
					 WIFEXITED(status) && WEXITSTATUS(status) == 33);

	/* A child that execs: "sh -c" prints a line and exits with 2. */
	pid = vfork();
	if (pid == 0) {
		execl("/bin/sh", "sh", "-c", "echo via vfork; exit 2", (char *)0);
		_exit(127);
	}
	check("vfork + exec returns the child pid", pid > 0);
	check("exec'd child exit status", waitpid(pid, &status, 0) == pid &&
					  WIFEXITED(status) && WEXITSTATUS(status) == 2);

	/* A child whose exec fails stays the child and can still exit. */
	pid = vfork();
	if (pid == 0) {
		execl("/nonexistent", "nonexistent", (char *)0);
		_exit(errno == ENOENT ? 44 : 45);
	}
	check("failed exec in vfork child", pid > 0 &&
					    waitpid(pid, &status, 0) == pid &&
					    WEXITSTATUS(status) == 44);
}

/*
 * Signal handlers. The kernel calls them when a system call returns, so
 * every test below makes one after the signal has been sent.
 */
static volatile sig_atomic_t got_signal, got_siginfo, got_sigchld, alarms;
static int alarm_pipe[2];
static jmp_buf signal_jb;

static void on_signal(int sig)
{
	got_signal = sig;
}

static void on_siginfo(int sig, siginfo_t *si, void *ctx)
{
	got_siginfo = si->si_signo == sig && si->si_pid == getpid() && ctx != 0;
}

static void on_sigchld(int sig)
{
	got_sigchld++;
}

static void on_jump(int sig)
{
	longjmp(signal_jb, sig);
}

static void arm_alarm(void)
{
	struct itimerval it = { { 0, 0 }, { 0, 20 * 1000 } };

	setitimer(ITIMER_REAL, &it, 0);
}

/*
 * With alarm_again set, the first alarm only interrupts and the second
 * one ends the read().
 */
static volatile sig_atomic_t alarm_again;

static void on_alarm(int sig)
{
	if (++alarms == 2)
		write(alarm_pipe[1], "x", 1);
	else if (alarm_again)
		arm_alarm();
}

static void test_signals(void)
{
	struct sigaction sa = { 0 };
	sigset_t set;
	volatile int jumps = 0;
	int status = 0;
	char c = 0;
	ssize_t n;
	pid_t pid;

	signal(SIGUSR1, on_signal);
	check("raise runs the handler", !raise(SIGUSR1) && got_signal == SIGUSR1);
	check("mask restored after the handler", !sigprocmask(SIG_BLOCK, 0, &set) &&
						 !sigismember(&set, SIGUSR1));

	sa.sa_sigaction = on_siginfo;
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGUSR2, &sa, 0);
	check("SA_SIGINFO handler gets siginfo and context",
	      !kill(getpid(), SIGUSR2) && got_siginfo);

	/* A blocked signal is delivered when it is unblocked. */
	got_signal = 0;
	sigemptyset(&set);
	sigaddset(&set, SIGUSR1);
	sigprocmask(SIG_BLOCK, &set, 0);
	raise(SIGUSR1);
	check("blocked signal stays pending", got_signal == 0);
	sigprocmask(SIG_UNBLOCK, &set, 0);
	check("delivered when unblocked", got_signal == SIGUSR1);

	/* Ignored and reset to default. */
	signal(SIGUSR1, SIG_IGN);
	check("SIG_IGN", !raise(SIGUSR1));

	/*
	 * A blocking read() interrupted by a handler: restarted with
	 * SA_RESTART (it then sees the byte the second alarm writes),
	 * EINTR without.
	 */
	check("pipe for alarms", !pipe(alarm_pipe));
	sa.sa_handler = on_alarm;
	sa.sa_flags = SA_RESTART;
	sigaction(SIGALRM, &sa, 0);
	alarm_again = 1;
	arm_alarm();
	n = read(alarm_pipe[0], &c, 1);
	check("SA_RESTART: read restarted after the handler",
	      n == 1 && c == 'x' && alarms == 2);

	alarms = 0;
	alarm_again = 0;
	sa.sa_flags = 0;
	sigaction(SIGALRM, &sa, 0);
	arm_alarm();
	n = read(alarm_pipe[0], &c, 1);
	check("no SA_RESTART: read fails with EINTR",
	      n == -1 && errno == EINTR && alarms == 1);
	signal(SIGALRM, SIG_DFL);
	close(alarm_pipe[0]);
	close(alarm_pipe[1]);

	/*
	 * longjmp out of a handler, many times: each one abandons a system
	 * call inside the kernel, which must not pile anything up.
	 */
	sa.sa_handler = on_jump;
	sa.sa_flags = SA_NODEFER;
	sigaction(SIGUSR1, &sa, 0);
	if (setjmp(signal_jb) == SIGUSR1)
		jumps++;
	if (jumps < 2000) {
		raise(SIGUSR1);
		check("longjmp out of a handler: raise returned", 0);
	}
	check("longjmp out of a handler x2000", jumps == 2000 && getpid() > 0);
	signal(SIGUSR1, SIG_DFL);

	/* A child killed by a signal, and SIGCHLD for it. */
	sa.sa_handler = on_sigchld;
	sa.sa_flags = SA_RESTART;
	sigaction(SIGCHLD, &sa, 0);
	pid = vfork();
	if (pid == 0) {
		execl("/bin/sleep", "sleep", "30", (char *)0);
		_exit(127);
	}
	check("kill child", pid > 0 && !kill(pid, SIGTERM));
	check("child terminated by SIGTERM", waitpid(pid, &status, 0) == pid &&
					     WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
	check("SIGCHLD handler ran", got_sigchld == 1);
	signal(SIGCHLD, SIG_DFL);
}

int main(void)
{
	test_setjmp();
	test_files();
	test_pipe();
	test_malloc();
	test_time();
	test_threads();
	test_vfork();
	test_signals();

	if (failures)
		printf("selftest: %d FAILED\n", failures);
	else
		printf("selftest: all passed\n");
	return failures;
}
