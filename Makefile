EMACS ?= emacs
LOAD_PATH ?=

.PHONY: test

test:
	@task_test_dir=$$(mktemp -d); \
	trap 'rm -rf "$$task_test_dir"' EXIT; \
	TICKTICK_TEST_HOME="$$task_test_dir/" $(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval "(progn (require 'package) (setq package-load-list '((request t) (simple-httpd t))) (package-initialize) (setq user-emacs-directory (getenv \"TICKTICK_TEST_HOME\")))" \
	  -L . -l test/ticktick-test.el -f ert-run-tests-batch-and-exit
