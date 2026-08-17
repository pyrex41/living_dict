.PHONY: tasks test oracle noop clean

tasks:
	python3 tools/build_tasks.py

test:
	python3 -m unittest discover -s tests -v

oracle:
	python3 -m ldeval run --oracle --arm oracle --output runs/oracle

noop:
	python3 -m ldeval run --agent-command "python3 $(CURDIR)/adapters/noop.py" --arm noop --output runs/noop || true

clean:
	rm -rf runs .selftest .test-runs build *.egg-info

