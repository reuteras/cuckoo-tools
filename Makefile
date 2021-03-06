.PHONY: install test

all: install

install:
	cp .bashrc ~/ && chmod 600 ~/.bashrc
	cp .bash_aliases ~/ && chmod 600 ~/.bash_aliases
	cp .vimrc ~/ && chmod 600 ~/.vimrc

clean:
	./bin/clean.sh

test:
	/usr/bin/shellcheck -f checkstyle bin/*.sh > checkstyle.out || true

update:
	./bin/update.sh

