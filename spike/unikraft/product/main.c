#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_LINE 4096

struct entry {
	char *key;
	char *value;
};

static struct entry *entries;
static size_t entry_count;
static size_t entry_capacity;

static char *copy_token(const char *text)
{
	size_t size = strlen(text) + 1;
	char *copy = malloc(size);

	if (copy != NULL)
		memcpy(copy, text, size);
	return copy;
}

static size_t lower_bound(const char *key, int *found)
{
	size_t low = 0;
	size_t high = entry_count;

	while (low < high) {
		size_t middle = low + (high - low) / 2;
		int order = strcmp(entries[middle].key, key);

		if (order < 0)
			low = middle + 1;
		else
			high = middle;
	}
	*found = low < entry_count && strcmp(entries[low].key, key) == 0;
	return low;
}

static int put(const char *key, const char *value)
{
	int found;
	size_t at = lower_bound(key, &found);
	char *new_value = copy_token(value);

	if (new_value == NULL)
		return -1;
	if (found) {
		free(entries[at].value);
		entries[at].value = new_value;
		return 0;
	}
	if (entry_count == entry_capacity) {
		size_t capacity = entry_capacity == 0 ? 8 : entry_capacity * 2;
		struct entry *grown = realloc(entries, capacity * sizeof(*entries));

		if (grown == NULL) {
			free(new_value);
			return -1;
		}
		entries = grown;
		entry_capacity = capacity;
	}
	memmove(&entries[at + 1], &entries[at],
		(entry_count - at) * sizeof(*entries));
	entries[at].key = copy_token(key);
	entries[at].value = new_value;
	if (entries[at].key == NULL) {
		free(new_value);
		memmove(&entries[at], &entries[at + 1],
			(entry_count - at) * sizeof(*entries));
		return -1;
	}
	entry_count++;
	return 0;
}

static void delete_key(const char *key)
{
	int found;
	size_t at = lower_bound(key, &found);

	if (!found)
		return;
	free(entries[at].key);
	free(entries[at].value);
	entry_count--;
	memmove(&entries[at], &entries[at + 1],
		(entry_count - at) * sizeof(*entries));
}

static void execute(char *line)
{
	char *command;
	char *key;
	char *value;
	char *extra;
	int found;
	size_t at;
	size_t i;

	command = strtok(line, " \t");
	if (command == NULL)
		return;
	key = strtok(NULL, " \t");
	value = strtok(NULL, " \t");
	extra = strtok(NULL, " \t");

	if (strcmp(command, "PUT") == 0 && key && value && !extra) {
		if (put(key, value) == 0)
			puts("OK");
		else
			puts("ERR memory");
	} else if (strcmp(command, "GET") == 0 && key && !value) {
		at = lower_bound(key, &found);
		if (found)
			printf("VALUE %s %s\n", key, entries[at].value);
		else
			printf("MISSING %s\n", key);
	} else if (strcmp(command, "DELETE") == 0 && key && !value) {
		delete_key(key);
		puts("OK");
	} else if (strcmp(command, "DUMP") == 0 && !key) {
		for (i = 0; i < entry_count; i++)
			printf("KEY %s %s\n", entries[i].key, entries[i].value);
		puts("OK");
	} else {
		puts("ERR unknown");
	}
	fflush(stdout);
}

int main(int argc, char **argv)
{
	char line[MAX_LINE];
	FILE *input = stdin;

	if (argc == 2) {
		input = fopen(argv[1], "r");
		if (input == NULL) {
			puts("ERR input");
			return 1;
		}
	} else if (argc != 1) {
		puts("ERR input");
		return 1;
	}

	while (fgets(line, sizeof(line), input) != NULL) {
		size_t length = strlen(line);

		while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r'))
			line[--length] = '\0';
		if (length == 0)
			continue;
		if (strcmp(line, "HALT") == 0) {
			puts("HALT");
			fflush(stdout);
			if (input != stdin)
				fclose(input);
			return 0;
		}
		execute(line);
	}
	if (input != stdin)
		fclose(input);
	return 0;
}
