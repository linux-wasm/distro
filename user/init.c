/*
 * /init of the linux-wasm distro, until BusyBox takes over.
 *
 * Not a shell: a small command loop that lets you poke at the system from
 * the web page. It is an ordinary C program linked against musl, so it
 * also serves as the distro's test that libc and kernel work together.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define MAX_ARGS 16

static void cmd_help(void)
{
	puts("commands:\n"
	     "  help              this text\n"
	     "  uname             kernel name, release and machine\n"
	     "  echo ARGS...      print the arguments\n"
	     "  ls [DIR]          list a directory\n"
	     "  cat FILE          print a file\n"
	     "  run PROG ARGS...  start a program and wait for it\n"
	     "  poweroff          shut the machine down");
}

static void cmd_uname(void)
{
	struct utsname u;

	if (uname(&u))
		perror("uname");
	else
		printf("%s %s %s %s\n", u.sysname, u.release, u.version, u.machine);
}

static void cmd_ls(const char *path)
{
	DIR *dir = opendir(path);
	struct dirent *entry;

	if (!dir) {
		perror(path);
		return;
	}
	while ((entry = readdir(dir)))
		if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, ".."))
			printf("%s%s\n", entry->d_name,
			       entry->d_type == DT_DIR ? "/" : "");
	closedir(dir);
}

static void cmd_cat(const char *path)
{
	char buf[512];
	ssize_t n;
	int fd = open(path, O_RDONLY);

	if (fd < 0) {
		perror(path);
		return;
	}
	fflush(stdout);
	while ((n = read(fd, buf, sizeof buf)) > 0)
		write(1, buf, n);
	if (n < 0)
		perror(path);
	close(fd);
}

static void cmd_run(char **argv)
{
	pid_t pid;
	int status;
	int err = posix_spawn(&pid, argv[0], 0, 0, argv, environ);

	if (err) {
		printf("%s: %s\n", argv[0], strerror(err));
		return;
	}
	if (waitpid(pid, &status, 0) < 0)
		perror("waitpid");
	else if (WIFEXITED(status))
		printf("[%d] exited with status %d\n", (int)pid, WEXITSTATUS(status));
	else if (WIFSIGNALED(status))
		printf("[%d] killed by signal %d\n", (int)pid, WTERMSIG(status));
}

static void cmd_poweroff(void)
{
	puts("powering off");
	fflush(stdout);
	sync();
	reboot(RB_POWER_OFF);
	perror("reboot");
}

int main(int argc, char **argv)
{
	char line[256];
	char *args[MAX_ARGS + 1];

	/* "run /init hello" starts this program again as a child. */
	if (getpid() != 1) {
		printf("child %d of %d:", (int)getpid(), (int)getppid());
		for (int i = 1; i < argc; i++)
			printf(" %s", argv[i]);
		putchar('\n');
		return argc - 1;
	}

	puts("\nlinux-wasm: this is a demo init, not a shell. Type \"help\".");

	for (;;) {
		int n = 0;

		fputs("# ", stdout);
		fflush(stdout);
		if (!fgets(line, sizeof line, stdin)) {
			puts("\nend of input");
			cmd_poweroff();
			return 1;
		}
		for (char *tok = strtok(line, " \t\n"); tok && n < MAX_ARGS;
		     tok = strtok(0, " \t\n"))
			args[n++] = tok;
		args[n] = 0;
		if (!n)
			continue;

		if (!strcmp(args[0], "help")) {
			cmd_help();
		} else if (!strcmp(args[0], "uname")) {
			cmd_uname();
		} else if (!strcmp(args[0], "echo")) {
			for (int i = 1; i < n; i++)
				printf("%s%s", i > 1 ? " " : "", args[i]);
			putchar('\n');
		} else if (!strcmp(args[0], "ls")) {
			cmd_ls(n > 1 ? args[1] : "/");
		} else if (!strcmp(args[0], "cat") && n > 1) {
			cmd_cat(args[1]);
		} else if (!strcmp(args[0], "run") && n > 1) {
			cmd_run(args + 1);
		} else if (!strcmp(args[0], "poweroff")) {
			cmd_poweroff();
		} else {
			printf("%s: unknown command or missing argument, try \"help\"\n",
			       args[0]);
		}
	}
}
